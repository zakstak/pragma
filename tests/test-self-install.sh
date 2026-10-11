#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions match literal shell snippets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
CAPTURED_OUTPUT=''
CAPTURED_STATUS=0

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

  if echo "$actual" | grep -Fq "$expected"; then
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s — expected %s\n' "$label" "$expected"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_contains() {
  local label="$1"
  local expected="$2"
  local file_path="$3"

  if grep -Fq "$expected" "$file_path"; then
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s — expected %s in %s\n' "$label" "$expected" "$file_path"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_not_contains() {
  local label="$1"
  local unexpected="$2"
  local file_path="$3"

  if ! grep -Fq "$unexpected" "$file_path"; then
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s — did not expect %s in %s\n' "$label" "$unexpected" "$file_path"
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

assert_command_fails_with() {
  local label="$1"
  local expected="$2"
  shift 2

  capture_command_result "$@"

  if [[ $CAPTURED_STATUS -eq 0 ]]; then
    printf 'FAIL: %s — command unexpectedly succeeded\n' "$label"
    FAIL=$((FAIL + 1))
    return
  fi

  if echo "$CAPTURED_OUTPUT" | grep -Fq "$expected"; then
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s — expected %s with non-zero exit\n' "$label" "$expected"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1"
  local unexpected="$2"
  local actual="$3"

  if ! echo "$actual" | grep -Fq "$unexpected"; then
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s — did not expect %s\n' "$label" "$unexpected"
    FAIL=$((FAIL + 1))
  fi
}

write_uname_stub() {
  local stub_dir="$1"
  local stub_value="$2"

  mkdir -p "$stub_dir"
  cat >"$stub_dir/uname" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$stub_value'
EOF
  chmod +x "$stub_dir/uname"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
export PRAGMA_GLOBAL_BIN_DIR="$tmp_dir/global-bin"
mkdir -p "$PRAGMA_GLOBAL_BIN_DIR"
for core_tool in prek kingfisher; do
  cp "$(command -v "$core_tool")" "$PRAGMA_GLOBAL_BIN_DIR/$core_tool"
done

repo_copy="$tmp_dir/pragma-self"
copy_tree "$PRAGMA_DIR" "$repo_copy"
rm -rf "${repo_copy:?}/bin"
cp "$repo_copy/prek.toml" "$tmp_dir/original-prek.toml"

space_file="$repo_copy/space file.sh"
cat >"$space_file" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$tmp_dir/go.mod" <<'EOF'
module caller-noise

go 1.22.0
EOF

output="$(cd "$tmp_dir" && bash "$repo_copy/install.sh" --agent "$repo_copy" 2>&1)"

assert_contains "Self-install keeps repo-local config" "Self-install detected; keeping repo-local prek.toml" "$output"
assert_contains "Tool detection uses target repo" "Detected languages: json markdown shell toml typescript yaml" "$output"
assert_not_contains "Caller cwd does not leak into detection" "Detected languages: go" "$output"

if cmp -s "$tmp_dir/original-prek.toml" "$repo_copy/prek.toml"; then
  printf 'PASS: prek.toml unchanged after self-install\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: prek.toml changed after self-install\n'
  FAIL=$((FAIL + 1))
fi

missing_prek_repo="$tmp_dir/pragma-self-missing-prek"
copy_tree "$PRAGMA_DIR" "$missing_prek_repo"
rm -rf "${missing_prek_repo:?}/bin"
rm -f "$missing_prek_repo/prek.toml"

assert_command_fails_with "Self-install without repo-local prek.toml fails" "Self-install requires repo-local prek.toml" bash "$missing_prek_repo/install.sh" --agent "$missing_prek_repo"

git -C "$repo_copy" add -- install.sh "space file.sh"
if hook_output="$(cd "$repo_copy" && PATH="$repo_copy/bin:$PATH" prek run --files install.sh "space file.sh" 2>&1)"; then
  printf 'PASS: pre-commit hook handles pragma and spaced files\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: pre-commit hook failed on pragma or spaced files\n%s\n' "$hook_output"
  FAIL=$((FAIL + 1))
fi

target_repo="$tmp_dir/target repo"
mkdir -p "$target_repo"
git init -q "$target_repo"

target_output="$(bash "$repo_copy/install.sh" --agent "$target_repo" 2>&1)"

assert_contains "Generated install completes" "Pragma is configured for $target_repo" "$target_output"
assert_file_contains "Generated config points format hook at repo-local wrapper" "entry = \".pragma-hooks/format.sh\"" "$target_repo/prek.toml"
assert_file_contains "Generated config points lint hook at repo-local wrapper" "entry = \".pragma-hooks/lint.sh\"" "$target_repo/prek.toml"
assert_file_contains "Generated config points secrets hook at repo-local wrapper" "entry = \".pragma-hooks/secrets.sh\"" "$target_repo/prek.toml"
assert_file_contains "Generated config points test hook at repo-local wrapper" "entry = \".pragma-hooks/test.sh\"" "$target_repo/prek.toml"
assert_file_contains "Generated config keeps docker lint regex" "[Dd]ockerfile" "$target_repo/prek.toml"
assert_file_not_contains "Generated config avoids repo-local lib paths" "entry = \"./lib/" "$target_repo/prek.toml"
assert_file_contains "Generated format wrapper resolves runtime location" 'exec "$PRAGMA_HOME/lib/format.sh" "$@"' "$target_repo/.pragma-hooks/format.sh"
assert_file_contains "Generated lint wrapper resolves runtime location" 'exec "$PRAGMA_HOME/lib/lint.sh" "$@"' "$target_repo/.pragma-hooks/lint.sh"

worktree_dir="$tmp_dir/pragma worktree"
git -C "$repo_copy" worktree add --detach -q "$worktree_dir" HEAD >/dev/null 2>&1
worktree_output="$(bash "$repo_copy/install.sh" --agent "$worktree_dir" 2>&1)"
assert_contains "Worktree bootstrap succeeds" "Pragma is configured for $worktree_dir" "$worktree_output"

spaced_pragma_dir="$tmp_dir/pragma copy spaced"
copy_tree "$PRAGMA_DIR" "$spaced_pragma_dir"
rm -rf "${spaced_pragma_dir:?}/bin"

spaced_target_repo="$tmp_dir/generated target"
mkdir -p "$spaced_target_repo"
git init -q "$spaced_target_repo"

spaced_target_file="$spaced_target_repo/generated spaced.sh"
cat >"$spaced_target_file" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

spaced_output="$(bash "$spaced_pragma_dir/install.sh" --agent "$spaced_target_repo" 2>&1)"
assert_contains "Spaced pragma install completes" "Pragma is configured for $spaced_target_repo" "$spaced_output"
assert_file_contains "Generated config keeps spaced pragma path out of prek entry" "entry = \".pragma-hooks/format.sh\"" "$spaced_target_repo/prek.toml"
assert_file_not_contains "Generated wrapper excludes machine paths" "$spaced_pragma_dir" "$spaced_target_repo/.pragma-hooks/format.sh"

if (cd "$spaced_target_repo" && PATH="$spaced_pragma_dir/bin:$PATH" prek run --files "generated spaced.sh" >/dev/null 2>&1); then
  printf 'PASS: generated hooks run from spaced pragma path\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: generated hooks failed from spaced pragma path\n'
  FAIL=$((FAIL + 1))
fi

home_root="$tmp_dir/fake-home"
mkdir -p "$home_root"
home_pragma_dir="$home_root/.pragma"
copy_tree "$PRAGMA_DIR" "$home_pragma_dir"
rm -rf "${home_pragma_dir:?}/bin"

home_target_repo="$tmp_dir/home target"
mkdir -p "$home_target_repo"
git init -q "$home_target_repo"

home_output="$(HOME="$home_root" bash "$home_pragma_dir/install.sh" --agent "$home_target_repo" 2>&1)"
assert_contains "Home pragma install completes" "Pragma is configured for $home_target_repo" "$home_output"
assert_file_contains "Canonical home wrapper falls back to HOME" 'PRAGMA_HOME="${PRAGMA_HOME:-$HOME/.pragma}"' "$home_target_repo/.pragma-hooks/format.sh"
assert_file_contains "Canonical home regenerate comment uses tilde path" "# To regenerate: ~/.pragma/install.sh <target-repo>" "$home_target_repo/prek.toml"

unsupported_repo="$tmp_dir/pragma-unsupported"
copy_tree "$PRAGMA_DIR" "$unsupported_repo"
rm -rf "${unsupported_repo:?}/bin"

unsupported_uname_dir="$tmp_dir/unsupported-uname"
write_uname_stub "$unsupported_uname_dir" Windows_NT

capture_command_result env PATH="$unsupported_uname_dir:$PATH" bash "$unsupported_repo/install.sh" --agent "$unsupported_repo"
unsupported_output="$CAPTURED_OUTPUT"

if [[ $CAPTURED_STATUS -eq 0 ]]; then
  printf 'FAIL: unsupported host unexpectedly succeeded\n'
  FAIL=$((FAIL + 1))
else
  assert_contains "Unsupported host fails with explicit bootstrap message" "Unsupported host: Pragma bootstrap/install-tools are supported on macOS and Linux only." "$unsupported_output"
fi
assert_not_contains "Unsupported host stops before bootstrap header" "Pragma Setup" "$unsupported_output"

if [[ ! -d "$unsupported_repo/bin" ]]; then
  printf 'PASS: unsupported host does not create install artifacts\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: unsupported host unexpectedly created install artifacts\n'
  FAIL=$((FAIL + 1))
fi

if cmp -s "$tmp_dir/original-prek.toml" "$unsupported_repo/prek.toml"; then
  printf 'PASS: unsupported host leaves prek.toml unchanged\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: unsupported host changed prek.toml\n'
  FAIL=$((FAIL + 1))
fi

missing_target="$tmp_dir/missing repo"
assert_command_fails_with "Missing target gets friendly error" "$missing_target does not exist" bash "$repo_copy/install.sh" --agent "$missing_target"

not_dir_target="$tmp_dir/not-a-dir"
touch "$not_dir_target"
assert_command_fails_with "Non-directory target gets friendly error" "$not_dir_target is not a directory" bash "$repo_copy/install.sh" --agent "$not_dir_target"

printf '\nPassed: %s\n' "$PASS"
printf 'Failed: %s\n' "$FAIL"

exit "$FAIL"
