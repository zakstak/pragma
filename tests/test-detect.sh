#!/usr/bin/env bash
# test-detect.sh — Test language detection logic
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/detect.sh"

PASS=0
FAIL=0

assert_contains() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  if echo "$actual" | grep -qx "$expected"; then
    log_success "PASS: $label"
    PASS=$((PASS + 1))
  else
    log_error "FAIL: $label — expected '$expected' in output"
    echo "  Got: $(echo "$actual" | tr '\n' ' ')"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1"
  local unexpected="$2"
  local actual="$3"

  if ! echo "$actual" | grep -qx "$unexpected"; then
    log_success "PASS: $label"
    PASS=$((PASS + 1))
  else
    log_error "FAIL: $label — did not expect '$unexpected' in output"
    FAIL=$((FAIL + 1))
  fi
}

# ─── Tests for detect_from_files ──────────────────────────────────────────────

log_header "detect_from_files"

# Go
result=$(detect_from_files "main.go pkg/server.go")
assert_contains "Go files detected" "go" "$result"
assert_not_contains "No false Rust from Go" "rust" "$result"

# Rust
result=$(detect_from_files "src/main.rs lib.rs")
assert_contains "Rust files detected" "rust" "$result"

# TypeScript
result=$(detect_from_files "src/app.ts components/Button.tsx")
assert_contains "TypeScript files detected" "typescript" "$result"

# Mixed
result=$(detect_from_files "main.go src/lib.rs index.html config.yaml Dockerfile setup.sh README.md config.toml data.json app.py")
assert_contains "Mixed: go" "go" "$result"
assert_contains "Mixed: rust" "rust" "$result"
assert_contains "Mixed: html" "html" "$result"
assert_contains "Mixed: yaml" "yaml" "$result"
assert_contains "Mixed: docker" "docker" "$result"
assert_contains "Mixed: shell" "shell" "$result"
assert_contains "Mixed: markdown" "markdown" "$result"
assert_contains "Mixed: toml" "toml" "$result"
assert_contains "Mixed: json" "json" "$result"
assert_contains "Mixed: python" "python" "$result"

# Empty
result=$(detect_from_files "")
assert_not_contains "Empty returns nothing" "go" "$result"

# JS/JSX
result=$(detect_from_files "app.js component.jsx")
assert_contains "JS/JSX → typescript" "typescript" "$result"

# YML variant
result=$(detect_from_files "ci.yml docker-compose.yaml")
assert_contains "yml extension" "yaml" "$result"

# ─── Tests for detect_from_repo ───────────────────────────────────────────────

log_header "detect_from_repo (in pragma dir)"

# Run from pragma repo — should detect at least shell and markdown
result=$(cd "$SCRIPT_DIR/.." && detect_from_repo)
assert_contains "Pragma repo: shell" "shell" "$result"
assert_contains "Pragma repo: markdown" "markdown" "$result"
assert_contains "Pragma repo: toml" "toml" "$result"
assert_contains "Pragma repo: yaml" "yaml" "$result"

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
log_header "Results"
log_info "Passed: $PASS"
[[ $FAIL -gt 0 ]] && log_error "Failed: $FAIL" || log_success "Failed: $FAIL"

exit "$FAIL"
