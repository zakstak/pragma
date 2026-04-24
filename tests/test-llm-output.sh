#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
CAPTURED_OUTPUT=''
CAPTURED_STATUS=0

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

assert_single_line() {
  local label="$1"
  local actual="$2"

  if [[ "$actual" == *$'\n'* ]]; then
    printf 'FAIL: %s — expected single-line output\n' "$label"
    FAIL=$((FAIL + 1))
  else
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  fi
}

assert_empty() {
  local label="$1"
  local actual="$2"

  if [[ -z "$actual" ]]; then
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s — expected empty output\n' "$label"
    FAIL=$((FAIL + 1))
  fi
}

assert_status() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  if [[ "$actual" == "$expected" ]]; then
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s — expected status %s, got %s\n' "$label" "$expected" "$actual"
    FAIL=$((FAIL + 1))
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

bin_dir="$tmp_dir/bin"
mkdir -p "$bin_dir"

format_repo="$tmp_dir/format-repo"
mkdir -p "$format_repo"
git init -q "$format_repo"
cat >"$format_repo/index.js" <<'EOF'
export const answer = 42;
EOF

cat >"$bin_dir/prettier" <<'EOF'
#!/usr/bin/env bash
printf 'SyntaxError: unexpected token\nline 4\n'
exit 2
EOF
chmod +x "$bin_dir/prettier"

capture_command_result env PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" PRAGMA_OUTPUT_FORMAT=gpt bash -c "cd \"$format_repo\" && \"$PRAGMA_DIR/lib/format.sh\" index.js"
assert_status "Format failure exits non-zero" 1 "$CAPTURED_STATUS"
assert_single_line "Format failure stays single-line" "$CAPTURED_OUTPUT"
assert_contains "Format failure emits pre-commit hook" '"hook":"pre-commit"' "$CAPTURED_OUTPUT"
assert_contains "Format failure emits format step" '"step":"format"' "$CAPTURED_OUTPUT"
assert_contains "Format failure emits prettier tool" '"tool":"prettier"' "$CAPTURED_OUTPUT"
assert_contains "Format failure emits compact message" '"msg":"typescript formatting failed"' "$CAPTURED_OUTPUT"
assert_contains "Format failure keeps output tail" '"tail":"SyntaxError: unexpected token\nline 4"' "$CAPTURED_OUTPUT"

cat >"$bin_dir/prettier" <<'EOF'
#!/usr/bin/env bash
printf '\033[31mboom\033[0m\nnext\n'
exit 2
EOF
chmod +x "$bin_dir/prettier"

capture_command_result env PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" PRAGMA_OUTPUT_FORMAT=gpt bash -c "cd \"$format_repo\" && \"$PRAGMA_DIR/lib/format.sh\" index.js"
assert_status "GPT format failure with ANSI exits non-zero" 1 "$CAPTURED_STATUS"
assert_single_line "GPT format failure with ANSI stays single-line" "$CAPTURED_OUTPUT"
assert_not_contains "GPT format failure strips escape byte" $'\033' "$CAPTURED_OUTPUT"
assert_not_contains "GPT format failure strips ANSI markers" '[31m' "$CAPTURED_OUTPUT"
assert_contains "GPT format failure keeps sanitized tail" '"tail":"boom\nnext"' "$CAPTURED_OUTPUT"

long_tail="BEGIN$(printf 'x%.0s' $(seq 1 340))END"
cat >"$bin_dir/prettier" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$long_tail'
exit 2
EOF
chmod +x "$bin_dir/prettier"

capture_command_result env PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" PRAGMA_OUTPUT_FORMAT=gpt bash -c "cd \"$format_repo\" && \"$PRAGMA_DIR/lib/format.sh\" index.js"
assert_status "GPT long-line failure exits non-zero" 1 "$CAPTURED_STATUS"
assert_single_line "GPT long-line failure stays single-line" "$CAPTURED_OUTPUT"
assert_not_contains "GPT long-line failure trims leading marker" 'BEGIN' "$CAPTURED_OUTPUT"
assert_contains "GPT long-line failure keeps trailing marker" 'END"' "$CAPTURED_OUTPUT"

cat >"$bin_dir/prettier" <<'EOF'
#!/usr/bin/env bash
printf 'SyntaxError: unexpected token\nline 4\n'
exit 2
EOF
chmod +x "$bin_dir/prettier"

capture_command_result env PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" PRAGMA_OUTPUT_FORMAT=human bash -c "cd \"$format_repo\" && \"$PRAGMA_DIR/lib/format.sh\" index.js"
assert_status "Human format failure exits non-zero" 1 "$CAPTURED_STATUS"
assert_contains "Human format failure replays tool output" 'SyntaxError: unexpected token' "$CAPTURED_OUTPUT"
assert_not_contains "Human format failure does not emit JSON envelope" '"fails":' "$CAPTURED_OUTPUT"

cat >"$bin_dir/prettier" <<'EOF'
#!/usr/bin/env bash
printf 'formatted %s\n' "$*"
exit 0
EOF
chmod +x "$bin_dir/prettier"

capture_command_result env PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" PRAGMA_OUTPUT_FORMAT=gpt bash -c "cd \"$format_repo\" && \"$PRAGMA_DIR/lib/format.sh\" index.js"
assert_status "Format success exits zero" 0 "$CAPTURED_STATUS"
assert_empty "Format success stays silent" "$CAPTURED_OUTPUT"

cat >"$format_repo/template.html" <<'EOF'
{% if user %}
  <div>{{ user.name }}</div>
{% endif %}
EOF

cat >"$bin_dir/prettier" <<'EOF'
#!/usr/bin/env bash
printf 'prettier should not run for templated html\n'
exit 9
EOF
chmod +x "$bin_dir/prettier"

capture_command_result env PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" PRAGMA_OUTPUT_FORMAT=gpt bash -c "cd \"$format_repo\" && \"$PRAGMA_DIR/lib/format.sh\" template.html"
assert_status "Templated HTML skip exits zero" 0 "$CAPTURED_STATUS"
assert_empty "Templated HTML skip stays silent in GPT mode" "$CAPTURED_OUTPUT"

cat >"$format_repo/plain.html" <<'EOF'
<div hx-get="/users" hx-trigger="click">Open</div>
EOF

capture_command_result env PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" PRAGMA_OUTPUT_FORMAT=gpt bash -c "cd \"$format_repo\" && \"$PRAGMA_DIR/lib/format.sh\" plain.html"
assert_status "Plain HTML still uses formatter and fails" 1 "$CAPTURED_STATUS"
assert_contains "Plain HTML formatter failure keeps html message" '"msg":"html formatting failed"' "$CAPTURED_OUTPUT"

cat >"$format_repo/page.templ" <<'EOF'
templ Page() {
  <div>Hello</div>
}
EOF

cat >"$bin_dir/templ" <<'EOF'
#!/usr/bin/env bash
printf 'templ parse error\nline 2\n'
exit 2
EOF
chmod +x "$bin_dir/templ"

capture_command_result env PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" PRAGMA_OUTPUT_FORMAT=gpt bash -c "cd \"$format_repo\" && \"$PRAGMA_DIR/lib/format.sh\" page.templ"
assert_status "templ format failure exits non-zero" 1 "$CAPTURED_STATUS"
assert_single_line "templ format failure stays single-line" "$CAPTURED_OUTPUT"
assert_contains "templ format failure emits templ tool" '"tool":"templ"' "$CAPTURED_OUTPUT"
assert_contains "templ format failure emits templ message" '"msg":"templ formatting failed"' "$CAPTURED_OUTPUT"

cat >"$bin_dir/templ" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$bin_dir/templ"

capture_command_result env PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" PRAGMA_OUTPUT_FORMAT=gpt bash -c "cd \"$format_repo\" && \"$PRAGMA_DIR/lib/format.sh\" page.templ"
assert_status "templ format success exits zero" 0 "$CAPTURED_STATUS"
assert_empty "templ format success stays silent" "$CAPTURED_OUTPUT"

cat >"$bin_dir/rustfmt" <<'EOF'
#!/usr/bin/env bash
printf 'rustfmt partial-file failure\n'
exit 1
EOF
chmod +x "$bin_dir/rustfmt"

cat >"$bin_dir/cargo" <<'EOF'
#!/usr/bin/env bash
printf 'cargo fmt repaired workspace\n'
exit 0
EOF
chmod +x "$bin_dir/cargo"

mkdir -p "$format_repo/src"
cat >"$format_repo/src/lib.rs" <<'EOF'
pub fn answer() -> u32 {
    42
}
EOF
cat >"$format_repo/src/extra.rs" <<'EOF'
pub fn extra() -> u32 {
    7
}
EOF
git -C "$format_repo" add index.js src/lib.rs src/extra.rs

capture_command_result env PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" PRAGMA_OUTPUT_FORMAT=gpt bash -c "cd \"$format_repo\" && \"$PRAGMA_DIR/lib/format.sh\" src/lib.rs"
assert_status "Rust fallback success exits zero" 0 "$CAPTURED_STATUS"
assert_empty "Rust fallback success stays silent" "$CAPTURED_OUTPUT"

cat >"$bin_dir/cargo" <<'EOF'
#!/usr/bin/env bash
printf 'cargo fmt touched sibling\n'
printf '// touched by cargo fmt\n' >> "$TEST_EXTRA_RUST"
exit 0
EOF
chmod +x "$bin_dir/cargo"

capture_command_result env PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" TEST_EXTRA_RUST="$format_repo/src/extra.rs" PRAGMA_OUTPUT_FORMAT=gpt bash -c "cd \"$format_repo\" && \"$PRAGMA_DIR/lib/format.sh\" src/lib.rs"
assert_status "Rust fallback touching extra files exits non-zero" 1 "$CAPTURED_STATUS"
assert_single_line "Rust fallback extra-file failure stays single-line" "$CAPTURED_OUTPUT"
assert_contains "Rust fallback extra-file failure uses cargo tool" '"tool":"cargo"' "$CAPTURED_OUTPUT"
assert_contains "Rust fallback extra-file failure explains issue" '"msg":"cargo fmt touched additional files"' "$CAPTURED_OUTPUT"
assert_contains "Rust fallback extra-file failure reports extra file" 'src/extra.rs' "$CAPTURED_OUTPUT"

cat >"$format_repo/src/extra.rs" <<'EOF'
pub fn extra() -> u32 {
    7
}
EOF
git -C "$format_repo" add src/extra.rs
printf '// pre-existing dirty change\n' >>"$format_repo/src/extra.rs"

capture_command_result env PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" TEST_EXTRA_RUST="$format_repo/src/extra.rs" PRAGMA_OUTPUT_FORMAT=gpt bash -c "cd \"$format_repo\" && \"$PRAGMA_DIR/lib/format.sh\" src/lib.rs"
assert_status "Rust fallback touching pre-dirty files exits non-zero" 1 "$CAPTURED_STATUS"
assert_single_line "Rust fallback pre-dirty failure stays single-line" "$CAPTURED_OUTPUT"
assert_contains "Rust fallback pre-dirty failure reports extra file" 'src/extra.rs' "$CAPTURED_OUTPUT"

test_repo="$tmp_dir/test-repo"
mkdir -p "$test_repo"
git init -q "$test_repo"
cat >"$test_repo/package.json" <<'EOF'
{
  "name": "test-repo",
  "devDependencies": {
    "typescript": "5.0.0"
  },
  "scripts": {
    "test": "npm test"
  }
}
EOF
cat >"$test_repo/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "target": "ES2022"
  }
}
EOF

cat >"$bin_dir/npm" <<'EOF'
#!/usr/bin/env bash
printf 'FAIL suite\nECONNREFUSED\n'
exit 1
EOF
chmod +x "$bin_dir/npm"

capture_command_result env PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" PRAGMA_OUTPUT_FORMAT=gpt bash -c "cd \"$test_repo\" && \"$PRAGMA_DIR/lib/test.sh\""
assert_status "Test failure exits non-zero" 1 "$CAPTURED_STATUS"
assert_single_line "Test failure stays single-line" "$CAPTURED_OUTPUT"
assert_contains "Test failure emits pre-push hook" '"hook":"pre-push"' "$CAPTURED_OUTPUT"
assert_contains "Test failure emits test step" '"step":"test"' "$CAPTURED_OUTPUT"
assert_contains "Test failure includes skip command" '"skip_cmd":"PRAGMA_SKIP_TESTS=1 git push"' "$CAPTURED_OUTPUT"
assert_contains "Test failure includes npm tool" '"tool":"npm"' "$CAPTURED_OUTPUT"

capture_command_result env PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" PRAGMA_OUTPUT_FORMAT=gpt PRAGMA_SKIP_TESTS=1 bash -c "cd \"$test_repo\" && \"$PRAGMA_DIR/lib/test.sh\""
assert_status "Test skip exits zero" 0 "$CAPTURED_STATUS"
assert_empty "Test skip stays silent" "$CAPTURED_OUTPUT"

secrets_repo="$tmp_dir/secrets-repo"
mkdir -p "$secrets_repo"
git init -q "$secrets_repo"

cat >"$bin_dir/gitleaks" <<'EOF'
#!/usr/bin/env bash
printf 'secret found\npath=.env\n'
exit 7
EOF
chmod +x "$bin_dir/gitleaks"

capture_command_result env PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PATH="$bin_dir:$PATH" PRAGMA_OUTPUT_FORMAT=gpt bash -c "cd \"$secrets_repo\" && \"$PRAGMA_DIR/lib/secrets.sh\""
assert_status "Secret scan failure exits non-zero" 1 "$CAPTURED_STATUS"
assert_single_line "Secret scan failure stays single-line" "$CAPTURED_OUTPUT"
assert_contains "Secret scan emits secrets step" '"step":"secrets"' "$CAPTURED_OUTPUT"
assert_contains "Secret scan emits secret class" '"cls":"secret"' "$CAPTURED_OUTPUT"
assert_contains "Secret scan keeps output tail" '"tail":"secret found\npath=.env"' "$CAPTURED_OUTPUT"

printf '\nPassed: %s\n' "$PASS"
printf 'Failed: %s\n' "$FAIL"

exit "$FAIL"
