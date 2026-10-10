#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"

PRAGMA_OUTPUT_FORMAT="${PRAGMA_OUTPUT_FORMAT:-gpt}"

main() {
  pragma_set_context "pre-commit" "secrets"

  if ! has_tool kingfisher; then
    log_warn "Missing tool: ${BOLD}kingfisher${RESET} (secret scanner)"
    pragma_add_failure "kingfisher" "tool" 0 "" "./lib/secrets.sh" "missing tool: kingfisher" "" 1
    exit_with_status
  fi

  local config_path="$PRAGMA_DIR/kingfisher.yaml"
  [[ ! -f kingfisher.yaml ]] || config_path=kingfisher.yaml

  pragma_run "kingfisher" "secret" 0 "" "./lib/secrets.sh" "secret scan failed" \
    kingfisher scan . --staged --no-validate --redact --quiet --no-update-check \
    --jobs 2 --config "$config_path" || record_failure
  exit_with_status
}

main "$@"
