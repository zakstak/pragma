#!/usr/bin/env bash
# common.sh — Shared utilities for pragma scripts
set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  MAGENTA='\033[0;35m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  DIM='\033[2m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' BOLD='' DIM='' RESET=''
fi

# ─── Logging ─────────────────────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}ℹ${RESET} $*"; }
log_success() { echo -e "${GREEN}✔${RESET} $*"; }
log_warn()    { echo -e "${YELLOW}⚠${RESET} $*"; }
log_error()   { echo -e "${RED}✖${RESET} $*"; }
log_header()  { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${RESET}\n"; }
log_skip()    { echo -e "${DIM}  ⏭ $*${RESET}"; }

# ─── Tool checks ─────────────────────────────────────────────────────────────

# Check if a tool is available. Returns 0 if found, 1 if not.
has_tool() {
  command -v "$1" &>/dev/null
}

# Require a tool or print a warning and return 1.
require_tool() {
  local tool="$1"
  local purpose="${2:-}"
  if ! has_tool "$tool"; then
    log_warn "Missing tool: ${BOLD}$tool${RESET}${purpose:+ ($purpose)}"
    return 1
  fi
  return 0
}

# ─── File filtering ──────────────────────────────────────────────────────────

# Filter a list of files by extension(s).
# Usage: filter_by_ext "file1.rs file2.go" rs
# Can also be piped: echo "files..." | filter_by_ext rs ts
filter_by_ext() {
  local files="${1:-}"
  shift
  local exts=("$@")

  # Build grep pattern: \.(rs|go|ts)$
  local pattern
  pattern="\\.($(IFS='|'; echo "${exts[*]}"))$"

  if [[ -n "$files" ]]; then
    echo "$files" | tr ' ' '\n' | grep -E "$pattern" || true
  else
    grep -E "$pattern" || true
  fi
}

# ─── Pragma location ──────────────────────────────────────────────────────

# Resolve the directory where pragma is installed.
pragma_dir() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  echo "$dir"
}

# ─── Exit tracking ───────────────────────────────────────────────────────────
PRAGMA_EXIT_CODE=0

# Record a failure without immediately exiting (for parallel-style checks).
record_failure() {
  PRAGMA_EXIT_CODE=1
}

# Exit with the accumulated code.
exit_with_status() {
  exit "${PRAGMA_EXIT_CODE}"
}
