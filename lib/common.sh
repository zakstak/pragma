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
pragma_human_output_enabled() {
  [[ "${PRAGMA_OUTPUT_FORMAT:-human}" != "gpt" ]]
}

log_info() {
  pragma_human_output_enabled || return 0
  echo -e "${BLUE}ℹ${RESET} $*"
}

log_success() {
  pragma_human_output_enabled || return 0
  echo -e "${GREEN}✔${RESET} $*"
}

log_warn() {
  pragma_human_output_enabled || return 0
  echo -e "${YELLOW}⚠${RESET} $*"
}

log_error() {
  pragma_human_output_enabled || return 0
  echo -e "${RED}✖${RESET} $*"
}

log_header() {
  pragma_human_output_enabled || return 0
  echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${RESET}\n"
}

log_skip() {
  pragma_human_output_enabled || return 0
  echo -e "${DIM}  ⏭ $*${RESET}"
}

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

PRAGMA_HOOK="${PRAGMA_HOOK:-unknown}"
PRAGMA_STEP="${PRAGMA_STEP:-unknown}"
PRAGMA_EXIT_CODE=0
PRAGMA_FAILURES=()

pragma_set_context() {
  PRAGMA_HOOK="$1"
  PRAGMA_STEP="$2"
}

pragma_sanitize_machine_text() {
  local input="${1-}"
  printf '%s' "$input" | LC_ALL=C sed -E $'s/\x1B\[[0-9;?]*[ -/]*[@-~]//g; s/\x1B[@-_]//g' | LC_ALL=C tr -d '\000-\010\013\014\016-\037'
}

pragma_json_escape() {
  local value
  value="$(pragma_sanitize_machine_text "${1-}")"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

pragma_compact_tail() {
  local input
  input="$(pragma_sanitize_machine_text "${1-}")"
  input=${input//$'\r'/}

  local -a lines=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && lines+=("$line")
  done <<<"$input"

  local start=0
  local total=${#lines[@]}
  if ((total > 5)); then
    start=$((total - 5))
  fi

  local output=""
  local i
  for ((i = start; i < total; i++)); do
    if [[ -n "$output" ]]; then
      output+=$'\n'
    fi
    output+="${lines[i]}"
  done

  if ((${#output} > 320)); then
    output="${output: -320}"
  fi

  printf '%s' "$output"
}

pragma_add_failure() {
  local tool="$1"
  local cls="$2"
  local skip="$3"
  local skip_cmd="$4"
  local rerun="$5"
  local msg="$6"
  local output="${7-}"
  local code="${8:-1}"
  local tail

  tail="$(pragma_compact_tail "$output")"
  PRAGMA_FAILURES+=("{\"tool\":\"$(pragma_json_escape "$tool")\",\"cls\":\"$(pragma_json_escape "$cls")\",\"skip\":$skip,\"skip_cmd\":\"$(pragma_json_escape "$skip_cmd")\",\"rerun\":\"$(pragma_json_escape "$rerun")\",\"msg\":\"$(pragma_json_escape "$msg")\",\"tail\":\"$(pragma_json_escape "$tail")\",\"code\":$code}")
  PRAGMA_EXIT_CODE=1
}

pragma_run() {
  local tool="$1"
  local cls="$2"
  local skip="$3"
  local skip_cmd="$4"
  local rerun="$5"
  local msg="$6"
  shift 6

  local output
  local status

  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  if [[ $status -ne 0 ]]; then
    if pragma_human_output_enabled && [[ -n "$output" ]]; then
      printf '%s\n' "$output" >&2
    fi
    pragma_add_failure "$tool" "$cls" "$skip" "$skip_cmd" "$rerun" "$msg" "$output" "$status"
    return "$status"
  fi

  return 0
}

pragma_emit_failures() {
  local failures='['
  local i
  for ((i = 0; i < ${#PRAGMA_FAILURES[@]}; i++)); do
    if ((i > 0)); then
      failures+=','
    fi
    failures+="${PRAGMA_FAILURES[i]}"
  done
  failures+=']'

  printf '{"v":1,"hook":"%s","step":"%s","fails":%s,"code":%s}\n' \
    "$(pragma_json_escape "$PRAGMA_HOOK")" \
    "$(pragma_json_escape "$PRAGMA_STEP")" \
    "$failures" \
    "$PRAGMA_EXIT_CODE"
}

# Record a failure without immediately exiting (for parallel-style checks).
record_failure() {
  PRAGMA_EXIT_CODE=1
}

# Exit with the accumulated code.
exit_with_status() {
  if [[ $PRAGMA_EXIT_CODE -ne 0 ]] && ! pragma_human_output_enabled; then
    pragma_emit_failures
  fi
  exit "${PRAGMA_EXIT_CODE}"
}
