#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

assert_contains() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  if echo "$actual" | grep -Fq -- "$expected"; then
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s — expected %s\n' "$label" "$expected"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1"
  local unexpected="$2"
  local actual="$3"

  if echo "$actual" | grep -Fq -- "$unexpected"; then
    printf 'FAIL: %s — did not expect %s\n' "$label" "$unexpected"
    FAIL=$((FAIL + 1))
  else
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  fi
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

repo_dir="$tmp_dir/repo"
bin_dir="$tmp_dir/bin"
runtime_path="$tmp_dir/runtime-path"
mkdir -p "$repo_dir" "$bin_dir" "$runtime_path"

for tool in dirname find grep mkdir sh sort tr uname; do
  ln -s "$(command -v "$tool")" "$runtime_path/$tool"
done

cat >"$repo_dir/go.mod" <<'EOF'
module example.com/demo

go 1.25.0
EOF

cat >"$repo_dir/Cargo.toml" <<'EOF'
[package]
name = "demo"
version = "0.1.0"
edition = "2021"
EOF

for tool in lefthook gitleaks rustfmt cargo-clippy goimports; do
  cat >"$bin_dir/$tool" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$bin_dir/$tool"
done

cat >"$bin_dir/golangci-lint" <<'EOF'
#!/bin/sh
if [ "$1" = "version" ] && [ "$2" = "--format" ] && [ "$3" = "short" ]; then
  printf '%s\n' "${TEST_GOLANGCI_VERSION:-v2.3.0}"
  exit 0
fi

if [ "$1" = "version" ] && [ "$2" = "--short" ]; then
  printf '%s\n' "${TEST_GOLANGCI_VERSION:-v2.3.0}"
  exit 0
fi

if [ "$1" = "version" ] || [ "$1" = "--version" ]; then
  printf 'golangci-lint has version %s built with go1.25.0 from test\n' "${TEST_GOLANGCI_VERSION:-v2.3.0}"
  exit 0
fi

exit 0
EOF
chmod +x "$bin_dir/golangci-lint"

present_output="$(cd "$repo_dir" && PATH="$bin_dir:$runtime_path" /bin/bash "$PRAGMA_DIR/tools/install-tools.sh" --agent 2>&1)"
assert_contains "cargo-clippy satisfies clippy requirement" "clippy is available" "$present_output"
assert_not_contains "cargo-clippy does not trigger reinstall" "Adding clippy via rustup" "$present_output"
assert_contains "golangci-lint v2 satisfies Go requirement" "golangci-lint is available" "$present_output"

rm "$bin_dir/cargo-clippy"
rm "$bin_dir/golangci-lint"

cat >"$bin_dir/golangci-lint" <<'EOF'
#!/bin/sh
if [ "$1" = "version" ] && [ "$2" = "--format" ] && [ "$3" = "short" ]; then
  printf '%s\n' "v1.64.8"
  exit 0
fi

if [ "$1" = "version" ] && [ "$2" = "--short" ]; then
  printf '%s\n' "v1.64.8"
  exit 0
fi

if [ "$1" = "version" ] || [ "$1" = "--version" ]; then
  printf 'golangci-lint has version v1.64.8 built with go1.25.0 from test\n'
  exit 0
fi

exit 0
EOF
chmod +x "$bin_dir/golangci-lint"

cat >"$bin_dir/rustup" <<'EOF'
#!/bin/sh
printf '%s\n' "$*"
exit 0
EOF
chmod +x "$bin_dir/rustup"

cat >"$bin_dir/curl" <<'EOF'
#!/bin/sh
printf '%s\n' 'exit 0'
EOF
chmod +x "$bin_dir/curl"

missing_output="$(cd "$repo_dir" && PATH="$bin_dir:$runtime_path" /bin/bash "$PRAGMA_DIR/tools/install-tools.sh" --agent 2>&1)"
assert_contains "missing cargo-clippy is reported as clippy" "clippy is missing" "$missing_output"
assert_contains "missing cargo-clippy installs via rustup" "Adding clippy via rustup" "$missing_output"
assert_contains "golangci-lint v1 is treated as missing" "golangci-lint is missing" "$missing_output"
assert_contains "golangci-lint v1 triggers reinstall" "Installed golangci-lint" "$missing_output"

printf '\nPassed: %s\n' "$PASS"
printf 'Failed: %s\n' "$FAIL"

exit "$FAIL"
