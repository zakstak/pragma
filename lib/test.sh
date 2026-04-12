#!/usr/bin/env bash
# test.sh — Run test suites for all detected languages in the repo
# Used by pre-push hook (operates on full repo, not staged files)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/detect.sh"

PRAGMA_OUTPUT_FORMAT="${PRAGMA_OUTPUT_FORMAT:-gpt}"
TEST_RERUN="./lib/test.sh"
TEST_SKIP_CMD="PRAGMA_SKIP_TESTS=1 git push"

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
  log_info "Running TypeScript/JS tests..."

  # Prefer bun, then npm
  if [[ -f "bun.lock" ]] || [[ -f "bun.lockb" ]]; then
    if has_tool bun; then
      pragma_run "bun" "test" 1 "$TEST_SKIP_CMD" "$TEST_RERUN" "bun tests failed" bun test || return 1
      log_success "TypeScript tests passed (bun)"
      return 0
    fi
  fi

  if [[ -f "package.json" ]]; then
    # Check if a test script exists
    if grep -q '"test"' package.json 2>/dev/null; then
      if has_tool npm; then
        pragma_run "npm" "test" 1 "$TEST_SKIP_CMD" "$TEST_RERUN" "npm tests failed" npm test || return 1
        log_success "TypeScript tests passed (npm)"
        return 0
      else
        log_warn "npm not found, cannot run TypeScript tests"
        pragma_add_failure "npm" "tool" 1 "$TEST_SKIP_CMD" "$TEST_RERUN" "missing tool: npm" "" 1
        return 1
      fi
    else
      log_skip "No test script in package.json"
      return 0
    fi
  fi

  log_skip "No test runner found for TypeScript"
  return 0
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

  log_header "Running Tests"

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
