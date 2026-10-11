#!/usr/bin/env bash
# Check tooling using temporary repositories and local Git remotes.
set -euo pipefail

if [[ $# -ne 0 ]]; then
  printf 'Usage: %s\n' "$0" >&2
  exit 2
fi

PRAGMA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PRAGMA_DIR"
export PATH="$PRAGMA_DIR/bin:$PATH"

scripts=(install.sh lib/*.sh tools/*.sh tests/*.sh)
for script in "${scripts[@]}"; do
  bash -n "$script"
done

shellcheck -e SC2329 -x -P SCRIPTDIR "${scripts[@]}"
shfmt -d -i 2 -ci "${scripts[@]}"
for helper in lib/*.js; do
  node --check "$helper"
done
oxlint --deny-warnings lib/*.js

for test_script in tests/*.sh; do
  printf '\nRunning %s\n' "$test_script"
  bash "$test_script"
done
