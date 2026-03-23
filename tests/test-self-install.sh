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

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

repo_copy="$tmp_dir/pragma-self"
cp -a "$PRAGMA_DIR/." "$repo_copy"
cp "$repo_copy/lefthook.yml" "$tmp_dir/original-lefthook.yml"

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

assert_contains "Self-install keeps repo-local config" "Self-install detected; keeping repo-local lefthook.yml" "$output"
assert_contains "Tool detection uses target repo" "Detected languages: markdown shell toml yaml" "$output"
assert_not_contains "Caller cwd does not leak into detection" "Detected languages: go" "$output"

if cmp -s "$tmp_dir/original-lefthook.yml" "$repo_copy/lefthook.yml"; then
  printf 'PASS: lefthook.yml unchanged after self-install\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: lefthook.yml changed after self-install\n'
  FAIL=$((FAIL + 1))
fi

if (cd "$repo_copy" && lefthook run pre-commit --file install.sh --file "space file.sh" --no-tty >/dev/null 2>&1); then
  printf 'PASS: pre-commit hook handles pragma and spaced files\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: pre-commit hook failed on pragma or spaced files\n'
  FAIL=$((FAIL + 1))
fi

target_repo="$tmp_dir/target repo"
mkdir -p "$target_repo"
git init -q "$target_repo"

target_output="$(bash "$repo_copy/install.sh" --agent "$target_repo" 2>&1)"

assert_contains "Generated install completes" "Pragma is configured for $target_repo" "$target_output"
assert_file_contains "Generated config rewrites format path" "\"$repo_copy/lib/format.sh\" {staged_files}" "$target_repo/lefthook.yml"
assert_file_contains "Generated config rewrites lint path" "\"$repo_copy/lib/lint.sh\" {staged_files}" "$target_repo/lefthook.yml"
assert_file_contains "Generated config rewrites test path" "\"$repo_copy/lib/test.sh\"" "$target_repo/lefthook.yml"
assert_file_contains "Generated config keeps docker lint glob" "dockerfile,Dockerfile" "$target_repo/lefthook.yml"
assert_file_not_contains "Generated config avoids repo-local script paths" "./lib/" "$target_repo/lefthook.yml"

worktree_dir="$tmp_dir/pragma worktree"
git -C "$repo_copy" worktree add --detach -q "$worktree_dir" HEAD >/dev/null 2>&1
worktree_output="$(bash "$repo_copy/install.sh" --agent "$worktree_dir" 2>&1)"
assert_contains "Worktree bootstrap succeeds" "Pragma is configured for $worktree_dir" "$worktree_output"

spaced_pragma_dir="$tmp_dir/pragma copy spaced"
cp -a "$PRAGMA_DIR/." "$spaced_pragma_dir"

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
assert_file_contains "Generated config quotes spaced format path" "\"$spaced_pragma_dir/lib/format.sh\" {staged_files}" "$spaced_target_repo/lefthook.yml"

if (cd "$spaced_target_repo" && lefthook run pre-commit --file "generated spaced.sh" --no-tty >/dev/null 2>&1); then
  printf 'PASS: generated hooks run from spaced pragma path\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: generated hooks failed from spaced pragma path\n'
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
