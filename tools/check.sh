#!/usr/bin/env bash
# Check tooling using temporary repositories and local Git remotes.
set -euo pipefail

check_docker=false
case "${1:-}" in
  "") ;;
  --docker) check_docker=true ;;
  *)
    printf 'Usage: %s [--docker]\n' "$0" >&2
    exit 2
    ;;
esac

PRAGMA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PRAGMA_DIR"
export PATH="$PRAGMA_DIR/bin:$PATH"

scripts=(install.sh lib/*.sh tools/*.sh tests/*.sh)
for script in "${scripts[@]}"; do
  bash -n "$script"
done

shellcheck -e SC2329 -x -P SCRIPTDIR "${scripts[@]}"
shfmt -d -i 2 -ci "${scripts[@]}"
hadolint Dockerfile

for test_script in tests/*.sh; do
  printf '\nRunning %s\n' "$test_script"
  bash "$test_script"
done

if $check_docker; then
  docker build -t "${PRAGMA_DOCKER_IMAGE:-pragma-tools:local}" .
  bash tests/test-git-hooks.sh --docker-tools
fi
