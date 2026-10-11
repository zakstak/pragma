#!/usr/bin/env bash
# Capture compiler comparisons separately from the project's blocking checks.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/test.sh" --shadow-only "$@"
