#!/usr/bin/env bash
# common.sh — Shared utilities for pragma scripts
set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  DIM='\033[2m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' RESET=''
fi

# ─── Logging ─────────────────────────────────────────────────────────────────
log_info() { echo -e "${BLUE}ℹ${RESET} $*"; }
log_success() { echo -e "${GREEN}✔${RESET} $*"; }
log_warn() { echo -e "${YELLOW}⚠${RESET} $*"; }
log_error() { echo -e "${RED}✖${RESET} $*"; }
log_header() { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${RESET}\n"; }
log_skip() { echo -e "${DIM}  ⏭ $*${RESET}"; }

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

golangci_version_text() {
  if ! has_tool golangci-lint; then
    return 1
  fi

  local output=""

  output="$(golangci-lint version --format short 2>/dev/null || true)"
  [[ -n "$output" ]] || output="$(golangci-lint version --short 2>/dev/null || true)"
  [[ -n "$output" ]] || output="$(golangci-lint version 2>/dev/null || true)"
  [[ -n "$output" ]] || output="$(golangci-lint --version 2>/dev/null || true)"
  [[ -n "$output" ]] || return 1

  printf '%s\n' "$output"
}

golangci_major_version() {
  local output
  output="$(golangci_version_text)" || return 1

  if [[ "$output" =~ (^|[^[:alnum:]])v?([0-9]+)(\.[0-9]+){0,2}([^[:alnum:]]|$) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi

  return 1
}

golangci_is_v2() {
  local major
  major="$(golangci_major_version)" || return 1
  [[ "$major" -ge 2 ]]
}

# ─── File filtering ──────────────────────────────────────────────────────────

has_ext() {
  local file="$1"
  shift

  local ext
  for ext in "$@"; do
    case "$file" in
      *".${ext}") return 0 ;;
    esac
  done

  return 1
}

is_dockerfile_path() {
  local basename="${1##*/}"

  case "${basename,,}" in
    dockerfile | dockerfile.* | *.dockerfile) return 0 ;;
  esac

  return 1
}

filter_by_ext() {
  local output_var="$1"
  shift
  local -n output_ref="$output_var"
  local exts=()

  while [[ $# -gt 0 ]] && [[ "$1" != "--" ]]; do
    exts+=("$1")
    shift
  done

  if [[ "${1:-}" == "--" ]]; then
    shift
  fi

  output_ref=()

  local file
  for file in "$@"; do
    if has_ext "$file" "${exts[@]}"; then
      output_ref+=("$file")
    fi
  done
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
