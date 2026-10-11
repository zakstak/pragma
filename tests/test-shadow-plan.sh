#!/usr/bin/env bash
# Validate shell boundaries and automatic discovery against isolated compilers.
set -euo pipefail
PRAGMA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$PRAGMA_DIR/lib/shadow-plan.js" <<'JS'
const assert = require('node:assert/strict');
const { scriptPlan, readOnlyArgs } = require(process.argv[2]);
assert.deepEqual(scriptPlan('tsc --noEmit -p "config with spaces.json" && node node_modules/typescript/bin/tsc -p other.json').commands, [['--noEmit', '-p', 'config with spaces.json'], ['-p', 'other.json']]);
for (const script of ['npx --no-install tsc -p app.json', 'pnpm exec tsc -p app.json', 'npm exec -- tsc -p app.json', 'bunx tsc -p app.json']) {
  assert.deepEqual(scriptPlan(script).commands, [['-p', 'app.json']]);
}
for (const script of ['tsc -p $(touch PWNED)', 'tsc && echo success', 'tsc > output', 'tsc || true', 'tsc; echo success', 'tsc --watch', 'tsc --Watch', 'tsc --watch=true', 'tsc --WATCH=false', 'tsc --Build', 'tsc -build', 'tsc --b', 'tsc --B', 'tsc --build=true', 'tsc --init', 'tsc --generateTrace output', 'tsc --generateCpuProfile output.cpuprofile', 'tsc --noEmit\ntsc --noEmit -p child.json', 'tsc -b', 'vue-tsc --build', 'svelte-check && tsc', 'pnpm -r typecheck', 'npm exec tsc -p app.json', 'FOO=bar tsc', 'tsc "${HOME}"']) {
  const result = scriptPlan(script);
  assert.equal(result.supported, false, script);
  assert.ok(result.reason, script);
}
assert.deepEqual(scriptPlan("tsc -p 'literal $file.json'").commands, [['-p', 'literal $file.json']]);
assert.deepEqual(scriptPlan(String.raw`tsc -p "a\z.json"`).commands, [['-p', String.raw`a\z.json`]]);
assert.deepEqual(scriptPlan(String.raw`tsc -p "literal \$file.json"`).commands, [['-p', 'literal $file.json']]);
const args = ['--project', 'config with spaces.json', '--strict', 'false'];
assert.deepEqual(readOnlyArgs(args, '/private state', 0).slice(0, args.length), args);
assert.ok(readOnlyArgs(args, '/private state', 0).includes('/private state/0.tsbuildinfo'));
console.log('PASS: direct compiler argv survives quoting; shell composition and build mutation are refused');
JS

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
fixture_pragma="$tmp_dir/pragma"
mkdir -p "$fixture_pragma/lib" "$fixture_pragma/bin" "$tmp_dir/repo/packages/nested app/node_modules/.bin" "$tmp_dir/repo/node_modules/.bin"
cp "$PRAGMA_DIR"/lib/* "$fixture_pragma/lib/"
cp "$PRAGMA_DIR/VERSION" "$fixture_pragma/"
cat >"$fixture_pragma/bin/tsc-rs" <<'JS'
#!/usr/bin/env node
const fs = require('node:fs');
if (process.argv[2] === '--version') { console.log('Version 7.1.0-dev'); process.exit(0); }
fs.appendFileSync(process.env.TEST_ARGV, JSON.stringify({compiler:'rust', cwd:process.cwd(), args:process.argv.slice(2)})+'\n');
if (process.env.TEST_SHADOW_FAIL === '1') { console.log('source.ts(1,1): error TS2322: mismatch.'); process.exit(2); }
JS
printf '{"version":"0.3.0","source_commit":"fixture","archive_sha256":"verified-fixture"}\n' >"$fixture_pragma/bin/tsc-rs.receipt.json"
cat >"$tmp_dir/repo/node_modules/.bin/tsc" <<'JS'
#!/usr/bin/env node
const fs = require('node:fs');
if (process.argv[2] === '--version') { console.log('Version 6.0.3'); process.exit(0); }
fs.appendFileSync(process.env.TEST_ARGV, JSON.stringify({compiler:'typescript', cwd:process.cwd(), args:process.argv.slice(2)})+'\n');
if (process.env.TEST_BASELINE_FAIL === '1') { console.log('source.ts(1,1): error TS2322: mismatch.'); process.exit(2); }
JS
chmod +x "$fixture_pragma/bin/tsc-rs" "$tmp_dir/repo/node_modules/.bin/tsc"
cp "$tmp_dir/repo/node_modules/.bin/tsc" "$tmp_dir/repo/packages/nested app/node_modules/.bin/tsc"
cd "$tmp_dir/repo"
git init -q
printf '{"scripts":{"check":"tsc --noEmit -p \\\"config with spaces.json\\\""}}\n' >"packages/nested app/package.json"
printf '{"compilerOptions":{"strict":true}}\n' >"packages/nested app/config with spaces.json"
printf '{}\n' >package.json
export TEST_ARGV="$tmp_dir/argv" PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PRAGMA_OUTPUT_FORMAT=gpt
unset PRAGMA_SHADOW PRAGMA_SKIP_TESTS
run_capture() {
  : >"$TEST_ARGV"
  bash "$fixture_pragma/lib/test.sh" --shadow-only >"$tmp_dir/output" 2>&1
}
run_capture
node - "$tmp_dir/output" "$TEST_ARGV" <<'JS'
const assert = require('node:assert/strict'), fs = require('node:fs');
const envelope = JSON.parse(fs.readFileSync(process.argv[2], 'utf8').trim());
const meta = JSON.parse(fs.readFileSync(`${envelope.cache}/metadata.json`));
assert.equal(meta.baseline_policy, 'advisory-only');
assert.equal(meta.comparisons.length, 1);
assert.equal(meta.comparisons[0].project, 'packages/nested app');
assert.equal(meta.comparisons[0].scope, 'direct-tsc');
assert.equal(meta.comparisons[0].script, 'check');
assert.equal(meta.compilers['tsc-rs'].receipt.source_commit, 'fixture');
assert.match(meta.compilers['tsc-rs'].receipt_sha256, /^[a-f0-9]{64}$/);
const commands = fs.readFileSync(process.argv[3], 'utf8').trim().split('\n').map(JSON.parse);
assert.equal(commands.length, 2);
assert.deepEqual(commands.map(command => command.compiler), ['typescript', 'rust']);
for (const command of commands) {
  assert.deepEqual(command.args.slice(0, 3), ['--noEmit', '-p', 'config with spaces.json']);
  assert.ok(command.cwd.endsWith('packages/nested app'));
  assert.ok(command.args.includes('--noEmit'));
  assert.ok(command.args[command.args.indexOf('--tsBuildInfoFile') + 1].startsWith(envelope.cache));
}
assert.deepEqual(meta.skipped, []);
JS
printf 'PASS: nested check script is discovered without a root typecheck; argv/cwd and provenance are captured\n'
TEST_BASELINE_FAIL=1 TEST_SHADOW_FAIL=1 run_capture
[[ $(wc -l <"$TEST_ARGV") == 2 ]]
printf 'PASS: capture-only baseline and shadow failures never create a new push gate\n'
printf '{"scripts":{"typecheck":"vue-tsc --build"}}\n' >"packages/nested app/package.json"
printf '{}\n' >"packages/nested app/tsconfig.json"
run_capture
node - "$tmp_dir/output" <<'JS'
const assert = require('node:assert/strict'), fs = require('node:fs');
const envelope = JSON.parse(fs.readFileSync(process.argv[2], 'utf8').trim());
const meta = JSON.parse(fs.readFileSync(`${envelope.cache}/metadata.json`));
assert.equal(meta.skipped[0].scope, 'project-script');
assert.match(meta.skipped[0].reason, /framework/);
assert.equal(meta.comparisons[0].scope, 'typescript-config-only');
assert.ok(envelope.findings.includes('shadow_coverage_incomplete'));
JS
printf 'PASS: unsupported framework script is explicit; separate config-only checks never claim template parity\n'
printf '{"scripts":{"typecheck":"tsc-rs --noEmit -p tsconfig.json"}}\n' >"packages/nested app/package.json"
cp "$tmp_dir/repo/node_modules/.bin/tsc" "$tmp_dir/repo/packages/nested app/node_modules/.bin/tsc-rs"
task_native_package="@tsc-rs/$(node -p 'process.platform + "-" + process.arch')"
mkdir -p "packages/nested app/node_modules/tsc-rs" "packages/nested app/node_modules/$task_native_package/lib"
printf '{"name":"tsc-rs","version":"0.2.0"}\n' >"packages/nested app/node_modules/tsc-rs/package.json"
printf '{"name":"%s","version":"0.2.0"}\n' "$task_native_package" >"packages/nested app/node_modules/$task_native_package/package.json"
cp "$tmp_dir/repo/node_modules/.bin/tsc" "packages/nested app/node_modules/$task_native_package/lib/tsc"
run_capture
node - "$tmp_dir/output" <<'JS'
const assert = require('node:assert/strict'), fs = require('node:fs');
const envelope = JSON.parse(fs.readFileSync(process.argv[2], 'utf8').trim());
const meta = JSON.parse(fs.readFileSync(`${envelope.cache}/metadata.json`));
assert.equal(meta.comparisons.length, 1);
assert.equal(meta.comparisons[0].scope, 'native-version-comparison');
assert.equal(meta.comparisons[0].baseline_compiler.kind, 'project-tsc-rs');
assert.ok(meta.comparisons[0].baseline_compiler.executable.endsWith('/tsc-rs'));
assert.equal(meta.comparisons[0].baseline_compiler.package.name, 'tsc-rs');
assert.equal(meta.comparisons[0].baseline_compiler.package.version, '0.2.0');
assert.equal(meta.comparisons[0].baseline_compiler.native_package.version, '0.2.0');
assert.match(meta.comparisons[0].baseline_compiler.executable_identity.sha256, /^[a-f0-9]{64}$/);
assert.match(meta.comparisons[0].baseline_compiler.native_binary.sha256, /^[a-f0-9]{64}$/);
assert.ok(meta.comparisons[0].baseline_compiler.executable_identity.realpath.endsWith('/tsc-rs'));
assert.equal(meta.comparisons[0].candidate_compiler.receipt.version, '0.3.0');
assert.deepEqual(meta.skipped, []);
JS
printf 'PASS: existing native compiler baseline is identified as a version comparison, never independent TypeScript parity\n'
PRAGMA_SHADOW=0 run_capture
[[ ! -s "$TEST_ARGV" && ! -s "$tmp_dir/output" ]]
git config --local pragma.shadow false
run_capture
[[ ! -s "$TEST_ARGV" && ! -s "$tmp_dir/output" ]]
git config --local --unset pragma.shadow
printf 'PASS: explicit environment and local config opt-outs disable the dedicated hook\n'
printf '{}\n' >"packages/nested app/package.json"
rm "packages/nested app/tsconfig.json" "packages/nested app/config with spaces.json"
mkdir -p tests/fixtures/forbidden
printf '{"scripts":{"typecheck":"tsc --noEmit"}}\n' >tests/fixtures/forbidden/package.json
printf '{}\n' >tests/fixtures/forbidden/tsconfig.json
run_capture
[[ ! -s "$TEST_ARGV" && ! -s "$tmp_dir/output" ]]
printf 'PASS: compiler fixture projects are not treated as application workspaces\n'

mkdir -p frontend
printf '{"compilerOptions":{"strict":true}}\n' >frontend/tsconfig.json
run_capture
node - "$tmp_dir/output" "$TEST_ARGV" <<'JS'
const assert = require('node:assert/strict'), fs = require('node:fs');
const envelope = JSON.parse(fs.readFileSync(process.argv[2], 'utf8').trim());
const meta = JSON.parse(fs.readFileSync(`${envelope.cache}/metadata.json`));
assert.equal(meta.comparisons.length, 1);
assert.equal(meta.comparisons[0].project, 'frontend');
assert.equal(meta.comparisons[0].scope, 'typescript-config-only');
assert.ok(meta.comparisons[0].baseline_compiler.executable.endsWith('/repo/node_modules/.bin/tsc'));
assert.equal(fs.readFileSync(process.argv[3], 'utf8').trim().split('\n').length, 2);
JS
printf 'PASS: nested config-only project uses hoisted compiler without requiring package.json\n'
rm -rf frontend
printf '{"scripts":{"typecheck":"tsc -p \\\"config first.json\\\" && tsc -p other.json"}}\n' >package.json
printf '{}\n' >"config first.json"
printf '{}\n' >other.json
cat >"$fixture_pragma/bin/npm" <<'RUNNER'
#!/bin/sh
if [ "$1" = --version ]; then printf '12.2.0\n'; fi
exit 0
RUNNER
chmod +x "$fixture_pragma/bin/npm"
PATH="$fixture_pragma/bin:$PATH" run_capture
node - "$tmp_dir/output" <<'JS'
const assert = require('node:assert/strict'), fs = require('node:fs');
const envelope = JSON.parse(fs.readFileSync(process.argv[2], 'utf8').trim());
const meta = JSON.parse(fs.readFileSync(`${envelope.cache}/metadata.json`));
const comparison = meta.comparisons.find(result => result.project === '.');
assert.equal(comparison.input_commands.length, 2);
assert.equal(comparison.shadow.commands.length, 2);
assert.deepEqual(comparison.config_inputs.map(config => config.path).sort(), ['config first.json', 'other.json']);
for (const config of comparison.config_inputs) assert.ok(fs.existsSync(`${envelope.cache}/project-configs/${config.path}`));
JS
printf 'PASS: every custom-named config in a direct compiler chain is snapshotted with exact input commands\n'
