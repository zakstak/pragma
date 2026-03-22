#!/usr/bin/env bash
# test.sh — Run test suites for all detected languages in the repo
# Used by pre-push hook (operates on full repo, not staged files)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/detect.sh"

# ─── Per-language test runners ────────────────────────────────────────────────

test_go() {
  if ! has_tool go; then
    log_warn "go not found, skipping Go tests"
    return 1
  fi
  log_info "Running Go tests..."
  go test ./... 2>&1 || {
    log_error "Go tests failed"
    return 1
  }
  log_success "Go tests passed"
}

test_rust() {
  if ! has_tool cargo; then
    log_warn "cargo not found, skipping Rust tests"
    return 1
  fi
  log_info "Running Rust tests..."
  cargo test 2>&1 || {
    log_error "Rust tests failed"
    return 1
  }
  log_success "Rust tests passed"
}

test_typescript() {
  log_info "Running TypeScript/JS tests..."

  # Prefer bun, then npm
  if [[ -f "bun.lock" ]] || [[ -f "bun.lockb" ]]; then
    if has_tool bun; then
      bun test 2>&1 || {
        log_error "Bun tests failed"
        return 1
      }
      log_success "TypeScript tests passed (bun)"
      return 0
    fi
  fi

  if [[ -f "package.json" ]]; then
    # Check if a test script exists
    if grep -q '"test"' package.json 2>/dev/null; then
      if has_tool npm; then
        npm test 2>&1 || {
          log_error "npm tests failed"
          return 1
        }
        log_success "TypeScript tests passed (npm)"
        return 0
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
    log_warn "pytest/python not found, skipping Python tests"
    return 1
  fi

  log_info "Running Python tests..."
  if has_tool pytest; then
    pytest 2>&1 || {
      log_error "Python tests failed"
      return 1
    }
  else
    python -m pytest 2>&1 || {
      log_error "Python tests failed"
      return 1
    }
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
