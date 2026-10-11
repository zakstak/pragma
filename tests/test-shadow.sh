#!/usr/bin/env bash
# Retain complete receipts without changing the normal typecheck gate.
set -euo pipefail
PRAGMA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
repo="$tmp_dir/repo with spaces"
mkdir -p "$tmp_dir/bin" "$repo"
git init -q -b main "$repo"
git -C "$repo" config user.name Fixture
git -C "$repo" config user.email fixture@example.invalid
git -C "$repo" config commit.gpgsign false
cat >"$tmp_dir/bin/npm" <<'RUNNER'
#!/bin/sh
if [ "$1" = --version ]; then
  printf '11.0.0\n'
  exit 0
fi
printf '%s\n' "$*" >>"$TEST_COMMANDS"
case "$*" in
  'run typecheck')
    printf 'baseline stdout\n'
    printf 'baseline stderr\n' >&2
    if [ "${TEST_BASELINE_SLEEP:-0}" = 1 ]; then
      sleep 30 &
      printf '%s\n' "$!" >"$TEST_CHILD_PID"
      wait
    fi
    if [ "${TEST_BASELINE_FAIL:-0}" = 1 ]; then
      printf "answer.ts(1,14): error TS2322: Type 'string' is not assignable to type 'number'.\n"
      exit 2
    fi
    ;;
  'run typecheck:shadow')
    printf 'shadow stdout\n'
    printf 'shadow stderr\n' >&2
    if [ "${TEST_LARGE_OUTPUT:-0}" = 1 ]; then
      node -e 'process.stdout.write("x".repeat(2 * 1024 * 1024) + "END\n")'
    fi
    if [ "${TEST_CHANGE_INPUT:-0}" = 1 ]; then
      printf 'export const changed = 1;\n' >answer.ts
    fi
    if [ "${TEST_SHADOW_SLEEP:-0}" = 1 ]; then
      sleep 30 &
      if [ -n "${TEST_CHILD_PID:-}" ]; then
        printf '%s\n' "$!" >"$TEST_CHILD_PID"
      fi
      wait
    fi
    if [ "${TEST_SHADOW_SIGNAL:-0}" = 1 ]; then
      kill -TERM "$$"
    fi
    if [ "${TEST_BASELINE_FAIL:-0}" = 1 ]; then
      printf "answer.ts(1,14): error TS2322: Type 'string' is not assignable to type 'number'.\n"
      exit 3
    fi
    if [ "${TEST_SHADOW_FAIL:-0}" = 1 ]; then
      printf 'answer.ts(2,1): error TS2355: Missing return.\n'
      exit 1
    fi
    ;;
  test) printf 'test passed\n' ;;
esac
RUNNER
chmod +x "$tmp_dir/bin/npm"
export PATH="$tmp_dir/bin:$PATH"
export TEST_COMMANDS="$tmp_dir/commands"
export PRAGMA_OUTPUT_FORMAT=gpt PRAGMA_SKIP_INTERNAL_BIN_PATH=1
unset PRAGMA_SKIP_TESTS PRAGMA_SHADOW PRAGMA_SHADOW_CACHE_DIR PRAGMA_SHADOW_TIMEOUT_SECONDS
cd "$repo"
printf '{"scripts":{"typecheck":"tsc --noEmit","typecheck:shadow":"tsc-rs --noEmit","test":"node test.js"}}\n' >package.json
printf '{"compilerOptions":{"strict":true}}\n' >tsconfig.json
printf 'export const answer: number = 42;\n' >answer.ts
git add .
git -c core.hooksPath=/dev/null commit -qm fixture
head="$(git rev-parse HEAD)"
run_checks() {
  : >"$TEST_COMMANDS"
  bash "$PRAGMA_DIR/lib/test.sh" "$@" >"$tmp_dir/output" 2>&1
}
receipt_path() {
  node -e 'const fs = require("node:fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1], "utf8").split("\n")[0]).cache)' "$tmp_dir/output"
}
PRAGMA_SHADOW=0 run_checks
[[ "$(cat "$TEST_COMMANDS")" == $'run typecheck\ntest' && ! -e .git/pragma/shadow ]]
printf 'PASS: disabled shadow creates no cache or extra compiler run\n'
run_checks
receipt="$(receipt_path)"
[[ "$(cat "$TEST_COMMANDS")" == $'run typecheck\nrun typecheck:shadow\ntest' ]]
node - "$receipt" "$head" "$PRAGMA_DIR/lib/shadow-summary.js" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const [directory, head, summaryHelper] = process.argv.slice(2);
const meta = JSON.parse(fs.readFileSync(path.join(directory, 'metadata.json')));
const findings = JSON.parse(fs.readFileSync(path.join(directory, 'findings.json')));
const summary = JSON.parse(fs.readFileSync(path.join(directory, 'summary.json')));
assert.equal(meta.state, 'complete');
assert.equal(meta.schema_version, 2);
assert.equal(findings.schema, 'pragma.shadow-findings');
assert.equal(findings.schema_version, 1);
assert.equal(summary.schema, 'pragma.shadow-summary');
assert.equal(summary.schema_version, 1);
assert.equal(summary.run_id, meta.id);
assert.equal(summary.state, 'complete');
assert.equal(summary.started_at, meta.started_at);
assert.equal(summary.finished_at, meta.finished_at);
assert.deepEqual(summary.repository, { id: meta.context?.repository_id ?? null, root: meta.repository.root, git_dir: meta.repository.git_dir, head });
assert.equal(summary.worktree_id, meta.context?.worktree_id ?? null);
assert.deepEqual(summary.context, meta.context ?? { thread_id: null, thread_source: null });
const { buildSummary } = require(summaryHelper);
const legacyMeta = { ...meta };
delete legacyMeta.context;
const legacySummary = buildSummary(legacyMeta, findings, summary.artifacts);
assert.deepEqual(legacySummary.context, { thread_id: null, thread_source: null });
assert.equal(legacySummary.repository.id, null);
assert.equal(legacySummary.worktree_id, null);
const contextualMeta = { ...meta, context: { thread_id: 'thread-fixture', thread_source: 'PRAGMA_THREAD_ID', repository_id: 'repository-fixture', worktree_id: 'worktree-fixture' } };
const contextualSummary = buildSummary(contextualMeta, findings, summary.artifacts);
assert.deepEqual(contextualSummary.context, contextualMeta.context);
assert.equal(contextualSummary.repository.id, 'repository-fixture');
assert.equal(contextualSummary.worktree_id, 'worktree-fixture');
assert.equal(summary.producer.name, 'pragma');
assert.equal(summary.producer.version, meta.pragma.version);
assert.deepEqual(summary.producer.git, meta.pragma.git);
assert.deepEqual(summary.producer.source_hashes, meta.pragma.source_hashes);
assert.match(summary.producer.source_hashes['lib/shadow-summary.js'], /^[a-f0-9]{64}$/);
assert.deepEqual(summary.compilers, meta.compilers);
assert.equal(summary.baseline_policy, 'project-script-blocking');
assert.equal(summary.baseline.exit_code, meta.baseline.exit_code);
assert.equal(summary.shadow.exit_code, meta.shadow.exit_code);
assert.deepEqual(summary.baseline.artifacts, { stdout: meta.baseline.stdout.file, stderr: meta.baseline.stderr.file });
assert.deepEqual(summary.shadow.artifacts, { stdout: meta.shadow.stdout.file, stderr: meta.shadow.stderr.file });
assert.equal(summary.comparisons.length, 1);
assert.equal(summary.comparisons[0].project, '.');
assert.equal(summary.comparisons[0].scope, 'project-owned-script');
assert.equal(summary.comparisons[0].baseline.exit_code, 0);
assert.equal(summary.comparisons[0].shadow.exit_code, 0);
assert.deepEqual(summary.comparisons[0].findings, []);
assert.deepEqual(summary.skipped, []);
assert.deepEqual(summary.capture_errors, []);
for (const file of [...Object.values(summary.artifacts), ...Object.values(summary.comparisons[0].artifacts), ...Object.values(summary.baseline.artifacts), ...Object.values(summary.shadow.artifacts)]) {
  assert.equal(path.isAbsolute(file), false);
  assert.ok(!file.split(path.sep).includes('..'));
  assert.ok(fs.existsSync(path.join(directory, file)), file);
}
assert.equal(fs.statSync(path.join(directory, 'summary.json')).mode & 0o777, 0o600);
assert.equal(Object.hasOwn(summary.comparisons[0].baseline, 'stdout'), false);
assert.equal(Object.hasOwn(summary.comparisons[0].shadow, 'stdout'), false);
assert.equal(meta.git_before.head, head);
assert.equal(meta.git_after.head, head);
assert.equal(meta.git_before.branch, 'main');
assert.equal(meta.baseline.exit_code, 0);
assert.equal(meta.shadow.exit_code, 0);
assert.ok(meta.baseline.duration_ms >= 0);
assert.ok(meta.host.cpu_count > 0);
assert.ok(meta.runtime.executable);
assert.deepEqual(findings.findings, []);
for (const label of ['baseline', 'shadow']) {
  for (const stream of ['stdout', 'stderr']) {
    assert.equal(fs.readFileSync(path.join(directory, `${label}.${stream}.log`), 'utf8'), `${label} ${stream}\n`);
  }
}
for (const file of ['inputs-before.json', 'inputs-after.json', 'inputs/package.json', 'inputs/tsconfig.json', 'git-staged.patch', 'git-worktree.patch', 'report.md', 'notes.md']) {
  assert.ok(fs.existsSync(path.join(directory, file)), file);
}
assert.equal(fs.statSync(directory).mode & 0o777, 0o700);
assert.equal(fs.statSync(path.join(directory, 'metadata.json')).mode & 0o777, 0o600);
JS
first_receipt="$receipt"
printf 'PASS: default shadow caches outputs and publishes a private versioned collector summary with provenance\n'
PRAGMA_SHADOW=1 TEST_SHADOW_FAIL=1 run_checks
receipt="$(receipt_path)"
[[ "$receipt" != "$first_receipt" && -f "$first_receipt/metadata.json" ]]
rg -q outcome_difference "$receipt/findings.json"
rg -q diagnostic_difference "$receipt/findings.json"
[[ "$(cat "$TEST_COMMANDS")" == $'run typecheck\nrun typecheck:shadow\ntest' ]]
printf 'PASS: shadow differences remain report-only and retain prior receipts\n'
if PRAGMA_SHADOW=1 TEST_BASELINE_FAIL=1 run_checks; then
  printf 'FAIL: normal compiler failure was accepted\n'
  exit 1
fi
receipt="$(receipt_path)"
[[ "$(cat "$TEST_COMMANDS")" == $'run typecheck\nrun typecheck:shadow' ]]
rg -q '"cls":"typecheck"' "$tmp_dir/output"
node - "$receipt" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const directory = process.argv[2];
const metadata = JSON.parse(fs.readFileSync(path.join(directory, 'metadata.json')));
const findings = JSON.parse(fs.readFileSync(path.join(directory, 'findings.json')));
const summary = JSON.parse(fs.readFileSync(path.join(directory, 'summary.json')));
assert.equal(metadata.baseline.exit_code, 2);
assert.equal(metadata.shadow.exit_code, 3);
assert.equal(summary.baseline.exit_code, 2);
assert.equal(summary.shadow.exit_code, 3);
assert.deepEqual(findings.findings, []);
assert.equal(findings.baseline_diagnostics.length, 1);
JS
printf 'PASS: baseline errors still block pushes, shadow still runs, and unequal failure codes are not findings\n'
if PRAGMA_SHADOW=1 PRAGMA_OUTPUT_FORMAT=human TEST_BASELINE_FAIL=1 run_checks; then
  printf 'FAIL: human mode accepted a failing baseline\n'
  exit 1
fi
rg -q TS2322 "$tmp_dir/output"
if rg -q '"hook":"pre-push"' "$tmp_dir/output"; then
  printf 'FAIL: human mode emitted a JSON envelope\n'
  exit 1
fi
printf 'PASS: human mode displays baseline diagnostics and the cache path\n'
PRAGMA_SHADOW=1 TEST_LARGE_OUTPUT=1 run_checks
receipt="$(receipt_path)"
[[ "$(wc -c <"$receipt/shadow.stdout.log")" -gt 2097152 ]]
tail -c 4 "$receipt/shadow.stdout.log" | rg -q END
printf 'PASS: compiler outputs exceed subprocess buffer limits without truncation\n'
PRAGMA_SHADOW=1 TEST_CHANGE_INPUT=1 run_checks
receipt="$(receipt_path)"
rg -q repository_changed_during_run "$receipt/findings.json"
git restore answer.ts
printf 'PASS: worktree changes during the comparison are recorded\n'
PRAGMA_SHADOW=1 TEST_SHADOW_SIGNAL=1 run_checks
receipt="$(receipt_path)"
rg -q shadow_execution_error "$receipt/findings.json"
rg -q SIGTERM "$receipt/metadata.json"
printf 'PASS: compiler crashes are cached without blocking a passing baseline\n'
PRAGMA_SHADOW=1 PRAGMA_SHADOW_TIMEOUT_SECONDS=0.1 TEST_SHADOW_SLEEP=1 run_checks
receipt="$(receipt_path)"
rg -q shadow_timeout "$receipt/findings.json"
printf 'PASS: shadow timeouts retain outputs and findings without blocking tests\n'
node - "$PRAGMA_DIR/lib/shadow.js" "$tmp_dir" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { spawn } = require('node:child_process');
const [helper, temporary] = process.argv.slice(2);
async function check(label, signal) {
  const pidFile = `${temporary}/${label}.pid`;
  const receiptFile = `${temporary}/${label}.receipt`;
  const child = spawn(process.execPath, [helper, 'npm', receiptFile], {
    stdio: 'ignore',
    env: { ...process.env, TEST_CHILD_PID: pidFile, [label === 'baseline' ? 'TEST_BASELINE_SLEEP' : 'TEST_SHADOW_SLEEP']: '1' },
  });
  const closed = new Promise(resolve => child.on('close', (code, termination) => resolve({ code, termination })));
  const deadline = Date.now() + 6000;
  try {
    while (!fs.existsSync(pidFile)) {
      assert.ok(Date.now() < deadline, 'compiler child did not start');
      await new Promise(resolve => setTimeout(resolve, 20));
    }
    const pid = Number(fs.readFileSync(pidFile, 'utf8'));
    child.kill(signal);
    const result = await closed;
    assert.equal(result.code, signal === 'SIGINT' ? 130 : 143);
    assert.equal(result.termination, null);
    // A killed orphan can briefly remain a zombie until the system reaps it.
    const ps = require('node:child_process').spawnSync('ps', ['-o', 'stat=', '-p', String(pid)], { encoding: 'utf8' });
    assert.ok(!ps.stdout.trim() || ps.stdout.trim().startsWith('Z'), `compiler survived: ${ps.stdout}`);
    const directory = fs.readFileSync(receiptFile, 'utf8');
    assert.equal(JSON.parse(fs.readFileSync(`${directory}/metadata.json`)).state, 'running');
    assert.equal(fs.existsSync(`${directory}/summary.json`), false, 'partial receipt must not advertise a completed summary');
    for (const compiler of ['baseline', 'shadow']) {
      for (const stream of ['stdout', 'stderr']) assert.ok(fs.existsSync(`${directory}/${compiler}.${stream}.log`));
    }
  } finally {
    child.kill('SIGTERM');
  }
}
(async () => {
  await check('baseline', 'SIGINT');
  await check('shadow', 'SIGTERM');
})().catch(error => { console.error(error); process.exitCode = 1; });
JS
printf 'PASS: cancelling baseline or shadow kills compiler descendants and retains partial outputs\n'
PRAGMA_SHADOW=1 PRAGMA_SHADOW_TIMEOUT_SECONDS=2147484 run_checks
[[ "$(cat "$TEST_COMMANDS")" == $'run typecheck\ntest' ]]
rg -q 'Shadow capture unavailable' "$tmp_dir/output"
printf 'PASS: oversized timeout values preserve the normal gate instead of overflowing the timer\n'
git config --local pragma.shadow true
run_checks
receipt="$(receipt_path)"
[[ -f "$receipt/metadata.json" ]]
PRAGMA_SHADOW=0 run_checks
[[ "$(cat "$TEST_COMMANDS")" == $'run typecheck\ntest' ]]
git config --local pragma.shadow invalid
run_checks
[[ "$(cat "$TEST_COMMANDS")" == $'run typecheck\ntest' ]]
rg -q 'local pragma.shadow must be a Git boolean' "$tmp_dir/output"
git config --local --unset pragma.shadow
PRAGMA_SHADOW_CACHE_DIR="$tmp_dir/custom cache" run_checks --shadow
receipt="$(receipt_path)"
[[ "$receipt" == "$tmp_dir/custom cache/"* ]]
printf 'PASS: local config, environment overrides, CLI flag, and custom spaced cache paths work\n'
PRAGMA_SHADOW_CACHE_DIR="$repo/local cache" run_checks --shadow
receipt="$(receipt_path)"
node -e 'const assert=require("node:assert/strict"); const fs=require("node:fs"); assert.deepEqual(JSON.parse(fs.readFileSync(process.argv[1])).findings, [])' "$receipt/findings.json"
printf 'PASS: custom caches inside the repo do not change input fingerprints or Git findings\n'
rm -rf "${repo:?}/local cache"
printf 'occupied\n' >"$tmp_dir/unwritable-cache"
PRAGMA_SHADOW=1 PRAGMA_SHADOW_CACHE_DIR="$tmp_dir/unwritable-cache" run_checks
[[ "$(cat "$TEST_COMMANDS")" == $'run typecheck\ntest' ]]
rg -q 'Shadow capture unavailable' "$tmp_dir/output"
printf 'PASS: cache setup failure preserves the normal typecheck gate\n'
printf '\n[[repos.hooks]]\nid = "pragma-shadow"\n' >prek.toml
run_checks
[[ "$(cat "$TEST_COMMANDS")" == $'run typecheck\ntest' ]]
run_checks --shadow-only
receipt="$(receipt_path)"
[[ "$(cat "$TEST_COMMANDS")" == $'run typecheck\nrun typecheck:shadow' ]]
TEST_BASELINE_FAIL=1 run_checks --shadow-only
[[ "$(cat "$TEST_COMMANDS")" == $'run typecheck\nrun typecheck:shadow' ]]
PRAGMA_SHADOW=invalid run_checks --shadow-only
[[ ! -s "$TEST_COMMANDS" ]]
run_checks --shadow
receipt="$(receipt_path)"
[[ "$(cat "$TEST_COMMANDS")" == $'run typecheck\nrun typecheck:shadow\ntest' ]]
rm prek.toml
printf 'PASS: dedicated hook avoids inline duplication, remains advisory, and explicit --shadow retains normal gates\n'
if PRAGMA_SHADOW_CACHE_DIR="$tmp_dir" TEST_BASELINE_FAIL=1 run_checks; then
  printf 'FAIL: ancestor shadow cache bypassed the normal typecheck\n'
  exit 1
fi
[[ "$(cat "$TEST_COMMANDS")" == 'run typecheck' ]]
rg -q 'TS2322' "$tmp_dir/output"
printf 'PASS: an ancestor cache cannot hide or bypass the mandatory project typecheck\n'
worktree="$tmp_dir/linked worktree"
git worktree add -q -b linked "$worktree"
(cd "$worktree" && PRAGMA_SHADOW=1 run_checks)
receipt="$(receipt_path)"
[[ "$receipt" == *'.git/worktrees/'* && -f "$receipt/metadata.json" ]]
printf 'PASS: linked worktrees cache under their own Git metadata directory\n'
unborn="$tmp_dir/unborn"
git init -q "$unborn"
cp package.json tsconfig.json answer.ts "$unborn/"
(cd "$unborn" && PRAGMA_SHADOW=1 run_checks)
receipt="$(receipt_path)"
node -e 'const assert=require("node:assert/strict"); const fs=require("node:fs"); assert.equal(JSON.parse(fs.readFileSync(process.argv[1])).git_before.head, null)' "$receipt/metadata.json"
printf 'PASS: unborn repositories retain a null HEAD and both outputs\n'
