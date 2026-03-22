#!/usr/bin/env bash
# format.sh — Run formatters on staged files, grouped by detected language
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/detect.sh"

# ─── Per-language formatters ──────────────────────────────────────────────────

format_go() {
  local files="$1"
  local go_files
  go_files=$(filter_by_ext "$files" go)
  [[ -z "$go_files" ]] && return 0

  if require_tool goimports "go formatter"; then
    log_info "Formatting Go files..."
    echo "$go_files" | xargs goimports -w
    # Re-stage formatted files
    echo "$go_files" | xargs git add
  elif require_tool gofmt "go formatter (fallback)"; then
    log_info "Formatting Go files (gofmt)..."
    echo "$go_files" | xargs gofmt -w
    echo "$go_files" | xargs git add
  else
    record_failure
  fi
}

format_rust() {
  local files="$1"
  local rs_files
  rs_files=$(filter_by_ext "$files" rs)
  [[ -z "$rs_files" ]] && return 0

  if require_tool rustfmt "rust formatter"; then
    log_info "Formatting Rust files..."
    echo "$rs_files" | xargs rustfmt --edition 2021 2>/dev/null || {
      # rustfmt may fail on partial files; try cargo fmt instead
      if has_tool cargo; then
        cargo fmt 2>/dev/null || true
      fi
    }
    echo "$rs_files" | xargs git add
  else
    record_failure
  fi
}

format_typescript() {
  local files="$1"
  local ts_files
  ts_files=$(filter_by_ext "$files" ts tsx js jsx)
  [[ -z "$ts_files" ]] && return 0

  if require_tool prettier "typescript/js formatter"; then
    log_info "Formatting TypeScript/JS files..."
    echo "$ts_files" | xargs prettier --write 2>/dev/null
    echo "$ts_files" | xargs git add
  else
    record_failure
  fi
}

format_html() {
  local files="$1"
  local html_files
  html_files=$(filter_by_ext "$files" html htm)
  [[ -z "$html_files" ]] && return 0

  if require_tool prettier "html formatter"; then
    log_info "Formatting HTML files..."
    echo "$html_files" | xargs prettier --write 2>/dev/null
    echo "$html_files" | xargs git add
  else
    record_failure
  fi
}

format_yaml() {
  local files="$1"
  local yaml_files
  yaml_files=$(filter_by_ext "$files" yml yaml)
  [[ -z "$yaml_files" ]] && return 0

  if require_tool prettier "yaml formatter"; then
    log_info "Formatting YAML files..."
    echo "$yaml_files" | xargs prettier --write 2>/dev/null
    echo "$yaml_files" | xargs git add
  else
    record_failure
  fi
}

format_shell() {
  local files="$1"
  local sh_files
  sh_files=$(filter_by_ext "$files" sh)
  [[ -z "$sh_files" ]] && return 0

  if require_tool shfmt "shell formatter"; then
    log_info "Formatting Shell files..."
    echo "$sh_files" | xargs shfmt -w -i 2 -ci
    echo "$sh_files" | xargs git add
  else
    record_failure
  fi
}

format_markdown() {
  local files="$1"
  local md_files
  md_files=$(filter_by_ext "$files" md)
  [[ -z "$md_files" ]] && return 0

  if require_tool prettier "markdown formatter"; then
    log_info "Formatting Markdown files..."
    echo "$md_files" | xargs prettier --write --prose-wrap always 2>/dev/null
    echo "$md_files" | xargs git add
  else
    record_failure
  fi
}

format_toml() {
  local files="$1"
  local toml_files
  toml_files=$(filter_by_ext "$files" toml)
  [[ -z "$toml_files" ]] && return 0

  if require_tool taplo "toml formatter"; then
    log_info "Formatting TOML files..."
    echo "$toml_files" | xargs taplo fmt
    echo "$toml_files" | xargs git add
  else
    record_failure
  fi
}

format_json() {
  local files="$1"
  local json_files
  json_files=$(filter_by_ext "$files" json)
  [[ -z "$json_files" ]] && return 0

  if require_tool prettier "json formatter"; then
    log_info "Formatting JSON files..."
    echo "$json_files" | xargs prettier --write 2>/dev/null
    echo "$json_files" | xargs git add
  else
    record_failure
  fi
}

format_python() {
  local files="$1"
  local py_files
  py_files=$(filter_by_ext "$files" py)
  [[ -z "$py_files" ]] && return 0

  if require_tool ruff "python formatter"; then
    log_info "Formatting Python files..."
    echo "$py_files" | xargs ruff format
    echo "$py_files" | xargs git add
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
  local files="${*:-}"
  if [[ -z "$files" ]]; then
    log_skip "No files to format"
    exit 0
  fi

  log_header "Formatting"

  local langs
  langs=$(detect_from_files "$files")

  if [[ -z "$langs" ]]; then
    log_skip "No recognized languages in staged files"
    exit 0
  fi

  for entry in "${FORMATTERS[@]}"; do
    local lang="${entry%%:*}"
    local func="${entry##*:}"
    if echo "$langs" | grep -qx "$lang"; then
      "$func" "$files" || record_failure
    fi
  done

  exit_with_status
}

main "$@"
