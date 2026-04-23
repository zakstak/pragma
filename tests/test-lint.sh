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

bin_dir="$tmp_dir/bin"
repo_dir="$tmp_dir/repo"
mkdir -p "$bin_dir" "$repo_dir/src"

cat >"$bin_dir/golangci-lint" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "version" ]]; then
  if [[ "${2:-}" == "--format" && "${3:-}" == "short" ]]; then
    printf '%s\n' "${TEST_GOLANGCI_VERSION:-v2.3.0}"
    exit 0
  fi

  if [[ "${2:-}" == "--short" ]]; then
    printf '%s\n' "${TEST_GOLANGCI_VERSION:-v2.3.0}"
    exit 0
  fi

  printf 'golangci-lint has version %s built with go1.25.0 from test\n' "${TEST_GOLANGCI_VERSION:-v2.3.0}"
  exit 0
fi

if [[ "$1" == "--version" ]]; then
  printf 'golangci-lint has version %s built with go1.25.0 from test\n' "${TEST_GOLANGCI_VERSION:-v2.3.0}"
  exit 0
fi

printf '%s\n' "$PWD" >"$TEST_CAPTURE_DIR/golangci.pwd"
printf '%s\n' "$*" >"$TEST_CAPTURE_DIR/golangci.args"
EOF
chmod +x "$bin_dir/golangci-lint"

cat >"$bin_dir/cargo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$TEST_CAPTURE_DIR/cargo.args"
EOF
chmod +x "$bin_dir/cargo"

cat >"$repo_dir/main.go" <<'EOF'
package main

func main() {}
EOF

cat >"$repo_dir/src/lib.rs" <<'EOF'
pub fn answer() -> u32 {
    42
}
EOF

(
  cd "$repo_dir"
  PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" TEST_CAPTURE_DIR="$tmp_dir" \
    bash "$PRAGMA_DIR/lib/lint.sh" main.go >/dev/null 2>&1
)

go_args="$(<"$tmp_dir/golangci.args")"
assert_contains "Go lint uses pragma default config" "--config $PRAGMA_DIR/.golangci.yml" "$go_args"
assert_contains "Go lint scopes to new changes" "--new-from-rev=HEAD" "$go_args"
assert_contains "Go lint does not autofix" "--fix=false" "$go_args"

(
  cd "$repo_dir"
  PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" TEST_CAPTURE_DIR="$tmp_dir" TEST_GOLANGCI_VERSION="v1.64.8" \
    bash "$PRAGMA_DIR/lib/lint.sh" main.go >/dev/null 2>&1
)

go_v1_args="$(<"$tmp_dir/golangci.args")"
assert_not_contains "Go lint skips bundled config for golangci-lint v1" "--config $PRAGMA_DIR/.golangci.yml" "$go_v1_args"

ln -s "$PRAGMA_DIR/.golangci.yml" "$repo_dir/.golangci.yml"

(
  cd "$repo_dir"
  PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" TEST_CAPTURE_DIR="$tmp_dir" TEST_GOLANGCI_VERSION="v1.64.8" \
    bash "$PRAGMA_DIR/lib/lint.sh" main.go >/dev/null 2>&1
)

self_v1_args="$(<"$tmp_dir/golangci.args")"
assert_not_contains "Repo symlink to pragma config is skipped for golangci-lint v1" "--config .golangci.yml" "$self_v1_args"

(
  cd "$repo_dir"
  PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" TEST_CAPTURE_DIR="$tmp_dir" TEST_GOLANGCI_VERSION="v2.3.0" \
    bash "$PRAGMA_DIR/lib/lint.sh" main.go >/dev/null 2>&1
)

self_v2_args="$(<"$tmp_dir/golangci.args")"
assert_contains "Repo symlink to pragma config is used for golangci-lint v2" "--config .golangci.yml" "$self_v2_args"

rm "$repo_dir/.golangci.yml"

cat >"$repo_dir/.golangci.toml" <<'EOF'
[linters]
default = "none"
EOF

(
  cd "$repo_dir"
  PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" TEST_CAPTURE_DIR="$tmp_dir" \
    bash "$PRAGMA_DIR/lib/lint.sh" main.go >/dev/null 2>&1
)

go_repo_args="$(<"$tmp_dir/golangci.args")"
assert_contains "Repo TOML config overrides pragma default" "--config .golangci.toml" "$go_repo_args"

rm "$repo_dir/.golangci.toml"

cat >"$repo_dir/.golangci.json" <<'EOF'
{
  "linters": {
    "default": "none"
  }
}
EOF

(
  cd "$repo_dir"
  PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" TEST_CAPTURE_DIR="$tmp_dir" \
    bash "$PRAGMA_DIR/lib/lint.sh" main.go >/dev/null 2>&1
)

go_repo_json_args="$(<"$tmp_dir/golangci.args")"
assert_contains "Repo JSON config overrides pragma default" "--config .golangci.json" "$go_repo_json_args"

mkdir -p "$repo_dir/tools/internal/goimports"
cat >"$repo_dir/tools/internal/goimports/go.mod" <<'EOF'
module example.com/goimports

go 1.25.0
EOF

cat >"$repo_dir/tools/internal/goimports/main.go" <<'EOF'
package main

func main() {}
EOF

(
  cd "$repo_dir"
  PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" TEST_CAPTURE_DIR="$tmp_dir" \
    bash "$PRAGMA_DIR/lib/lint.sh" tools/internal/goimports/main.go >/dev/null 2>&1
)

nested_go_pwd="$(<"$tmp_dir/golangci.pwd")"
assert_contains "Nested Go module lint runs from module root" "$repo_dir/tools/internal/goimports" "$nested_go_pwd"

(
  cd "$repo_dir"
  PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" TEST_CAPTURE_DIR="$tmp_dir" \
    bash "$PRAGMA_DIR/lib/lint.sh" src/lib.rs >/dev/null 2>&1
)

rust_args="$(<"$tmp_dir/cargo.args")"
assert_contains "Rust lint runs clippy" "clippy --all-targets --all-features -- -D warnings" "$rust_args"

printf '\nPassed: %s\n' "$PASS"
printf 'Failed: %s\n' "$FAIL"

exit "$FAIL"
