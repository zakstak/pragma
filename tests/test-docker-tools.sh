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

assert_file_exists() {
  local label="$1"
  local path="$2"

  if [[ -e "$path" ]]; then
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s — missing %s\n' "$label" "$path"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_not_exists() {
  local label="$1"
  local path="$2"

  if [[ ! -e "$path" ]]; then
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s — did not expect %s\n' "$label" "$path"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_not_contains() {
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

copy_tree() {
  local source_dir="$1"
  local target_dir="$2"

  mkdir -p "$target_dir"
  cp -R "$source_dir/." "$target_dir"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

pragma_copy="$tmp_dir/pragma copy"
target_repo="$tmp_dir/target repo"
target_subdir="$target_repo/sub dir"
docker_capture="$tmp_dir/docker-calls.log"
stub_bin="$tmp_dir/stub-bin"

copy_tree "$PRAGMA_DIR" "$pragma_copy"
rm -rf "${pragma_copy:?}/bin"
mkdir -p "$stub_bin" "$target_subdir"
git init -q "$target_repo"

cat >"$stub_bin/docker" <<'EOF'
#!/bin/sh
capture_file=${PRAGMA_DOCKER_CAPTURE_FILE:?}
{
  printf 'CALL\n'
  printf '%s\n' "$@"
  printf 'END\n'
} >>"$capture_file"
exit 0
EOF
chmod +x "$stub_bin/docker"

install_output="$(PATH="$stub_bin:$PATH" PRAGMA_DOCKER_IMAGE="pragma-tools:test" PRAGMA_DOCKER_CAPTURE_FILE="$docker_capture" bash "$pragma_copy/install.sh" --agent --docker-tools "$target_repo" 2>&1)"

assert_contains "Docker bootstrap completes" "Pragma is configured for $target_repo" "$install_output"
assert_contains "Docker bootstrap installs wrappers" "Docker-backed tools installed to $pragma_copy/bin/docker" "$install_output"
assert_file_not_exists "prek stays on the host" "$pragma_copy/bin/docker/prek"
assert_file_exists "Kingfisher wrapper created" "$pragma_copy/bin/docker/kingfisher"
assert_file_exists "prettier wrapper created" "$pragma_copy/bin/docker/prettier"
assert_file_not_exists "templ wrapper removed" "$pragma_copy/bin/docker/templ"
assert_file_exists "Go wrapper created" "$pragma_copy/bin/docker/go"
assert_file_exists "goimports wrapper created" "$pragma_copy/bin/docker/goimports"
assert_file_exists "v2 linter wrapper created" "$pragma_copy/bin/docker/golangci-lint"
assert_file_exists "cargo wrapper created" "$pragma_copy/bin/docker/cargo"
assert_file_not_exists "Docker wrappers do not replace native bin entries" "$pragma_copy/bin/prek"

for retired_tool in prek templ gitleaks; do
  printf '#!/bin/sh\nexit 0\n' >"$pragma_copy/bin/docker/$retired_tool"
done
PATH="$stub_bin:$PATH" bash "$pragma_copy/tools/install-tools.sh" --docker --agent >/dev/null
for retired_tool in prek templ gitleaks; do
  assert_file_not_exists "Docker upgrade removes retired $retired_tool wrapper" "$pragma_copy/bin/docker/$retired_tool"
done

assert_contains "Generated config uses repo-local wrapper path" "entry = \".pragma-hooks/format.sh\"" "$(cat "$target_repo/prek.toml")"
assert_contains "Generated wrapper scopes docker wrappers per repo" "export PRAGMA_TOOL_MODE=docker" "$(cat "$target_repo/.pragma-hooks/format.sh")"

mkdir -p "$pragma_copy/bin"
cat >"$pragma_copy/bin/hadolint" <<'EOF'
#!/bin/sh
printf '%s\n' native-hadolint
EOF
chmod +x "$pragma_copy/bin/hadolint"

resolution_output="$(PATH="/usr/bin:/bin" PRAGMA_TOOL_MODE=docker bash -lc 'source "$1/lib/common.sh"; command -v hadolint' _ "$pragma_copy")"
assert_contains "Docker mode prefers docker wrapper over native bin" "$pragma_copy/bin/docker/hadolint" "$resolution_output"

assert_file_exists "prek installs a real host hook" "$target_repo/.git/hooks/pre-commit"
assert_file_not_contains "Host hook excludes container executable paths" "/opt/pragma" "$target_repo/.git/hooks/pre-commit"

: >"$docker_capture"

wrapper_output="$(cd "$target_subdir" && PATH="$stub_bin:$PATH" PRAGMA_DOCKER_IMAGE="pragma-tools:test" PRAGMA_DOCKER_CAPTURE_FILE="$docker_capture" PRAGMA_SKIP_TESTS=1 "$pragma_copy/bin/docker/hadolint" "Dockerfile" 2>&1)"

if [[ -z "$wrapper_output" ]]; then
  printf 'PASS: %s\n' "Direct wrapper stays quiet"
  PASS=$((PASS + 1))
else
  printf 'FAIL: %s — expected no output\n' "Direct wrapper stays quiet"
  FAIL=$((FAIL + 1))
fi

wrapper_capture="$(cat "$docker_capture")"
assert_contains "Direct wrapper keeps repo bind mount" "$target_repo:/workspace" "$wrapper_capture"
assert_contains "Direct wrapper keeps pragma source mount" "$pragma_copy:$pragma_copy:ro" "$wrapper_capture"
assert_contains "Direct wrapper maps subdirectory workdir" "/workspace/sub dir" "$wrapper_capture"
assert_contains "Docker wrapper uses requested image" "pragma-tools:test" "$wrapper_capture"
assert_contains "Docker wrapper preserves host uid:gid" "$(id -u):$(id -g)" "$wrapper_capture"
assert_contains "Docker wrapper sets container HOME" "HOME=/tmp/pragma-home" "$wrapper_capture"
assert_contains "Docker wrapper sets cache dir" "XDG_CACHE_HOME=/tmp/pragma-cache" "$wrapper_capture"
assert_contains "Docker wrapper marks container execution" "PRAGMA_RUNNING_IN_DOCKER=1" "$wrapper_capture"
assert_contains "Direct wrapper forwards tool name" "hadolint" "$wrapper_capture"
assert_contains "Direct wrapper forwards arguments" "Dockerfile" "$wrapper_capture"
assert_contains "Direct wrapper forwards skip-tests env" "PRAGMA_SKIP_TESTS=1" "$wrapper_capture"

kingfisher_cache_root="$tmp_dir/cache root"
(cd "$target_repo" && PATH="$stub_bin:$PATH" XDG_CACHE_HOME="$kingfisher_cache_root" PRAGMA_DOCKER_CAPTURE_FILE="$docker_capture" "$pragma_copy/bin/docker/kingfisher" scan . --staged)
cache_capture="$(cat "$docker_capture")"
assert_contains "Kingfisher Docker scans mount a persistent cache" "$kingfisher_cache_root/pragma/kingfisher-docker:/tmp/pragma-kingfisher-cache" "$cache_capture"
assert_contains "Kingfisher Docker scans select the mounted rule cache" "KF_RULE_CACHE_DIR=/tmp/pragma-kingfisher-cache" "$cache_capture"
printf 'persisted fixture\n' >"$kingfisher_cache_root/pragma/kingfisher-docker/fixture"
(cd "$target_repo" && PATH="$stub_bin:$PATH" XDG_CACHE_HOME="$kingfisher_cache_root" PRAGMA_DOCKER_CAPTURE_FILE="$docker_capture" "$pragma_copy/bin/docker/kingfisher" scan . --staged)
assert_file_exists "Repeated Docker runs retain cache files" "$kingfisher_cache_root/pragma/kingfisher-docker/fixture"
if find "$kingfisher_cache_root/pragma/kingfisher-docker" -prune -perm 0700 -print | grep -q .; then
  printf 'PASS: Kingfisher cache is private to its owner\n'
  PASS=$((PASS + 1))
else
  printf 'FAIL: Kingfisher cache permissions are not private\n'
  FAIL=$((FAIL + 1))
fi

native_probe_output="$(cd "$target_repo" && PATH="$stub_bin:/usr/bin:/bin" bash "$pragma_copy/tools/install-tools.sh" --agent 2>&1 || true)"
assert_contains "Native mode still sees prek as missing after docker install" "prek is missing" "$native_probe_output"

cat >"$pragma_copy/bin/prek" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$pragma_copy/bin/prek"

native_restore_output="$(PATH="$stub_bin:/usr/bin:/bin" bash "$pragma_copy/install.sh" --agent "$target_repo" 2>&1)"
assert_contains "Native restore on normal repo completes" "Pragma is configured for $target_repo" "$native_restore_output"
assert_file_not_contains "Native restore on normal repo removes docker wrapper prefix" "PRAGMA_DOCKER_BIN_DIR" "$target_repo/prek.toml"

# Docker must also see metadata for linked Git worktrees.
git -C "$target_repo" -c user.name=Test -c user.email=test@example.com commit --allow-empty --no-verify -qm fixture
worktree_dir="$tmp_dir/linked worktree"
git -C "$target_repo" worktree add --detach -q "$worktree_dir" HEAD
: >"$docker_capture"
(cd "$worktree_dir" && PATH="$stub_bin:$PATH" PRAGMA_DOCKER_CAPTURE_FILE="$docker_capture" "$pragma_copy/bin/docker/hadolint" Dockerfile)
worktree_capture="$(cat "$docker_capture")"
common_dir="$(git -C "$target_repo" rev-parse --absolute-git-dir)"
linked_git_dir="$(git -C "$worktree_dir" rev-parse --absolute-git-dir)"
assert_contains "Worktree wrapper mounts shared Git metadata" "$common_dir:$common_dir" "$worktree_capture"
assert_contains "Worktree wrapper selects worktree Git metadata" "GIT_DIR=$linked_git_dir" "$worktree_capture"
assert_contains "Worktree wrapper maps Git worktree to container path" "GIT_WORK_TREE=/workspace" "$worktree_capture"

printf '\nPassed: %s\n' "$PASS"
printf 'Failed: %s\n' "$FAIL"

exit "$FAIL"
