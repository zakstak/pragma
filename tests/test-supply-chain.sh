#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions match literal shell snippets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

assert_contains() {
  local label="$1"
  local expected="$2"
  local path="$3"

  if grep -Fq -- "$expected" "$path"; then
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s — missing %s in %s\n' "$label" "$expected" "$path"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1"
  local unexpected="$2"
  local path="$3"

  if grep -Fq -- "$unexpected" "$path"; then
    printf 'FAIL: %s — found %s in %s\n' "$label" "$unexpected" "$path"
    FAIL=$((FAIL + 1))
  else
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  fi
}

assert_contains "Installer uses npm ci" 'npm ci --ignore-scripts --no-fund --no-audit --prefix "$PRAGMA_DIR/.npm-packages"' "$PRAGMA_DIR/tools/install-tools.sh"
assert_contains "Installer uses hashed Python requirements" 'install --quiet --require-hashes -r "$requirements_file"' "$PRAGMA_DIR/tools/install-tools.sh"
assert_contains "Installer extracts checksum entries robustly" '$2 == asset || $2 == "*" asset { print; exit }' "$PRAGMA_DIR/tools/install-tools.sh"
assert_not_contains "Installer avoids unchecked download helpers" "download_tarball()" "$PRAGMA_DIR/tools/install-tools.sh"
assert_not_contains "Installer avoids latest references" "@latest" "$PRAGMA_DIR/tools/install-tools.sh"
assert_contains "Installer restores pinned goimports build" "go build" "$PRAGMA_DIR/tools/install-tools.sh"
assert_contains "Python requirements pin ruff" "ruff==0.17.0" "$PRAGMA_DIR/tools/requirements/python.txt"
assert_contains "Python requirements pin pytest" "pytest==9.1.1" "$PRAGMA_DIR/tools/requirements/python.txt"
assert_contains "npm lockfile includes prettier" '"prettier": "3.9.10"' "$PRAGMA_DIR/.npm-packages/package-lock.json"
assert_contains "npm lockfile includes oxlint" '"oxlint": "1.87.0"' "$PRAGMA_DIR/.npm-packages/package-lock.json"
assert_contains "Repo ignores local venv" ".venv/" "$PRAGMA_DIR/.gitignore"

printf '\nPassed: %s\n' "$PASS"
printf 'Failed: %s\n' "$FAIL"

exit "$FAIL"
