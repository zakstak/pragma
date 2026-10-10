#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(dirname "$SCRIPT_DIR")"
source "$PRAGMA_DIR/lib/common.sh"

usage() {
  printf 'Usage: %s <tool> [args...]\n' "$0" >&2
}

assert_supported_volume_path() {
  local path="$1"

  if [[ "$path" == *:* || "$path" == *$'\n'* ]]; then
    log_error "Unsupported Docker bind path: $path"
    log_error "Paths used with Docker mode cannot contain ':' or newlines"
    exit 1
  fi
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

if ! has_tool docker; then
  log_error "docker is required for Pragma Docker tooling"
  exit 1
fi

TOOL_NAME="$1"
shift

IMAGE_NAME="${PRAGMA_DOCKER_IMAGE:-pragma-tools:local}"
CURRENT_DIR="$(pwd)"
REPO_ROOT="$CURRENT_DIR"
WORKDIR="/workspace"

if git -C "$CURRENT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
  REPO_ROOT="$(git -C "$CURRENT_DIR" rev-parse --show-toplevel)"

  if [[ "$CURRENT_DIR" != "$REPO_ROOT" ]]; then
    RELATIVE_DIR="${CURRENT_DIR#"$REPO_ROOT"/}"
    WORKDIR="/workspace/$RELATIVE_DIR"
  fi
fi

# Linked worktrees keep their Git metadata outside the mounted worktree.
GIT_COMMON_DIR=""
GIT_WORKTREE_DIR=""
if [[ -f "$REPO_ROOT/.git" ]]; then
  GIT_COMMON_DIR="$(git -C "$REPO_ROOT" rev-parse --git-common-dir)"
  GIT_COMMON_DIR="$(cd "$REPO_ROOT" && cd "$GIT_COMMON_DIR" && pwd)"
  GIT_WORKTREE_DIR="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir)"
  assert_supported_volume_path "$GIT_COMMON_DIR"
fi

assert_supported_volume_path "$REPO_ROOT"
assert_supported_volume_path "$PRAGMA_DIR"

DOCKER_ARGS=(
  run
  --rm
  --user "$(id -u):$(id -g)"
  --workdir "$WORKDIR"
  --volume "$REPO_ROOT:/workspace"
  --env "HOME=/tmp/pragma-home"
  --env "XDG_CACHE_HOME=/tmp/pragma-cache"
  --env "XDG_CONFIG_HOME=/tmp/pragma-config"
  --env "NPM_CONFIG_CACHE=/tmp/pragma-cache/npm"
  --env "PIP_CACHE_DIR=/tmp/pragma-cache/pip"
  --env "GOCACHE=/tmp/pragma-cache/go-build"
  --env "GOMODCACHE=/tmp/pragma-cache/go-mod"
  --env "GOLANGCI_LINT_CACHE=/tmp/pragma-cache/golangci-lint"
  --env "CARGO_HOME=/tmp/pragma-cache/cargo"
  --env "PRAGMA_RUNNING_IN_DOCKER=1"
)

if [[ "$TOOL_NAME" == kingfisher ]]; then
  KINGFISHER_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/pragma/kingfisher-docker"
  assert_supported_volume_path "$KINGFISHER_CACHE_DIR"
  (umask 077 && mkdir -p "$KINGFISHER_CACHE_DIR")
  DOCKER_ARGS+=(
    --volume "$KINGFISHER_CACHE_DIR:/tmp/pragma-kingfisher-cache"
    --env "KF_RULE_CACHE_DIR=/tmp/pragma-kingfisher-cache"
  )
fi

if [[ -n "$GIT_COMMON_DIR" ]]; then
  DOCKER_ARGS+=(
    --volume "$GIT_COMMON_DIR:$GIT_COMMON_DIR"
    --env "GIT_DIR=$GIT_WORKTREE_DIR"
    --env "GIT_WORK_TREE=/workspace"
  )
fi

if [[ "$PRAGMA_DIR" != "$REPO_ROOT" ]]; then
  DOCKER_ARGS+=(--volume "$PRAGMA_DIR:$PRAGMA_DIR:ro")
fi

if [[ -n "${CI:-}" ]]; then
  DOCKER_ARGS+=(--env "CI=$CI")
fi

if [[ -n "${NO_COLOR:-}" ]]; then
  DOCKER_ARGS+=(--env "NO_COLOR=$NO_COLOR")
fi

if [[ -n "${TERM:-}" ]]; then
  DOCKER_ARGS+=(--env "TERM=$TERM")
fi

if [[ -n "${PRAGMA_OUTPUT_FORMAT:-}" ]]; then
  DOCKER_ARGS+=(--env "PRAGMA_OUTPUT_FORMAT=$PRAGMA_OUTPUT_FORMAT")
fi

if [[ -n "${PRAGMA_SKIP_TESTS:-}" ]]; then
  DOCKER_ARGS+=(--env "PRAGMA_SKIP_TESTS=$PRAGMA_SKIP_TESTS")
fi

if [[ -t 0 ]]; then
  DOCKER_ARGS+=(-i)
fi

if [[ -t 1 ]]; then
  DOCKER_ARGS+=(-t)
fi

exec docker "${DOCKER_ARGS[@]}" "$IMAGE_NAME" "$TOOL_NAME" "$@"
