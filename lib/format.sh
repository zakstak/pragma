#!/usr/bin/env bash
# format.sh — Run formatters on staged files, grouped by detected language
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/detect.sh"

PRAGMA_OUTPUT_FORMAT="${PRAGMA_OUTPUT_FORMAT:-gpt}"
FORMAT_RERUN="./lib/format.sh <staged-files>"

# ─── Per-language formatters ──────────────────────────────────────────────────

format_go() {
  local -a files=("$@")
  local -a go_files=()
  filter_by_ext go_files go -- "${files[@]}"
  [[ ${#go_files[@]} -eq 0 ]] && return 0

  if has_tool goimports; then
    log_info "Formatting Go files..."
    pragma_run "goimports" "fmt" 0 "" "$FORMAT_RERUN" "go formatting failed" goimports -w "${go_files[@]}" || return 1
    git add -- "${go_files[@]}"
  elif has_tool gofmt; then
    log_info "Formatting Go files (gofmt)..."
    pragma_run "gofmt" "fmt" 0 "" "$FORMAT_RERUN" "go formatting failed" gofmt -w "${go_files[@]}" || return 1
    git add -- "${go_files[@]}"
  else
    log_warn "Missing tool: ${BOLD}goimports${RESET} or ${BOLD}gofmt${RESET} (go formatter)"
    pragma_add_failure "goimports" "tool" 0 "" "$FORMAT_RERUN" "missing tool: goimports or gofmt" "" 1
    return 1
  fi
}

format_rust() {
  local -a files=("$@")
  local -a rs_files=()
  filter_by_ext rs_files rs -- "${files[@]}"
  [[ ${#rs_files[@]} -eq 0 ]] && return 0

  if has_tool rustfmt; then
    log_info "Formatting Rust files..."
    if ! pragma_run "rustfmt" "fmt" 0 "" "$FORMAT_RERUN" "rust formatting failed" rustfmt --edition 2021 "${rs_files[@]}"; then
      if has_tool cargo; then
        pragma_run "cargo" "fmt" 0 "" "$FORMAT_RERUN" "rust formatting failed" cargo fmt || return 1
      else
        return 1
      fi
    fi
    git add -- "${rs_files[@]}"
  else
    log_warn "Missing tool: ${BOLD}rustfmt${RESET} (rust formatter)"
    pragma_add_failure "rustfmt" "tool" 0 "" "$FORMAT_RERUN" "missing tool: rustfmt" "" 1
    return 1
  fi
}

format_typescript() {
  local -a files=("$@")
  local -a ts_files=()
  filter_by_ext ts_files ts tsx js jsx -- "${files[@]}"
  [[ ${#ts_files[@]} -eq 0 ]] && return 0

  if has_tool prettier; then
    log_info "Formatting TypeScript/JS files..."
    pragma_run "prettier" "fmt" 0 "" "$FORMAT_RERUN" "typescript formatting failed" prettier --write "${ts_files[@]}" || return 1
    git add -- "${ts_files[@]}"
  else
    log_warn "Missing tool: ${BOLD}prettier${RESET} (typescript/js formatter)"
    pragma_add_failure "prettier" "tool" 0 "" "$FORMAT_RERUN" "missing tool: prettier" "" 1
    return 1
  fi
}

format_html() {
  local -a files=("$@")
  local -a html_files=()
  filter_by_ext html_files html htm -- "${files[@]}"
  [[ ${#html_files[@]} -eq 0 ]] && return 0

  if has_tool prettier; then
    log_info "Formatting HTML files..."
    pragma_run "prettier" "fmt" 0 "" "$FORMAT_RERUN" "html formatting failed" prettier --write "${html_files[@]}" || return 1
    git add -- "${html_files[@]}"
  else
    log_warn "Missing tool: ${BOLD}prettier${RESET} (html formatter)"
    pragma_add_failure "prettier" "tool" 0 "" "$FORMAT_RERUN" "missing tool: prettier" "" 1
    return 1
  fi
}

format_yaml() {
  local -a files=("$@")
  local -a yaml_files=()
  filter_by_ext yaml_files yml yaml -- "${files[@]}"
  [[ ${#yaml_files[@]} -eq 0 ]] && return 0

  if has_tool prettier; then
    log_info "Formatting YAML files..."
    pragma_run "prettier" "fmt" 0 "" "$FORMAT_RERUN" "yaml formatting failed" prettier --write "${yaml_files[@]}" || return 1
    git add -- "${yaml_files[@]}"
  else
    log_warn "Missing tool: ${BOLD}prettier${RESET} (yaml formatter)"
    pragma_add_failure "prettier" "tool" 0 "" "$FORMAT_RERUN" "missing tool: prettier" "" 1
    return 1
  fi
}

format_shell() {
  local -a files=("$@")
  local -a sh_files=()
  filter_by_ext sh_files sh -- "${files[@]}"
  [[ ${#sh_files[@]} -eq 0 ]] && return 0

  if has_tool shfmt; then
    log_info "Formatting Shell files..."
    pragma_run "shfmt" "fmt" 0 "" "$FORMAT_RERUN" "shell formatting failed" shfmt -w -i 2 -ci "${sh_files[@]}" || return 1
    git add -- "${sh_files[@]}"
  else
    log_warn "Missing tool: ${BOLD}shfmt${RESET} (shell formatter)"
    pragma_add_failure "shfmt" "tool" 0 "" "$FORMAT_RERUN" "missing tool: shfmt" "" 1
    return 1
  fi
}

format_markdown() {
  local -a files=("$@")
  local -a md_files=()
  filter_by_ext md_files md -- "${files[@]}"
  [[ ${#md_files[@]} -eq 0 ]] && return 0

  if has_tool prettier; then
    log_info "Formatting Markdown files..."
    pragma_run "prettier" "fmt" 0 "" "$FORMAT_RERUN" "markdown formatting failed" prettier --write --prose-wrap always "${md_files[@]}" || return 1
    git add -- "${md_files[@]}"
  else
    log_warn "Missing tool: ${BOLD}prettier${RESET} (markdown formatter)"
    pragma_add_failure "prettier" "tool" 0 "" "$FORMAT_RERUN" "missing tool: prettier" "" 1
    return 1
  fi
}

format_toml() {
  local -a files=("$@")
  local -a toml_files=()
  filter_by_ext toml_files toml -- "${files[@]}"
  [[ ${#toml_files[@]} -eq 0 ]] && return 0

  if has_tool taplo; then
    log_info "Formatting TOML files..."
    pragma_run "taplo" "fmt" 0 "" "$FORMAT_RERUN" "toml formatting failed" taplo fmt "${toml_files[@]}" || return 1
    git add -- "${toml_files[@]}"
  else
    log_warn "Missing tool: ${BOLD}taplo${RESET} (toml formatter)"
    pragma_add_failure "taplo" "tool" 0 "" "$FORMAT_RERUN" "missing tool: taplo" "" 1
    return 1
  fi
}

format_json() {
  local -a files=("$@")
  local -a json_files=()
  filter_by_ext json_files json -- "${files[@]}"
  [[ ${#json_files[@]} -eq 0 ]] && return 0

  if has_tool prettier; then
    log_info "Formatting JSON files..."
    pragma_run "prettier" "fmt" 0 "" "$FORMAT_RERUN" "json formatting failed" prettier --write "${json_files[@]}" || return 1
    git add -- "${json_files[@]}"
  else
    log_warn "Missing tool: ${BOLD}prettier${RESET} (json formatter)"
    pragma_add_failure "prettier" "tool" 0 "" "$FORMAT_RERUN" "missing tool: prettier" "" 1
    return 1
  fi
}

format_python() {
  local -a files=("$@")
  local -a py_files=()
  filter_by_ext py_files py -- "${files[@]}"
  [[ ${#py_files[@]} -eq 0 ]] && return 0

  if has_tool ruff; then
    log_info "Formatting Python files..."
    pragma_run "ruff" "fmt" 0 "" "$FORMAT_RERUN" "python formatting failed" ruff format "${py_files[@]}" || return 1
    git add -- "${py_files[@]}"
  else
    log_warn "Missing tool: ${BOLD}ruff${RESET} (python formatter)"
    pragma_add_failure "ruff" "tool" 0 "" "$FORMAT_RERUN" "missing tool: ruff" "" 1
    return 1
  fi
}

# ─── Dispatcher ───────────────────────────────────────────────────────────────

# Docker and gitleaks have no formatting step — intentionally omitted.

FORMATTERS=(
  "go:format_go"
  "rust:format_rust"
  "typescript:format_typescript"
  "html:format_html"
  "yaml:format_yaml"
  "shell:format_shell"
  "markdown:format_markdown"
  "toml:format_toml"
  "json:format_json"
  "python:format_python"
)

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  pragma_set_context "pre-commit" "format"

  local -a files=("$@")
  if [[ ${#files[@]} -eq 0 ]]; then
    log_skip "No files to format"
    exit 0
  fi

  log_header "Formatting"

  local langs
  langs=$(detect_from_files "${files[@]}")

  if [[ -z "$langs" ]]; then
    log_skip "No recognized languages in staged files"
    exit 0
  fi

  for entry in "${FORMATTERS[@]}"; do
    local lang="${entry%%:*}"
    local func="${entry##*:}"
    if echo "$langs" | grep -qx "$lang"; then
      "$func" "${files[@]}" || record_failure
    fi
  done

  exit_with_status
}

main "$@"
