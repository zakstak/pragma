#!/usr/bin/env bash
# test.sh — Run project typechecks and test suites before a push
# Used by pre-push hook (operates on full repo, not staged files)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/detect.sh"

PRAGMA_OUTPUT_FORMAT="${PRAGMA_OUTPUT_FORMAT:-gpt}"
TEST_RERUN="./lib/test.sh"
TEST_SKIP_CMD="PRAGMA_SKIP_TESTS=1 git push"

# Shadow comparisons are advisory and enabled unless explicitly opted out.
if [[ -n "${PRAGMA_SHADOW:-}" ]]; then
  SHADOW_ENABLED="$PRAGMA_SHADOW"
elif git config --get pragma.shadow >/dev/null 2>&1; then
  if ! SHADOW_ENABLED="$(git config --bool --get pragma.shadow 2>/dev/null)"; then
    printf 'Shadow capture skipped: local pragma.shadow must be a Git boolean.\n' >&2
    SHADOW_ENABLED=false
  fi
else
  SHADOW_ENABLED=true
fi
case "$SHADOW_ENABLED" in
  1 | true) SHADOW_ENABLED=true ;;
  0 | false) SHADOW_ENABLED=false ;;
  *)
    printf 'PRAGMA_SHADOW must be 0, 1, false, or true.\n' >&2
    if [[ ${1:-} == --shadow-only ]]; then exit 0; fi
    exit 2
    ;;
esac
SHADOW_ONLY=false
SHADOW_FORCED=false
if [[ ${1:-} == --shadow-only ]]; then
  SHADOW_ONLY=true
  shift
elif [[ ${1:-} == --shadow ]]; then
  SHADOW_FORCED=true
  SHADOW_ENABLED=true
  shift
fi
if [[ $# -ne 0 ]]; then
  printf 'Usage: %s [--shadow|--shadow-only]\n' "$0" >&2
  exit 2
fi
if ! pragma_enforce_thread_owner; then
  if $SHADOW_ONLY; then exit 0; fi
  exit 1
fi

run_shadow_typecheck() {
  local runner="$1" reader="$2" mode="${3:-required}" receipt_file receipt_dir status output
  if ! receipt_file="$(mktemp)"; then
    printf 'Shadow capture unavailable; running the normal typecheck.\n' >&2
    if [[ "$mode" == required ]]; then
      pragma_run "$runner" "typecheck" 1 "$TEST_SKIP_CMD" "$TEST_RERUN" "typescript typecheck failed" "$runner" run typecheck
      return $?
    fi
    return 0
  fi
  if pragma_exec "$reader" "$SCRIPT_DIR/shadow.js" "$runner" "$receipt_file" "$mode"; then
    status=0
  else
    status=$?
  fi
  receipt_dir="$(cat "$receipt_file")"
  rm -f "$receipt_file"
  if [[ "$mode" == advisory && $status -eq 0 && -z "$receipt_dir" ]]; then
    return 0
  fi
  # A capture setup error must not replace the normal compiler gate.
  if [[ ! -f "$receipt_dir/metadata.json" ]]; then
    printf 'Shadow capture unavailable; running the normal typecheck.\n' >&2
    if [[ "$mode" == required ]]; then
      pragma_run "$runner" "typecheck" 1 "$TEST_SKIP_CMD" "$TEST_RERUN" "typescript typecheck failed" "$runner" run typecheck
      return $?
    fi
    return 0
  fi
  if [[ "$mode" == advisory ]]; then
    return 0
  fi
  # A complete-looking receipt can never stand in for an unrun normal gate.
  if ! pragma_exec "$reader" -e '
    const fs = require("node:fs");
    const metadata = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    process.exit(metadata.baseline ? 0 : 1);
  ' "$receipt_dir/metadata.json"; then
    printf 'Shadow capture has no baseline; running the normal typecheck.\n' >&2
    pragma_run "$runner" "typecheck" 1 "$TEST_SKIP_CMD" "$TEST_RERUN" "typescript typecheck failed" "$runner" run typecheck
    return $?
  fi
  # Recover the baseline result if an artifact error interrupted finalization.
  if [[ $status == 125 ]]; then
    status="$(pragma_exec "$reader" -e '
      const fs = require("node:fs");
      const metadata = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const baseline = metadata.baseline;
      const signals = require("node:os").constants.signals;
      console.log(!baseline ? "not-run" : baseline.exit_code ?? (128 + (signals[baseline.signal] || 0)));
    ' "$receipt_dir/metadata.json")" || status=125
    if [[ "$status" == not-run ]]; then
      pragma_run "$runner" "typecheck" 1 "$TEST_SKIP_CMD" "$TEST_RERUN" "typescript typecheck failed" "$runner" run typecheck
      return $?
    fi
  fi
  if [[ $status -ne 0 ]]; then
    output="$(
      tail -n 5 "$receipt_dir/baseline.stdout.log"
      tail -n 5 "$receipt_dir/baseline.stderr.log"
    )"
    if pragma_human_output_enabled && [[ -n "$output" ]]; then
      printf '%s\n' "$output" >&2
    fi
    pragma_add_failure "$runner" "typecheck" 1 "$TEST_SKIP_CMD" "$TEST_RERUN" "typescript typecheck failed" "$output" "$status"
    return "$status"
  fi
}

# ─── Per-language test runners ────────────────────────────────────────────────

test_go() {
  if ! has_tool go; then
    log_warn "go not found, cannot run Go tests"
    pragma_add_failure "go" "tool" 1 "$TEST_SKIP_CMD" "$TEST_RERUN" "missing tool: go" "" 1
    return 1
  fi
  log_info "Running Go tests..."
  pragma_run "go" "test" 1 "$TEST_SKIP_CMD" "$TEST_RERUN" "go tests failed" go test ./... || return 1
  log_success "Go tests passed"
}

test_rust() {
  if ! has_tool cargo; then
    log_warn "cargo not found, cannot run Rust tests"
    pragma_add_failure "cargo" "tool" 1 "$TEST_SKIP_CMD" "$TEST_RERUN" "missing tool: cargo" "" 1
    return 1
  fi
  log_info "Running Rust tests..."
  pragma_run "cargo" "test" 1 "$TEST_SKIP_CMD" "$TEST_RERUN" "rust tests failed" cargo test || return 1
  log_success "Rust tests passed"
}

test_typescript() {
  local runner=npm reader=node scripts='' status
  local run_typecheck=false run_tests=false

  # Keep Bun's native test discovery for Bun projects.
  if [[ -f "bun.lock" || -f "bun.lockb" ]] && has_tool bun; then
    runner=bun
    run_tests=true
  fi

  if [[ -f "package.json" ]]; then
    if ! has_tool node; then
      if has_tool bun; then
        reader=bun
      else
        pragma_add_failure "node" "tool" 1 "$TEST_SKIP_CMD" "$TEST_RERUN" "node or bun is required to read package.json" "" 1
        return 1
      fi
    fi
    # shellcheck disable=SC2016 # The template literal belongs to JavaScript.
    if scripts="$(pragma_exec "$reader" -e '
      const fs = require("node:fs");
      try {
        const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
        const scripts = pkg.scripts ?? {};
        for (const name of ["typecheck", "test"]) {
          if (!Object.hasOwn(scripts, name)) continue;
          if (typeof scripts[name] !== "string" || !scripts[name].trim()) {
            throw new Error(`scripts.${name} must be a nonempty string`);
          }
          console.log(name);
        }
      } catch (error) {
        console.error(error.message);
        process.exit(1);
      }
    ' 2>&1)"; then
      [[ "$scripts" != *typecheck* ]] || run_typecheck=true
      [[ "$scripts" != *test* ]] || run_tests=true
    else
      status=$?
      pragma_add_failure "package.json" "config" 1 "$TEST_SKIP_CMD" "$TEST_RERUN" "cannot read project check scripts" "$scripts" "$status"
      return 1
    fi
  fi

  local inline_shadow="$SHADOW_ENABLED"
  if ! $SHADOW_FORCED && [[ -f prek.toml ]] && grep -Eq "^[[:space:]]*id[[:space:]]*=[[:space:]]*[\"']pragma-shadow[\"']" prek.toml; then
    inline_shadow=false
  fi
  if $inline_shadow && ! $run_typecheck; then
    run_shadow_typecheck "$runner" "$reader" advisory || return 1
  fi
  if ! $run_typecheck && ! $run_tests; then
    log_skip "No typecheck or test script in package.json"
    return 0
  fi
  if ! has_tool "$runner"; then
    pragma_add_failure "$runner" "tool" 1 "$TEST_SKIP_CMD" "$TEST_RERUN" "missing tool: $runner" "" 1
    return 1
  fi

  if $run_typecheck; then
    log_info "Running project typecheck ($runner)..."
    if $inline_shadow; then
      run_shadow_typecheck "$runner" "$reader" || return 1
    else
      pragma_run "$runner" "typecheck" 1 "$TEST_SKIP_CMD" "$TEST_RERUN" "typescript typecheck failed" "$runner" run typecheck || return 1
    fi
    log_success "TypeScript typecheck passed ($runner)"
  fi
  if $run_tests; then
    log_info "Running TypeScript/JS tests ($runner)..."
    pragma_run "$runner" "test" 1 "$TEST_SKIP_CMD" "$TEST_RERUN" "$runner tests failed" "$runner" test || return 1
    log_success "TypeScript tests passed ($runner)"
  fi
}

test_python() {
  if ! has_tool pytest && ! has_tool python; then
    log_warn "pytest/python not found, cannot run Python tests"
    pragma_add_failure "pytest" "tool" 1 "$TEST_SKIP_CMD" "$TEST_RERUN" "missing tool: pytest or python" "" 1
    return 1
  fi

  log_info "Running Python tests..."
  if has_tool pytest; then
    pragma_run "pytest" "test" 1 "$TEST_SKIP_CMD" "$TEST_RERUN" "python tests failed" pytest || return 1
  else
    pragma_run "python" "test" 1 "$TEST_SKIP_CMD" "$TEST_RERUN" "python tests failed" python -m pytest || return 1
  fi
  log_success "Python tests passed"
}

# ─── Dispatcher ───────────────────────────────────────────────────────────────

# Only languages that have test suites are included
TESTERS=(
  "go:test_go"
  "rust:test_rust"
  "typescript:test_typescript"
  "python:test_python"
)

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  pragma_set_context "pre-push" "test"

  if [[ "${PRAGMA_SKIP_TESTS:-0}" == "1" ]]; then
    exit 0
  fi

  if $SHADOW_ONLY; then
    if ! $SHADOW_ENABLED; then exit 0; fi
    local reader=node runner=npm
    if ! has_tool node; then
      if has_tool bun; then reader=bun; else
        printf 'Shadow capture unavailable: node or bun is required.\n' >&2
        exit 0
      fi
    fi
    if [[ -f bun.lock || -f bun.lockb ]] && has_tool bun; then runner=bun; fi
    run_shadow_typecheck "$runner" "$reader" advisory || true
    exit 0
  fi

  log_header "Running Pre-push Checks"

  local langs
  langs=$(detect_from_repo)

  if [[ -z "$langs" ]]; then
    log_skip "No recognized languages in repo"
    exit 0
  fi

  log_info "Detected languages: $(echo "$langs" | tr '\n' ' ')"

  for entry in "${TESTERS[@]}"; do
    local lang="${entry%%:*}"
    local func="${entry##*:}"
    if echo "$langs" | grep -qx "$lang"; then
      "$func" || record_failure
    fi
  done

  exit_with_status
}

main "$@"
