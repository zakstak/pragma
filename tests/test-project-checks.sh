#!/usr/bin/env bash
# Check project script selection and pre-push failure behavior.
set -euo pipefail
PRAGMA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/repo"
git init -q "$tmp_dir/repo"
for runner in npm bun; do
  cat >"$tmp_dir/bin/$runner" <<'RUNNER'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_COMMANDS"
if [ "$*" = 'run typecheck' ] && [ "${TEST_FAIL_TYPECHECK:-0}" = 1 ]; then
  printf 'TS2322: incompatible type\n'
  exit 2
fi
RUNNER
  chmod +x "$tmp_dir/bin/$runner"
done
export PATH="$tmp_dir/bin:$PATH"
export TEST_COMMANDS="$tmp_dir/commands"
export PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PRAGMA_OUTPUT_FORMAT=gpt PRAGMA_SHADOW=0
unset PRAGMA_SKIP_TESTS
cd "$tmp_dir/repo"
run_checks() {
  : >"$TEST_COMMANDS"
  bash "$PRAGMA_DIR/lib/test.sh" >"$tmp_dir/output" 2>&1
}
printf '{"scripts":{"typecheck":"tsc --noEmit","test":"node test.js"}}\n' >package.json
run_checks
[[ "$(cat "$TEST_COMMANDS")" == $'run typecheck\ntest' ]]
printf 'PASS: npm typecheck runs before tests\n'
if TEST_FAIL_TYPECHECK=1 run_checks; then
  printf 'FAIL: failing typecheck was accepted\n'
  exit 1
fi
[[ "$(cat "$TEST_COMMANDS")" == 'run typecheck' ]]
rg -q '"cls":"typecheck"' "$tmp_dir/output"
rg -q 'TS2322' "$tmp_dir/output"
printf 'PASS: failing typecheck blocks tests and retains diagnostics\n'
printf '{"scripts":{"typecheck":"tsc --noEmit"}}\n' >package.json
run_checks
[[ "$(cat "$TEST_COMMANDS")" == 'run typecheck' ]]
printf 'PASS: typecheck runs without a test script\n'
printf '{"devDependencies":{"test":"1.0.0"},"description":"typecheck"}\n' >package.json
run_checks
[[ ! -s "$TEST_COMMANDS" && ! -s "$tmp_dir/output" ]]
printf 'PASS: unrelated manifest strings do not trigger project scripts\n'
printf '{"scripts":{"typecheck":true}}\n' >package.json
if run_checks; then
  printf 'FAIL: invalid typecheck script was accepted\n'
  exit 1
fi
[[ ! -s "$TEST_COMMANDS" ]]
rg -q '"cls":"config"' "$tmp_dir/output"
printf 'PASS: invalid script configuration blocks the push\n'
printf '{invalid json\n' >package.json
if run_checks; then
  printf 'FAIL: malformed manifest was accepted\n'
  exit 1
fi
rg -q '"cls":"config"' "$tmp_dir/output"
printf 'PASS: malformed manifests produce a configuration failure\n'
printf '{"scripts":{"typecheck":"tsc --noEmit"}}\n' >package.json
PRAGMA_SKIP_TESTS=1 run_checks
[[ ! -s "$TEST_COMMANDS" && ! -s "$tmp_dir/output" ]]
printf 'PASS: pre-push skip covers typechecking and tests\n'
for lockfile in bun.lock bun.lockb; do
  printf '{"scripts":{"typecheck":"tsc --noEmit"}}\n' >package.json
  touch "$lockfile"
  run_checks
  [[ "$(cat "$TEST_COMMANDS")" == $'run typecheck\ntest' ]]
  printf '{}\n' >package.json
  run_checks
  [[ "$(cat "$TEST_COMMANDS")" == test ]]
  rm "$lockfile"
done
printf 'PASS: Bun typechecking preserves native test discovery for both lockfiles\n'
