#!/usr/bin/env bash
# format.sh — Run formatters on staged files, grouped by detected language
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/detect.sh"

# ─── Per-language formatters ──────────────────────────────────────────────────

format_go() {
  local -a files=("$@")
  local -a go_files=()
  filter_by_ext go_files go -- "${files[@]}"
  [[ ${#go_files[@]} -eq 0 ]] && return 0

  if require_tool goimports "go formatter"; then
    log_info "Formatting Go files..."
    goimports -w "${go_files[@]}"
    git add -- "${go_files[@]}"
  elif require_tool gofmt "go formatter (fallback)"; then
    log_info "Formatting Go files (gofmt)..."
    gofmt -w "${go_files[@]}"
    git add -- "${go_files[@]}"
  else
    record_failure
  fi
}

format_rust() {
  local -a files=("$@")
  local -a rs_files=()
  filter_by_ext rs_files rs -- "${files[@]}"
  [[ ${#rs_files[@]} -eq 0 ]] && return 0

  if require_tool rustfmt "rust formatter"; then
    log_info "Formatting Rust files..."
    rustfmt --edition 2021 "${rs_files[@]}" 2>/dev/null || {
      # rustfmt may fail on partial files; try cargo fmt instead
      if has_tool cargo; then
        cargo fmt 2>/dev/null || true
      fi
    }
    git add -- "${rs_files[@]}"
  else
    record_failure
  fi
}

format_typescript() {
  local -a files=("$@")
  local -a ts_files=()
  filter_by_ext ts_files ts tsx js jsx -- "${files[@]}"
  [[ ${#ts_files[@]} -eq 0 ]] && return 0

  if require_tool prettier "typescript/js formatter"; then
    log_info "Formatting TypeScript/JS files..."
    prettier --write "${ts_files[@]}" 2>/dev/null
    git add -- "${ts_files[@]}"
  else
    record_failure
  fi
}

format_html() {
  local -a files=("$@")
  local -a html_files=()
  filter_by_ext html_files html htm -- "${files[@]}"
  [[ ${#html_files[@]} -eq 0 ]] && return 0

  if require_tool prettier "html formatter"; then
    log_info "Formatting HTML files..."
    prettier --write "${html_files[@]}" 2>/dev/null
    git add -- "${html_files[@]}"
  else
    record_failure
  fi
}

format_yaml() {
  local -a files=("$@")
  local -a yaml_files=()
  filter_by_ext yaml_files yml yaml -- "${files[@]}"
  [[ ${#yaml_files[@]} -eq 0 ]] && return 0

  if require_tool prettier "yaml formatter"; then
    log_info "Formatting YAML files..."
    prettier --write "${yaml_files[@]}" 2>/dev/null
    git add -- "${yaml_files[@]}"
  else
    record_failure
  fi
}

format_shell() {
  local -a files=("$@")
  local -a sh_files=()
  filter_by_ext sh_files sh -- "${files[@]}"
  [[ ${#sh_files[@]} -eq 0 ]] && return 0

  if require_tool shfmt "shell formatter"; then
    log_info "Formatting Shell files..."
    shfmt -w -i 2 -ci "${sh_files[@]}"
    git add -- "${sh_files[@]}"
  else
    record_failure
  fi
}

format_markdown() {
  local -a files=("$@")
  local -a md_files=()
  filter_by_ext md_files md -- "${files[@]}"
  [[ ${#md_files[@]} -eq 0 ]] && return 0

  if require_tool prettier "markdown formatter"; then
    log_info "Formatting Markdown files..."
    prettier --write --prose-wrap always "${md_files[@]}" 2>/dev/null
    git add -- "${md_files[@]}"
  else
    record_failure
  fi
}

format_toml() {
  local -a files=("$@")
  local -a toml_files=()
  filter_by_ext toml_files toml -- "${files[@]}"
  [[ ${#toml_files[@]} -eq 0 ]] && return 0

  if require_tool taplo "toml formatter"; then
    log_info "Formatting TOML files..."
    taplo fmt "${toml_files[@]}"
    git add -- "${toml_files[@]}"
  else
    record_failure
  fi
}

format_json() {
  local -a files=("$@")
  local -a json_files=()
  filter_by_ext json_files json -- "${files[@]}"
  [[ ${#json_files[@]} -eq 0 ]] && return 0

  if require_tool prettier "json formatter"; then
    log_info "Formatting JSON files..."
    prettier --write "${json_files[@]}" 2>/dev/null
    git add -- "${json_files[@]}"
  else
    record_failure
  fi
}

format_python() {
  local -a files=("$@")
  local -a py_files=()
  filter_by_ext py_files py -- "${files[@]}"
  [[ ${#py_files[@]} -eq 0 ]] && return 0

  if require_tool ruff "python formatter"; then
    log_info "Formatting Python files..."
    ruff format "${py_files[@]}"
    git add -- "${py_files[@]}"
  else
    record_failure
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
