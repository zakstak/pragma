#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_HELPER="$SCRIPT_DIR/../tools/thread-worktree.js" node <<'NODE'
'use strict';
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const helper = process.env.WORKTREE_HELPER;
const { acquireLock, threadName } = require(helper);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'pragma-thread-test-'));
const source = path.join(temporary, 'source with spaces');
const base = path.join(temporary, 'cache with spaces');
fs.mkdirSync(source);
let passed = 0;

function git(args, repository = source) {
  const result = spawnSync('git', ['-C', repository, ...args], { encoding: 'utf8' });
  assert.strictEqual(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function run(id, options = {}) {
  return new Promise((resolve, reject) => {
    const env = { ...process.env, PRAGMA_WORKTREE_DIR: base, ...options.env };
    delete env.PRAGMA_THREAD_ID;
    delete env.CODEX_THREAD_ID;
    Object.assign(env, options.env || {});
    const child = spawn(process.execPath, [helper, ...(id === null ? [] : [id, source])], { env, cwd: source });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', data => { stdout += data; });
    child.stderr.on('data', data => { stderr += data; });
    child.on('error', reject);
    child.on('close', code => resolve({ code, stdout, stderr, value: code === 0 ? JSON.parse(stdout) : null }));
  });
}

function pass(message) {
  passed += 1;
  process.stdout.write(`ok ${passed} - ${message}\n`);
}

(async () => {
  try {
    git(['init', '--quiet']);
    git(['config', 'user.name', 'Pragma test']);
    git(['config', 'user.email', 'pragma-test@example.invalid']);
    fs.writeFileSync(path.join(source, 'tracked.txt'), 'committed\n');
    git(['add', 'tracked.txt']);
    git(['commit', '--quiet', '-m', 'fixture']);
    const originalHead = git(['rev-parse', 'HEAD']);
    const originalBranch = git(['symbolic-ref', '--short', 'HEAD']);
    fs.writeFileSync(path.join(source, 'tracked.txt'), 'dirty original\n');
    fs.writeFileSync(path.join(source, 'untracked.txt'), 'untouched\n');
    const originalStatus = git(['status', '--porcelain']);

    const cleanOriginal = path.join(temporary, 'clean original');
    fs.mkdirSync(cleanOriginal);
    git(['init', '--quiet'], cleanOriginal);
    fs.writeFileSync(path.join(cleanOriginal, 'tracked.txt'), 'clean\n');
    git(['add', '.'], cleanOriginal);
    git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'clean fixture'], cleanOriginal);
    const { ensureWorktree } = require(helper);
    const internalBase = path.join(cleanOriginal, 'never created', 'cache');
    await assert.rejects(ensureWorktree('contained base', cleanOriginal, internalBase), /outside every registered worktree/);
    assert(!fs.existsSync(path.join(cleanOriginal, 'never created')));
    assert.strictEqual(git(['status', '--porcelain'], cleanOriginal), '');
    const linkedClean = path.join(temporary, 'clean linked');
    git(['worktree', 'add', '--quiet', '--detach', linkedClean, 'HEAD'], cleanOriginal);
    const linkedBase = path.join(linkedClean, 'never created');
    await assert.rejects(ensureWorktree('linked contained base', cleanOriginal, linkedBase), /outside every registered worktree/);
    assert(!fs.existsSync(linkedBase));
    assert.strictEqual(git(['status', '--porcelain'], linkedClean), '');
    const alias = path.join(temporary, 'symlink to clean');
    fs.symlinkSync(cleanOriginal, alias, 'dir');
    await assert.rejects(ensureWorktree('symlink contained base', cleanOriginal, path.join(alias, 'new cache')), /outside every registered worktree/);
    assert(!fs.existsSync(path.join(cleanOriginal, 'new cache')));
    const metadataBase = path.join(cleanOriginal, '.git', 'new cache');
    await assert.rejects(ensureWorktree('metadata contained base', cleanOriginal, metadataBase), /outside every registered worktree/);
    assert(!fs.existsSync(metadataBase));
    assert.strictEqual(git(['status', '--porcelain'], cleanOriginal), '');
    pass('cache containment is rejected before mkdir for original, linked, symlinked, and Git metadata paths');

    const races = await Promise.all([run('same thread / $literal'), run('same thread / $literal')]);
    races.forEach(result => assert.strictEqual(result.code, 0, result.stderr));
    assert.strictEqual(races[0].value.worktree, races[1].value.worktree);
    assert.deepStrictEqual(races.map(result => result.value.reused).sort(), [false, true]);
    const owned = races[0].value;
    const owner = JSON.parse(fs.readFileSync(owned.owner_file, 'utf8'));
    assert.strictEqual(owner.schema, 'pragma.thread-owner');
    assert.strictEqual(owner.schema_version, 1);
    assert.strictEqual(owner.thread_id, 'same thread / $literal');
    assert.strictEqual(owner.repository, fs.realpathSync(path.join(source, '.git')));
    assert.strictEqual(owner.worktree, owned.worktree);
    assert(!owned.worktree.startsWith(path.join(source, '.git')));
    pass('concurrent same-thread creation publishes one complete owner and reuses one worktree');

    const other = await run('different thread');
    assert.strictEqual(other.code, 0, other.stderr);
    assert.notStrictEqual(other.value.worktree, owned.worktree);
    assert.notStrictEqual(other.value.branch, owned.branch);
    assert.strictEqual(git(['rev-parse', 'HEAD']), originalHead);
    assert.strictEqual(git(['symbolic-ref', '--short', 'HEAD']), originalBranch);
    assert.strictEqual(git(['status', '--porcelain']), originalStatus);
    assert.strictEqual(fs.readFileSync(path.join(source, 'tracked.txt'), 'utf8'), 'dirty original\n');
    assert.strictEqual(fs.readFileSync(path.join(source, 'untracked.txt'), 'utf8'), 'untouched\n');
    assert(!fs.existsSync(path.join(source, '.git', 'pragma', 'thread.json')));
    assert.strictEqual(fs.readFileSync(path.join(owned.worktree, 'tracked.txt'), 'utf8'), 'committed\n');
    pass('different threads are isolated and dirty original checkout remains unchanged and unclaimed');

    fs.writeFileSync(path.join(owned.worktree, 'tracked.txt'), 'thread commit\n');
    git(['add', 'tracked.txt'], owned.worktree);
    git(['-c', 'core.hooksPath=/dev/null', 'commit', '--quiet', '-m', 'thread change'], owned.worktree);
    const threadHead = git(['rev-parse', 'HEAD'], owned.worktree);
    fs.writeFileSync(path.join(owned.worktree, 'tracked.txt'), 'dirty thread\n');
    const reuse = await run(owner.thread_id);
    assert.strictEqual(reuse.code, 0, reuse.stderr);
    assert.strictEqual(reuse.value.reused, true);
    assert.strictEqual(git(['rev-parse', 'HEAD'], owned.worktree), threadHead);
    assert.strictEqual(fs.readFileSync(path.join(owned.worktree, 'tracked.txt'), 'utf8'), 'dirty thread\n');
    assert.deepStrictEqual(JSON.parse(fs.readFileSync(owned.owner_file, 'utf8')), owner);
    pass('same-thread reuse preserves committed and dirty work and original ownership');

    const alternate = await run(owner.thread_id, { env: { PRAGMA_WORKTREE_DIR: path.join(temporary, 'other cache') } });
    assert.notStrictEqual(alternate.code, 0);
    assert.match(alternate.stderr, /already checked out|already used by worktree/i);
    assert.strictEqual(git(['rev-parse', 'HEAD'], owned.worktree), threadHead);
    pass('an existing branch at another cache path cannot be forcibly checked out or reset');

    fs.writeFileSync(owned.owner_file, JSON.stringify({ ...owner, thread_id: 'some other owner' }));
    const conflictBytes = fs.readFileSync(owned.owner_file, 'utf8');
    const conflict = await run(owner.thread_id);
    assert.notStrictEqual(conflict.code, 0);
    assert.match(conflict.stderr, /owner conflicts/);
    assert.strictEqual(fs.readFileSync(owned.owner_file, 'utf8'), conflictBytes);
    pass('conflicting owner is rejected without overwriting metadata or dirty work');

    fs.unlinkSync(owned.owner_file);
    const unowned = await run(owner.thread_id);
    assert.notStrictEqual(unowned.code, 0);
    assert.match(unowned.stderr, /unowned or invalid/);
    assert(!fs.existsSync(owned.owner_file));
    assert.strictEqual(fs.readFileSync(path.join(owned.worktree, 'tracked.txt'), 'utf8'), 'dirty thread\n');
    pass('an existing unowned worktree cannot be silently claimed');

    for (const id of ['', 'bad\nthread', ' leading', 'trailing ', 'x'.repeat(129)]) {
      const invalid = await run(id);
      assert.notStrictEqual(invalid.code, 0);
      assert.match(invalid.stderr, /Thread ID/);
    }
    const fromEnvironment = await run(null, { env: { PRAGMA_THREAD_ID: 'preferred env', CODEX_THREAD_ID: 'fallback env' } });
    assert.strictEqual(fromEnvironment.code, 0, fromEnvironment.stderr);
    assert.strictEqual(fromEnvironment.value.thread_id, 'preferred env');
    const fallback = await run(null, { env: { CODEX_THREAD_ID: 'fallback env' } });
    assert.strictEqual(fallback.code, 0, fallback.stderr);
    assert.strictEqual(fallback.value.thread_id, 'fallback env');
    assert.notStrictEqual(threadName('a/b'), threadName('a b'));
    pass('thread IDs are validated at CLI boundary and environment precedence is stable');

    const staleLock = path.join(temporary, 'stale.lock');
    fs.mkdirSync(staleLock);
    fs.writeFileSync(path.join(staleLock, 'creator.json'), '{"pid":12345}');
    const start = Date.now();
    await assert.rejects(acquireLock(staleLock, 'waiting thread', 75), /remove a stale lock only after confirming no creator/);
    assert(Date.now() - start < 1000);
    assert(fs.existsSync(path.join(staleLock, 'creator.json')));
    pass('creation lock wait is bounded and stale ownership is preserved for explicit recovery');
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
})().catch(error => {
  process.stderr.write(error.stack + '\n');
  process.exitCode = 1;
});
NODE
