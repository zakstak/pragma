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
  [[ "${2:-}" == "--short" ]] || exit 2
  printf '%s\n' "${TEST_GOLANGCI_VERSION:-v2.14.0}"
  exit 0
fi

printf '%s\n' "$PWD" >"$TEST_CAPTURE_DIR/golangci.pwd"
printf '%s\n' "$*" >"$TEST_CAPTURE_DIR/golangci.args"
EOF
chmod +x "$bin_dir/golangci-lint"

cat >"$bin_dir/go" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$TEST_CAPTURE_DIR/go.args"
EOF
chmod +x "$bin_dir/go"

git init -q "$repo_dir"
git -C "$repo_dir" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m fixture

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

unborn_repo="$tmp_dir/unborn"
git init -q "$unborn_repo"
printf 'package main\nfunc main() {}\n' >"$unborn_repo/main.go"
(
  cd "$unborn_repo"
  PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" TEST_CAPTURE_DIR="$tmp_dir" \
    bash "$PRAGMA_DIR/lib/lint.sh" main.go >/dev/null 2>&1
)
assert_not_contains "First commit lint does not reference nonexistent HEAD" "--new-from-rev" "$(<"$tmp_dir/golangci.args")"

rm "$tmp_dir/golangci.args"
set +e
old_output="$(cd "$repo_dir" && PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" TEST_CAPTURE_DIR="$tmp_dir" TEST_GOLANGCI_VERSION=v1.64.8 bash "$PRAGMA_DIR/lib/lint.sh" main.go 2>&1)"
old_status=$?
set -e
assert_contains "Old linter reports the v2 requirement" "golangci-lint v2 is required" "$old_output"
if [[ $old_status -ne 0 && ! -f "$tmp_dir/golangci.args" && ! -f "$tmp_dir/go.args" ]]; then
  printf 'PASS: v1 is rejected without linting or a go vet fallback\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: v1 must be rejected without a fallback\n'
  FAIL=$((FAIL + 1))
fi

ln -s "$PRAGMA_DIR/.golangci.yml" "$repo_dir/.golangci.yml"

(
  cd "$repo_dir"
  PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" TEST_CAPTURE_DIR="$tmp_dir" TEST_GOLANGCI_VERSION="v2.14.0" \
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
nest_go_args="$(<"$tmp_dir/golangci.args")"
assert_contains "Nested Go module lint runs from module root" "$repo_dir/tools/internal/goimports" "$nested_go_pwd"
assert_contains "Nested Go module lint uses repo-relative config path" "--config ../../../.golangci.json" "$nest_go_args"

mkdir -p "$repo_dir/vendor/example"
cat >"$repo_dir/vendor/example/lib.go" <<'EOF'
package example

func Answer() int {
    return 42
}
EOF

rm -f "$tmp_dir/golangci.args" "$tmp_dir/golangci.pwd"

(
  cd "$repo_dir"
  PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" TEST_CAPTURE_DIR="$tmp_dir" \
    bash "$PRAGMA_DIR/lib/lint.sh" vendor/example/lib.go >/dev/null 2>&1
)

if [[ ! -f "$tmp_dir/golangci.args" ]]; then
  printf 'PASS: %s\n' "Vendored Go files are skipped"
  PASS=$((PASS + 1))
else
  printf 'FAIL: %s — expected golangci-lint to be skipped for vendored files\n' "Vendored Go files are skipped"
  FAIL=$((FAIL + 1))
fi

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
