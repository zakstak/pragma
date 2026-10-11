#!/usr/bin/env bash
# Collect complete observations without rewriting historical receipts.
set -euo pipefail
PRAGMA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$PRAGMA_DIR" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const pragma = process.argv[2];
const { buildSummary } = require(path.join(pragma, 'lib/shadow-summary.js'));
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'pragma-collection-'));
const cache = path.join(temporary, 'cache with spaces');
const repo = path.join(temporary, 'repository');
fs.mkdirSync(cache);
fs.mkdirSync(repo);
assert.equal(spawnSync('git', ['init', '-q', repo]).status, 0);
const gitCache = path.join(repo, '.git', 'pragma', 'shadow');
fs.mkdirSync(path.dirname(gitCache), { recursive: true });
fs.symlinkSync(cache, gitCache, 'dir');
function writeJson(location, value) {
  fs.writeFileSync(location, JSON.stringify(value, null, 2) + '\n');
}
function fixture(id, hour, thread, worktree = 'worktree-main', legacy = false) {
  const directory = path.join(cache, id);
  fs.mkdirSync(directory);
  const log = stream => ({ file: `${stream}.log`, bytes: 0, sha256: 'fixture' });
  const outcome = { exit_code: 0, signal: null, timed_out: false, error: null, stdout: log('stdout'), stderr: log('stderr') };
  const metadata = {
    schema_version: 2, state: 'complete', id,
    started_at: `2026-10-11T${hour}:00:00.000Z`, finished_at: `2026-10-11T${hour}:01:00.000Z`,
    repository: { root: repo, git_dir: path.join(repo, '.git') }, git_before: { head: 'fixture-head' },
    pragma: { version: '1.0.0', git: { output: 'fixture-producer' }, source_hashes: { 'lib/shadow.js': 'fixture-hash' } },
    compilers: { 'tsc-rs': { receipt: { version: '0.3.0' } } }, baseline_policy: 'advisory-only',
    comparisons: [{ project: '.', scope: 'direct-tsc', findings: [], baseline: outcome, shadow: outcome }],
    skipped: [], capture_errors: [],
  };
  if (!legacy) metadata.context = { thread_id: thread, thread_source: 'PRAGMA_THREAD_ID', repository_id: 'repository-shared', worktree_id: worktree };
  const findings = { findings: [] };
  writeJson(path.join(directory, 'metadata.json'), metadata);
  writeJson(path.join(directory, 'findings.json'), findings);
  fs.writeFileSync(path.join(directory, 'stdout.log'), '');
  fs.writeFileSync(path.join(directory, 'stderr.log'), '');
  if (!legacy) writeJson(path.join(directory, 'summary.json'), buildSummary(metadata, findings, { metadata: 'metadata.json', findings: 'findings.json', summary: 'summary.json' }));
  return directory;
}
function update(directory, filename, updateValue) {
  const location = path.join(directory, filename);
  const value = JSON.parse(fs.readFileSync(location));
  updateValue(value);
  writeJson(location, value);
}
function collect(args, extraEnv = {}) {
  const result = spawnSync(process.execPath, [path.join(pragma, 'tools/collect-shadow.js'), ...args], { cwd: repo, env: { ...process.env, ...extraEnv }, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, '');
  return JSON.parse(result.stdout);
}
function fingerprint(directory) {
  const values = [];
  function visit(current) {
    for (const entry of fs.readdirSync(current, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const location = path.join(current, entry.name);
      if (entry.isDirectory()) visit(location);
      else if (entry.isFile()) values.push([path.relative(directory, location), fs.statSync(location).mtimeMs, crypto.createHash('sha256').update(fs.readFileSync(location)).digest('hex')]);
    }
  }
  visit(directory);
  return JSON.stringify(values);
}
try {
  fixture('thread-a-old', '01', 'thread-a');
  fixture('thread-a-new', '02', 'thread-a');
  fixture('thread-a-new-zzz', '02', 'thread-a');
  fixture('thread-b', '03', 'thread-b');
  fixture('other-worktree', '04', 'thread-a', 'worktree-other');
  const legacy = fixture('legacy', '05', null, null, true);
  const failing = fixture('failing-checks', '06', 'thread-failing');
  update(failing, 'summary.json', value => { value.comparisons[0].baseline.exit_code = 2; value.comparisons[0].findings = ['outcome_difference']; value.findings = ['outcome_difference']; });
  const unfinished = fixture('interrupted', '07', 'thread-a');
  update(unfinished, 'metadata.json', value => { value.state = 'running'; });
  const future = fixture('future-summary', '08', 'thread-a');
  update(future, 'summary.json', value => { value.schema_version = 99; });
  const futureMetadata = fixture('future-metadata', '09', 'thread-a');
  update(futureMetadata, 'metadata.json', value => { value.schema_version = 99; });
  const futureFindings = fixture('future-findings', '10', null, null, true);
  update(futureFindings, 'findings.json', value => { value.schema = 'pragma.shadow-findings'; value.schema_version = 99; });
  const missingMetadata = fixture('missing-metadata', '11', 'thread-a');
  fs.unlinkSync(path.join(missingMetadata, 'metadata.json'));
  const missingFindings = fixture('missing-findings', '12', null, null, true);
  fs.unlinkSync(path.join(missingFindings, 'findings.json'));
  const malformed = fixture('malformed-summary', '13', 'thread-a');
  fs.writeFileSync(path.join(malformed, 'summary.json'), '{invalid');
  const invalidShape = fixture('invalid-legacy-shape', '14', null, null, true);
  update(invalidShape, 'metadata.json', value => { value.comparisons[0].baseline = null; });
  const escape = fixture('unsafe-artifact', '15', 'thread-a');
  update(escape, 'summary.json', value => { value.artifacts.metadata = '../metadata.json'; });
  const missingLog = fixture('missing-log', '16', 'thread-a');
  fs.unlinkSync(path.join(missingLog, 'stdout.log'));
  const mismatchedContext = fixture('mismatched-context', '17', 'thread-a');
  update(mismatchedContext, 'summary.json', value => { value.context.thread_id = 'another-thread'; });
  const mismatchedRepo = fixture('mismatched-repository', '18', 'thread-a');
  update(mismatchedRepo, 'summary.json', value => { value.repository.root = path.join(temporary, 'another-repository'); });
  const missingArtifactKeys = fixture('missing-artifact-keys', '19', 'thread-a');
  update(missingArtifactKeys, 'summary.json', value => { value.comparisons[0].artifacts = {}; });
  const missingIdentity = fixture('missing-identity', '20', 'thread-a');
  update(missingIdentity, 'summary.json', value => { delete value.worktree_id; });
  const additive = fixture('additive-fields', '21', 'thread-additive');
  update(additive, 'summary.json', value => { value.artifacts.future_optional = 'not-published-by-this-version'; value.comparisons[0].artifacts.future_optional = 'also-not-published'; value.future_optional = { arbitrary: 'additive' }; });
  const failedRoot = fixture('failed-root-gate', '22', 'thread-root-gate');
  const rootResult = { exit_code: 2, signal: null, timed_out: false, error: null, stdout: { file: 'root.stdout.log' }, stderr: { file: 'root.stderr.log' } };
  update(failedRoot, 'metadata.json', value => { value.baseline_policy = 'project-script-blocking'; value.baseline = rootResult; value.shadow = null; });
  fs.writeFileSync(path.join(failedRoot, 'root.stdout.log'), 'framework typecheck failed');
  fs.writeFileSync(path.join(failedRoot, 'root.stderr.log'), '');
  const failedMeta = JSON.parse(fs.readFileSync(path.join(failedRoot, 'metadata.json')));
  writeJson(path.join(failedRoot, 'summary.json'), buildSummary(failedMeta, { findings: [] }, { metadata: 'metadata.json', findings: 'findings.json', summary: 'summary.json' }));
  const legacyFailedRoot = fixture('legacy-failed-root', '23', null, null, true);
  update(legacyFailedRoot, 'metadata.json', value => { value.baseline = rootResult; value.shadow = null; });
  fs.writeFileSync(path.join(legacyFailedRoot, 'root.stdout.log'), 'advisory framework typecheck failed');
  fs.writeFileSync(path.join(legacyFailedRoot, 'root.stderr.log'), '');
  const missingRootLog = fixture('missing-root-log', '00', 'thread-a');
  update(missingRootLog, 'metadata.json', value => { value.baseline = rootResult; });
  const missingRootMeta = JSON.parse(fs.readFileSync(path.join(missingRootLog, 'metadata.json')));
  writeJson(path.join(missingRootLog, 'summary.json'), buildSummary(missingRootMeta, { findings: [] }, { metadata: 'metadata.json', findings: 'findings.json', summary: 'summary.json' }));
  const mismatchedRootOutcome = fixture('mismatched-root-outcome', '00', 'thread-a');
  update(mismatchedRootOutcome, 'summary.json', value => { value.baseline = { exit_code: 2, signal: null, timed_out: false, error: null, artifacts: { stdout: 'stdout.log', stderr: 'stderr.log' } }; });
  const betaRootFields = fixture('beta-missing-root-fields', '00', 'thread-a');
  update(betaRootFields, 'summary.json', value => { delete value.baseline; });
  fs.writeFileSync(path.join(cache, 'non-receipt-file'), 'ignored');
  const before = fingerprint(cache);
  const all = collect(['--cache', cache, '--repo', repo, '--cache', cache]);
  assert.equal(all.schema, 'pragma.shadow-collection');
  assert.equal(all.schema_version, 1);
  assert.ok(Number.isFinite(Date.parse(all.generated_at)));
  assert.equal(all.runs.length, 10);
  assert.equal(new Set(all.runs.map(run => run.receipt)).size, 10);
  assert.deepEqual(all.runs.map(run => run.summary.run_id), ['legacy-failed-root', 'failed-root-gate', 'additive-fields', 'failing-checks', 'legacy', 'other-worktree', 'thread-b', 'thread-a-new-zzz', 'thread-a-new', 'thread-a-old']);
  assert.equal(all.skipped.length, 17);
  for (const [id, pattern] of [
    ['interrupted', /incomplete/], ['future-summary', /unsupported.*summary/],
    ['future-metadata', /unsupported.*metadata/], ['future-findings', /unsupported.*findings/],
    ['missing-metadata', /cannot read metadata/], ['missing-findings', /cannot read findings/],
    ['malformed-summary', /malformed JSON/], ['invalid-legacy-shape', /outcome.*object/],
    ['unsafe-artifact', /metadata artifact must be metadata/],
    ['missing-log', /artifact stdout.log is unavailable/],
    ['mismatched-context', /context does not match/], ['mismatched-repository', /repository identity does not match/],
    ['missing-artifact-keys', /baseline_stdout artifact path/], ['missing-identity', /identities are required/],
    ['missing-root-log', /root.stdout.log is unavailable/], ['mismatched-root-outcome', /root baseline outcome does not match/],
    ['beta-missing-root-fields', /root baseline capture is required/],
  ]) assert.match(all.skipped.find(run => run.receipt.endsWith(`/${id}`)).reason, pattern);
  assert.ok(all.runs.find(run => run.summary.run_id === 'failing-checks').summary.findings.includes('outcome_difference'));
  const rootSummary = all.runs.find(run => run.summary.run_id === 'failed-root-gate').summary;
  assert.equal(rootSummary.baseline_policy, 'project-script-blocking');
  assert.equal(rootSummary.baseline.exit_code, 2);
  assert.equal(rootSummary.shadow, null);
  assert.equal(rootSummary.comparisons[0].baseline.exit_code, 0);
  assert.equal(rootSummary.comparisons[0].shadow.exit_code, 0);
  assert.equal(rootSummary.baseline.artifacts.stdout, 'root.stdout.log');
  const legacyRootSummary = all.runs.find(run => run.summary.run_id === 'legacy-failed-root').summary;
  assert.equal(legacyRootSummary.baseline.exit_code, 2);
  assert.equal(legacyRootSummary.baseline_policy, 'advisory-only');
  const configOnlySummary = all.runs.find(run => run.summary.run_id === 'thread-b').summary;
  assert.equal(configOnlySummary.baseline, null);
  assert.equal(configOnlySummary.shadow, null);
  assert.equal(fingerprint(cache), before);
  assert.equal(fs.existsSync(path.join(legacy, 'summary.json')), false);
  console.log('PASS: collection deduplicates physical receipts, preserves failing observations and reports malformed/unsupported/partial receipts');
  console.log('PASS: legacy metadata2 is converted in memory without changing any receipt bytes or mtimes');
  const latest = collect(['--cache', cache, '--latest']);
  assert.equal(latest.runs.length, 7);
  assert.ok(!latest.runs.some(run => run.summary.run_id === 'thread-a-old'));
  assert.ok(latest.runs.some(run => run.summary.run_id === 'thread-a-new-zzz'));
  assert.ok(!latest.runs.some(run => run.summary.run_id === 'thread-a-new'));
  assert.ok(latest.runs.some(run => run.summary.run_id === 'thread-b'));
  assert.ok(latest.runs.some(run => run.summary.run_id === 'other-worktree'));
  console.log('PASS: latest grouping retains separate threads/worktrees with deterministic timestamp/run-ID ordering');
  console.log('PASS: known artifacts and identities must match receipts; unknown additive fields remain compatible');
  console.log('PASS: failed root gates remain visible beside passing config comparisons; null roots and legacy advisory outcomes are retained');
  const defaultRepo = collect([], { PRAGMA_SHADOW_CACHE_DIR: '' });
  assert.deepEqual(defaultRepo.runs, all.runs);
  const defaultEnv = collect([], { PRAGMA_SHADOW_CACHE_DIR: cache });
  assert.deepEqual(defaultEnv.runs, all.runs);
  const unavailable = collect(['--cache', path.join(temporary, 'absent'), '--repo', path.join(temporary, 'absent-repo')]);
  assert.equal(unavailable.runs.length, 0);
  assert.equal(unavailable.skipped.length, 2);
  for (const args of [['--cache'], ['--unknown'], ['--repo', '--latest']]) {
    const result = spawnSync(process.execPath, [path.join(pragma, 'tools/collect-shadow.js'), ...args], { encoding: 'utf8' });
    assert.equal(result.status, 2);
    assert.equal(result.stdout, '');
    assert.match(result.stderr, /Usage:/);
  }
  console.log('PASS: environment/Git defaults and explicit inputs work; only invalid CLI arguments fail the collection');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
JS
