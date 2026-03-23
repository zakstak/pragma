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

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

bin_dir="$tmp_dir/bin"
repo_dir="$tmp_dir/repo"
mkdir -p "$bin_dir" "$repo_dir/src"

cat >"$bin_dir/golangci-lint" <<'EOF'
#!/usr/bin/env bash
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
  PATH="$bin_dir:$PATH" TEST_CAPTURE_DIR="$tmp_dir" \
    bash "$PRAGMA_DIR/lib/lint.sh" main.go >/dev/null 2>&1
)

go_args="$(<"$tmp_dir/golangci.args")"
assert_contains "Go lint uses pragma default config" "--config $PRAGMA_DIR/.golangci.yml" "$go_args"
assert_contains "Go lint scopes to new changes" "--new-from-rev=HEAD" "$go_args"
assert_contains "Go lint does not autofix" "--fix=false" "$go_args"

cat >"$repo_dir/.golangci.yml" <<'EOF'
version: "2"
EOF

(
  cd "$repo_dir"
  PATH="$bin_dir:$PATH" TEST_CAPTURE_DIR="$tmp_dir" \
    bash "$PRAGMA_DIR/lib/lint.sh" main.go >/dev/null 2>&1
)

go_repo_args="$(<"$tmp_dir/golangci.args")"
assert_contains "Repo Go config overrides pragma default" "--config .golangci.yml" "$go_repo_args"

(
  cd "$repo_dir"
  PATH="$bin_dir:$PATH" TEST_CAPTURE_DIR="$tmp_dir" \
    bash "$PRAGMA_DIR/lib/lint.sh" src/lib.rs >/dev/null 2>&1
)

rust_args="$(<"$tmp_dir/cargo.args")"
assert_contains "Rust lint runs clippy" "clippy --workspace --all-targets --all-features -- -D warnings" "$rust_args"

printf '\nPassed: %s\n' "$PASS"
printf 'Failed: %s\n' "$FAIL"

exit "$FAIL"
