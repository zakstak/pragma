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

assert_command_fails() {
  local label="$1"
  shift

  if "$@" >/dev/null 2>&1; then
    log_error "FAIL: $label — command unexpectedly succeeded"
    FAIL=$((FAIL + 1))
  else
    log_success "PASS: $label"
    PASS=$((PASS + 1))
  fi
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# ─── Tests for detect_from_files ──────────────────────────────────────────────

log_header "detect_from_files"

# Go
result=$(detect_from_files main.go pkg/server.go)
assert_contains "Go files detected" "go" "$result"
assert_not_contains "No false Rust from Go" "rust" "$result"

# Rust
result=$(detect_from_files src/main.rs lib.rs)
assert_contains "Rust files detected" "rust" "$result"

# TypeScript
result=$(detect_from_files src/app.ts components/Button.tsx)
assert_contains "TypeScript files detected" "typescript" "$result"

# templ
result=$(detect_from_files views/page.templ)
assert_contains "templ files detected" "templ" "$result"

# Mixed
result=$(detect_from_files main.go src/lib.rs views/page.templ index.html config.yaml Dockerfile setup.sh README.md config.toml data.json app.py)
assert_contains "Mixed: go" "go" "$result"
assert_contains "Mixed: rust" "rust" "$result"
assert_contains "Mixed: templ" "templ" "$result"
assert_contains "Mixed: html" "html" "$result"
assert_contains "Mixed: yaml" "yaml" "$result"
assert_contains "Mixed: docker" "docker" "$result"
assert_contains "Mixed: shell" "shell" "$result"
assert_contains "Mixed: markdown" "markdown" "$result"
assert_contains "Mixed: toml" "toml" "$result"
assert_contains "Mixed: json" "json" "$result"
assert_contains "Mixed: python" "python" "$result"

result=$(detect_from_files dockerfile services/App.Dockerfile)
assert_contains "Portable dockerfile detection handles lowercase names" "docker" "$result"

filtered=()
filter_by_ext filtered ts md -- "dir/file with spaces.ts" "docs/README.md" "scripts/build.sh"
filtered_output="$(printf '%s\n' "${filtered[@]}")"
assert_contains "filter_by_ext keeps matching ts files" "dir/file with spaces.ts" "$filtered_output"
assert_contains "filter_by_ext keeps matching md files" "docs/README.md" "$filtered_output"
assert_not_contains "filter_by_ext excludes non-matching files" "scripts/build.sh" "$filtered_output"

assert_command_fails "filter_by_ext rejects invalid output variable names" filter_by_ext 'bad-name' ts -- file.ts

# Empty
result=$(detect_from_files)
assert_not_contains "Empty returns nothing" "go" "$result"

# JS/JSX
result=$(detect_from_files app.js component.jsx)
assert_contains "JS/JSX → typescript" "typescript" "$result"

# YML variant
result=$(detect_from_files ci.yml docker-compose.yaml)
assert_contains "yml extension" "yaml" "$result"

result=$(detect_from_files "dir/file with spaces.ts" "docs/README copy.md")
assert_contains "Spaces: typescript" "typescript" "$result"
assert_contains "Spaces: markdown" "markdown" "$result"

cat >"$tmp_dir/template.html" <<'EOF'
{% if user %}
  <div>{{ user.name }}</div>
{% endif %}
EOF

if html_file_contains_template_syntax "$tmp_dir/template.html"; then
  log_success "PASS: HTML template syntax is detected"
  PASS=$((PASS + 1))
else
  log_error "FAIL: HTML template syntax should be detected"
  FAIL=$((FAIL + 1))
fi

cat >"$tmp_dir/plain.html" <<'EOF'
<div hx-get="/users" hx-trigger="click">Open</div>
EOF

if html_file_contains_template_syntax "$tmp_dir/plain.html"; then
  log_error "FAIL: Plain HTML with HTMX should not be treated as template syntax"
  FAIL=$((FAIL + 1))
else
  log_success "PASS: Plain HTML with HTMX is not treated as template syntax"
  PASS=$((PASS + 1))
fi

# ─── Tests for detect_from_repo ───────────────────────────────────────────────

log_header "detect_from_repo (in pragma dir)"

# Run from pragma repo — should detect at least shell and markdown
result=$(cd "$SCRIPT_DIR/.." && detect_from_repo)
assert_contains "Pragma repo: shell" "shell" "$result"
assert_contains "Pragma repo: markdown" "markdown" "$result"
assert_contains "Pragma repo: toml" "toml" "$result"
assert_contains "Pragma repo: yaml" "yaml" "$result"

portable_repo="$tmp_dir/portable-detect"
mkdir -p "$portable_repo/src/level2" "$portable_repo/src/level2/level3" "$portable_repo/node_modules/pkg" "$portable_repo/frontend/node_modules/pkg" "$portable_repo/.git/info"
touch "$portable_repo/src/level2/app.py"
touch "$portable_repo/src/level2/view.templ"
touch "$portable_repo/src/level2/level3/ignored.sh"
touch "$portable_repo/node_modules/pkg/ignored.json"
touch "$portable_repo/frontend/node_modules/pkg/nested.json"
touch "$portable_repo/.git/info/ignored.yaml"

result=$(cd "$portable_repo" && detect_from_repo)
assert_contains "Portable repo scan includes files within depth 3" "python" "$result"
assert_contains "Portable repo scan includes templ files within depth 3" "templ" "$result"
assert_not_contains "Portable repo scan excludes files deeper than depth 3" "shell" "$result"
assert_not_contains "Portable repo scan excludes node_modules matches" "json" "$result"
assert_not_contains "Portable repo scan excludes nested node_modules matches" "json" "$result"
assert_not_contains "Portable repo scan excludes .git matches" "yaml" "$result"

venv_repo="$tmp_dir/venv-detect"
mkdir -p "$venv_repo/.venv/bin"
touch "$venv_repo/.venv/bin/ignored.py"

result=$(cd "$venv_repo" && detect_from_repo)
assert_not_contains "Portable repo scan excludes .venv Python markers" "python" "$result"

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
log_header "Results"
log_info "Passed: $PASS"
if [[ $FAIL -gt 0 ]]; then
  log_error "Failed: $FAIL"
else
  log_success "Failed: $FAIL"
fi

exit "$FAIL"
