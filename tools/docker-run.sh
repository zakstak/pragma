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
  --env "GOLANGCI_LINT_CACHE=/tmp/pragma-cache/golangci-lint"
  --env "PRAGMA_RUNNING_IN_DOCKER=1"
)

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
