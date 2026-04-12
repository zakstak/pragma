#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

PRAGMA_OUTPUT_FORMAT="${PRAGMA_OUTPUT_FORMAT:-gpt}"

main() {
  pragma_set_context "pre-commit" "secrets"

  if ! has_tool gitleaks; then
    log_warn "Missing tool: ${BOLD}gitleaks${RESET} (secret scanner)"
    pragma_add_failure "gitleaks" "tool" 0 "" "./lib/secrets.sh" "missing tool: gitleaks" "" 1
    exit_with_status
  fi

  pragma_run "gitleaks" "secret" 0 "" "./lib/secrets.sh" "secret scan failed" gitleaks protect --staged --redact || record_failure
  exit_with_status
}

main "$@"
