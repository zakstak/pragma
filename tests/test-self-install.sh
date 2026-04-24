#!/usr/bin/env bash
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

repo_copy="$tmp_dir/pragma-self"
copy_tree "$PRAGMA_DIR" "$repo_copy"
rm -rf "${repo_copy:?}/bin"
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
escaped_repo_copy="$(printf '%q' "$repo_copy")"

assert_contains "Self-install keeps repo-local config" "Self-install detected; keeping repo-local lefthook.yml" "$output"
assert_contains "Tool detection uses target repo" "Detected languages: docker json markdown shell toml yaml" "$output"
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

stub_docker_bin="$tmp_dir/stub-docker-bin"
mkdir -p "$stub_docker_bin"
cat >"$stub_docker_bin/docker" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$stub_docker_bin/docker"

docker_self_repo="$tmp_dir/pragma-self-docker"
copy_tree "$PRAGMA_DIR" "$docker_self_repo"
rm -rf "${docker_self_repo:?}/bin"
cp "$docker_self_repo/lefthook.yml" "$tmp_dir/original-docker-lefthook.yml"

docker_self_output="$(cd "$tmp_dir" && PATH="$stub_docker_bin:$PATH" PRAGMA_DOCKER_IMAGE="pragma-tools:test" bash "$docker_self_repo/install.sh" --agent --docker-tools "$docker_self_repo" 2>&1)"
escaped_docker_self_repo="$(printf '%q' "$docker_self_repo")"
escaped_docker_bin_dir="$(printf '%q' "$docker_self_repo/bin/docker")"

assert_contains "Docker self-install updates repo-local config" "Self-install detected; updating repo-local lefthook.yml for Docker-backed tools" "$docker_self_output"
assert_file_contains "Docker self-install scopes wrapper dir in repo-local config" "PRAGMA_DOCKER_BIN_DIR=$escaped_docker_bin_dir ./lib/format.sh {staged_files}" "$docker_self_repo/lefthook.yml"
assert_file_contains "Docker self-install keeps relative format path" "./lib/format.sh {staged_files}" "$docker_self_repo/lefthook.yml"
assert_file_not_contains "Docker self-install avoids absolute format path" "$escaped_docker_self_repo/lib/format.sh" "$docker_self_repo/lefthook.yml"

if cmp -s "$tmp_dir/original-docker-lefthook.yml" "$docker_self_repo/lefthook.yml"; then
  printf 'FAIL: Docker self-install should update repo-local lefthook.yml\n'
  FAIL=$((FAIL + 1))
else
  printf 'PASS: Docker self-install updates repo-local lefthook.yml\n'
  PASS=$((PASS + 1))
fi

docker_revert_output="$(cd "$tmp_dir" && bash "$docker_self_repo/install.sh" --agent "$docker_self_repo" 2>&1)"
assert_contains "Native self-install restores tracked repo-local config" "Self-install detected; restoring repo-local lefthook.yml from tracked template" "$docker_revert_output"
assert_file_not_contains "Native self-install removes docker wrapper prefix" "PRAGMA_DOCKER_BIN_DIR=" "$docker_self_repo/lefthook.yml"

if cmp -s "$tmp_dir/original-docker-lefthook.yml" "$docker_self_repo/lefthook.yml"; then
  printf 'PASS: Native self-install restores original repo-local lefthook.yml\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: Native self-install did not restore original repo-local lefthook.yml\n'
  FAIL=$((FAIL + 1))
fi

target_repo="$tmp_dir/target repo"
mkdir -p "$target_repo"
git init -q "$target_repo"

target_output="$(bash "$repo_copy/install.sh" --agent "$target_repo" 2>&1)"

assert_contains "Generated install completes" "Pragma is configured for $target_repo" "$target_output"
assert_file_contains "Generated config rewrites format path" "$escaped_repo_copy/lib/format.sh {staged_files}" "$target_repo/lefthook.yml"
assert_file_contains "Generated config rewrites lint path" "$escaped_repo_copy/lib/lint.sh {staged_files}" "$target_repo/lefthook.yml"
assert_file_contains "Generated config rewrites secrets path" "$escaped_repo_copy/lib/secrets.sh" "$target_repo/lefthook.yml"
assert_file_contains "Generated config rewrites test path" "$escaped_repo_copy/lib/test.sh" "$target_repo/lefthook.yml"
assert_file_contains "Generated config keeps docker lint glob" "dockerfile,Dockerfile" "$target_repo/lefthook.yml"
assert_file_not_contains "Generated config avoids repo-local script paths" "./lib/" "$target_repo/lefthook.yml"

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
escaped_spaced_pragma_dir="$(printf '%q' "$spaced_pragma_dir")"
assert_contains "Spaced pragma install completes" "Pragma is configured for $spaced_target_repo" "$spaced_output"
assert_file_contains "Generated config quotes spaced format path" "$escaped_spaced_pragma_dir/lib/format.sh {staged_files}" "$spaced_target_repo/lefthook.yml"

if (cd "$spaced_target_repo" && lefthook run pre-commit --file "generated spaced.sh" --no-tty >/dev/null 2>&1); then
  printf 'PASS: generated hooks run from spaced pragma path\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: generated hooks failed from spaced pragma path\n'
  FAIL=$((FAIL + 1))
fi

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

if cmp -s "$tmp_dir/original-lefthook.yml" "$unsupported_repo/lefthook.yml"; then
  printf 'PASS: unsupported host leaves lefthook.yml unchanged\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: unsupported host changed lefthook.yml\n'
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
