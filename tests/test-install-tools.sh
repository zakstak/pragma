#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

copy_tree() {
  local source_dir="$1"
  local target_dir="$2"

  mkdir -p "$target_dir"
  cp -R "$source_dir/." "$target_dir"
}

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

capture_command_result() {
  local output
  local status_code

  set +e
  output="$("$@" 2>&1)"
  status_code=$?
  set -e

  CAPTURED_OUTPUT="$output"
  CAPTURED_STATUS=$status_code
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

cat >"$repo_dir/page.templ" <<'EOF'
templ Page() {
  <div>Hello</div>
}
EOF

for tool in prek gitleaks rustfmt goimports prettier templ; do
  cat >"$bin_dir/$tool" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$bin_dir/$tool"
done

cat >"$bin_dir/cargo" <<'EOF'
#!/bin/sh
if [ "$1" = "clippy" ] && [ "$2" = "--version" ]; then
  if [ "${TEST_CARGO_HAS_CLIPPY:-1}" = "1" ]; then
    printf '%s\n' "clippy 0.1.0 (test)"
    exit 0
  fi

  printf '%s\n' 'error: no such command: `clippy`' >&2
  exit 101
fi

exit 0
EOF
chmod +x "$bin_dir/cargo"

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

present_output="$(cd "$repo_dir" && PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$runtime_path" /bin/bash "$PRAGMA_DIR/tools/install-tools.sh" --agent 2>&1)"
assert_contains "cargo clippy subcommand satisfies clippy requirement" "clippy is available" "$present_output"
assert_not_contains "available cargo clippy does not trigger reinstall" "Adding clippy via rustup" "$present_output"
assert_contains "golangci-lint v2 satisfies Go requirement" "golangci-lint is available" "$present_output"
assert_contains "templ satisfies templ requirement" "templ is available" "$present_output"

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

cat >"$bin_dir/clippy" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$bin_dir/clippy"

cat >"$bin_dir/go" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$TEST_CAPTURE_DIR/go.args"
exit 0
EOF
chmod +x "$bin_dir/go"

rm -f "$bin_dir/templ"

missing_output="$(cd "$repo_dir" && PRAGMA_SKIP_INTERNAL_BIN_PATH=1 TEST_CARGO_HAS_CLIPPY=0 TEST_CAPTURE_DIR="$tmp_dir" PATH="$bin_dir:$runtime_path" /bin/bash "$PRAGMA_DIR/tools/install-tools.sh" --agent 2>&1)"
assert_contains "standalone clippy without cargo subcommand is reported missing" "clippy is missing" "$missing_output"
assert_contains "missing cargo clippy subcommand installs via rustup" "Adding clippy via rustup" "$missing_output"
assert_contains "golangci-lint v1 is accepted" "golangci-lint is available" "$missing_output"
assert_not_contains "golangci-lint v1 does not trigger reinstall" "Installed golangci-lint" "$missing_output"
assert_contains "missing templ installs via pinned module source" "Installing templ via pinned module source..." "$missing_output"

templ_go_args="$(<"$tmp_dir/go.args")"
assert_contains "templ install builds pinned module" "build -C $PRAGMA_DIR/tools/internal/templ -mod=readonly -o $PRAGMA_DIR/bin/templ github.com/a-h/templ/cmd/templ" "$templ_go_args"

unsupported_repo="$tmp_dir/pragma-unsupported"
copy_tree "$PRAGMA_DIR" "$unsupported_repo"
rm -rf "${unsupported_repo:?}/bin"

unsupported_runtime="$tmp_dir/unsupported-runtime"
mkdir -p "$unsupported_runtime"
cat >"$unsupported_runtime/uname" <<'EOF'
#!/bin/sh
printf '%s\n' Windows_NT
EOF
chmod +x "$unsupported_runtime/uname"

capture_command_result env PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$unsupported_runtime:$runtime_path" /bin/bash "$unsupported_repo/tools/install-tools.sh" --agent
unsupported_output="$CAPTURED_OUTPUT"

if [[ $CAPTURED_STATUS -eq 0 ]]; then
  printf 'FAIL: unsupported host unexpectedly succeeded\n'
  FAIL=$((FAIL + 1))
else
  assert_contains "unsupported host fails with explicit installer message" "Unsupported host: Pragma bootstrap/install-tools are supported on macOS and Linux only." "$unsupported_output"
fi
assert_not_contains "unsupported host stops before tool detection" "Detected languages:" "$unsupported_output"

if [[ ! -d "$unsupported_repo/bin" ]]; then
  printf 'PASS: unsupported host does not create tool install artifacts\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: unsupported host unexpectedly created tool install artifacts\n'
  FAIL=$((FAIL + 1))
fi

printf '\nPassed: %s\n' "$PASS"
printf 'Failed: %s\n' "$FAIL"

exit "$FAIL"
