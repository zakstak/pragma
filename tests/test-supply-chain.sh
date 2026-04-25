#!/usr/bin/env bash
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

assert_contains "Dockerfile pins base image digest" "@sha256:" "$PRAGMA_DIR/Dockerfile"
assert_contains "Dockerfile uses npm ci" "npm ci --ignore-scripts --no-fund --no-audit" "$PRAGMA_DIR/Dockerfile"
assert_contains "Dockerfile uses hashed Python requirements" "pip install --break-system-packages --no-cache-dir --require-hashes -r /tmp/pragma-python-requirements.txt" "$PRAGMA_DIR/Dockerfile"
assert_contains "Dockerfile builds pinned goimports module" "go build -C /tmp/goimports -mod=readonly -o /usr/local/bin/goimports golang.org/x/tools/cmd/goimports" "$PRAGMA_DIR/Dockerfile"
assert_contains "Dockerfile builds pinned templ module" "go build -C /tmp/templ -mod=readonly -o /usr/local/bin/templ github.com/a-h/templ/cmd/templ" "$PRAGMA_DIR/Dockerfile"
assert_contains "Dockerfile extracts checksum entries robustly" "\$2 == asset || \$2 == \"*\" asset { print; exit }" "$PRAGMA_DIR/Dockerfile"
assert_not_contains "Dockerfile avoids brittle golangci two-space grep" "grep \"  \$golangci_asset\$\"" "$PRAGMA_DIR/Dockerfile"
assert_not_contains "Dockerfile avoids brittle gitleaks two-space grep" "grep \"  \$gitleaks_asset\$\"" "$PRAGMA_DIR/Dockerfile"
assert_not_contains "Dockerfile avoids global npm install" "npm install --global" "$PRAGMA_DIR/Dockerfile"
assert_not_contains "Dockerfile avoids pip install without hashes" "pip install --break-system-packages --no-cache-dir \\" "$PRAGMA_DIR/Dockerfile"
assert_not_contains "Dockerfile avoids go install" " go install " "$PRAGMA_DIR/Dockerfile"
assert_not_contains "Dockerfile avoids cargo install" "cargo install" "$PRAGMA_DIR/Dockerfile"

assert_contains "Installer uses npm ci" "npm ci --ignore-scripts --no-fund --no-audit --prefix \"\$PRAGMA_DIR/.npm-packages\"" "$PRAGMA_DIR/tools/install-tools.sh"
assert_contains "Installer uses hashed Python requirements" "install --quiet --require-hashes -r \"\$requirements_file\"" "$PRAGMA_DIR/tools/install-tools.sh"
assert_contains "Installer builds pinned goimports module" "go build -C \"\$PRAGMA_DIR/tools/internal/goimports\" -mod=readonly -o \"\$BIN_DIR/goimports\" golang.org/x/tools/cmd/goimports" "$PRAGMA_DIR/tools/install-tools.sh"
assert_contains "Installer builds pinned templ module" "go build -C \"\$PRAGMA_DIR/tools/internal/templ\" -mod=readonly -o \"\$BIN_DIR/templ\" github.com/a-h/templ/cmd/templ" "$PRAGMA_DIR/tools/install-tools.sh"
assert_not_contains "Installer avoids bun auto-installs" "bun install -g" "$PRAGMA_DIR/tools/install-tools.sh"
assert_not_contains "Installer avoids pipx auto-installs" "pipx install" "$PRAGMA_DIR/tools/install-tools.sh"
assert_not_contains "Installer avoids uv tool installs" "uv tool install" "$PRAGMA_DIR/tools/install-tools.sh"
assert_not_contains "Installer avoids go install" " go install " "$PRAGMA_DIR/tools/install-tools.sh"
assert_not_contains "Installer avoids latest references" "@latest" "$PRAGMA_DIR/tools/install-tools.sh"

assert_contains "Host Python requirements file exists" "ruff==0.15.11" "$PRAGMA_DIR/tools/requirements/host-python.txt"
assert_contains "Docker Python requirements file exists" "pytest==9.0.3" "$PRAGMA_DIR/tools/requirements/docker-python.txt"
assert_contains "npm lockfile includes prettier" '"prettier": "3.8.3"' "$PRAGMA_DIR/.npm-packages/package-lock.json"
assert_contains "npm lockfile includes eslint" '"eslint": "9.39.4"' "$PRAGMA_DIR/.npm-packages/package-lock.json"
assert_contains "Repo ignores local venv" ".venv/" "$PRAGMA_DIR/.gitignore"

printf '\nPassed: %s\n' "$PASS"
printf 'Failed: %s\n' "$FAIL"

exit "$FAIL"
