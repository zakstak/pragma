#!/usr/bin/env bash
# Prove thread ownership is checked before hook side effects.
set -euo pipefail
PRAGMA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
node - "$PRAGMA_DIR" "$tmp_dir" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const [pragma, temporary] = process.argv.slice(2);
const {canonicalOrigin, getThreadContext, validateThreadId} = require(`${pragma}/lib/thread-context.js`);
assert.equal(canonicalOrigin('git@github.com:Zakstak/Pragma.git'), 'github.com/zakstak/pragma');
assert.equal(canonicalOrigin('https://username:fixture-password@github.com/zakstak/pragma.git?fixture-token=secret'), 'github.com/zakstak/pragma');
assert.equal(canonicalOrigin('ssh://git@github.com:22/Zakstak/Pragma.git'), 'github.com/zakstak/pragma');
assert.notEqual(canonicalOrigin('ssh://git@example.invalid:2222/owner/repo.git'), canonicalOrigin('ssh://git@example.invalid:2223/owner/repo.git'));
assert.equal(canonicalOrigin('git@bad host:owner/repo'), null);
for (const value of ['', '\nthread', 'a'.repeat(129), 'a\x00b']) assert.throws(() => validateThreadId(value));
function git(directory, args) {
  const result = spawnSync('git', args, {cwd:directory, encoding:'utf8'});
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}
const repo = path.join(temporary, 'repo');
fs.mkdirSync(repo);
git(repo, ['init', '-q']);
git(repo, ['config', 'user.name', 'Fixture']);
git(repo, ['config', 'user.email', 'fixture@example.invalid']);
git(repo, ['config', 'commit.gpgsign', 'false']);
git(repo, ['remote', 'add', 'origin', 'git@github.com:zakstak/pragma.git']);
fs.writeFileSync(path.join(repo, 'README.md'), 'fixture\n');
git(repo, ['add', '.']);
git(repo, ['-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'fixture']);
const tree = path.join(temporary, 'thread tree');
git(repo, ['worktree', 'add', '-q', '--detach', tree, 'HEAD']);
const mainContext = getThreadContext(repo, {PRAGMA_THREAD_ID:'first'});
const treeContext = getThreadContext(tree, {CODEX_THREAD_ID:'second'});
assert.equal(mainContext.repository_id, treeContext.repository_id);
assert.notEqual(mainContext.worktree_id, treeContext.worktree_id);
assert.equal(treeContext.thread_id, 'second');
assert.equal(getThreadContext(tree, {PRAGMA_THREAD_ID:'explicit',CODEX_THREAD_ID:'implicit'}).thread_id, 'explicit');
const location = git(tree, ['rev-parse', '--path-format=absolute', '--git-path', 'pragma/thread.json']);
fs.mkdirSync(path.dirname(location), {recursive:true});
const owner = {schema:'pragma.thread-owner',schema_version:1,thread_id:'second',repository:fs.realpathSync(git(tree,['rev-parse','--path-format=absolute','--git-common-dir'])),worktree:fs.realpathSync(tree),created_at:new Date().toISOString()};
fs.writeFileSync(location,JSON.stringify(owner));
assert.equal(getThreadContext(tree, {}).thread_id,'second');
assert.equal(getThreadContext(tree, {}).thread_source,'worktree-owner');
assert.throws(() => getThreadContext(tree,{CODEX_THREAD_ID:'first'}), /belongs to thread second/);
const before = fs.readFileSync(path.join(tree,'README.md'),'utf8');
for (const [file,args] of [['format.sh',['README.md']],['lint.sh',['README.md']],['secrets.sh',[]],['test.sh',[]]]) {
  const run = spawnSync('bash',[`${pragma}/lib/${file}`,...args],{cwd:tree,encoding:'utf8',env:{...process.env,PRAGMA_THREAD_ID:'first',PRAGMA_SKIP_TESTS:'1'}});
  assert.notEqual(run.status,0,`${file}: ${run.stdout} ${run.stderr}`);
  assert.match(run.stderr,/belongs to thread second/,file);
}
const advisory = spawnSync('bash',[`${pragma}/lib/test.sh`,'--shadow-only'],{cwd:tree,encoding:'utf8',env:{...process.env,PRAGMA_THREAD_ID:'first'}});
assert.equal(advisory.status,0);
assert.match(advisory.stderr,/belongs to thread second/);
assert.equal(fs.readFileSync(path.join(tree,'README.md'),'utf8'),before);
fs.writeFileSync(location,JSON.stringify({...owner,schema_version:2}));
assert.throws(() => getThreadContext(tree,{}),/Unsupported or invalid/);
console.log('PASS: identity strips credentials, separates worktrees, and records thread precedence');
console.log('PASS: conflicting owners stop all normal hook entry points before side effects; advisory capture stays advisory');
console.log('PASS: manual runs inherit the assigned owner; unknown owner schemas are rejected');
JS
