#!/usr/bin/env bash
# lint.sh — Run linters on staged files, grouped by detected language
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/detect.sh"

PRAGMA_OUTPUT_FORMAT="${PRAGMA_OUTPUT_FORMAT:-gpt}"
LINT_RERUN="./lib/lint.sh <staged-files>"

# ─── Per-language linters ─────────────────────────────────────────────────────

golangci_repo_config_path() {
  local candidate

  for candidate in \
    ".golangci.yml" \
    ".golangci.yaml" \
    ".golangci.toml" \
    ".golangci.json"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

golangci_default_config_path() {
  local candidate

  for candidate in \
    "$PRAGMA_DIR/.golangci.yml" \
    "$PRAGMA_DIR/.golangci.yaml" \
    "$PRAGMA_DIR/.golangci.toml" \
    "$PRAGMA_DIR/.golangci.json"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

lint_go() {
  local -a files=("$@")
  local -a go_files=()
  filter_by_ext go_files go -- "${files[@]}"
  [[ ${#go_files[@]} -eq 0 ]] && return 0

  if has_tool golangci-lint; then
    log_info "Linting Go files..."
    local -a golangci_args=(run --new-from-rev=HEAD --fix=false)
    local config_path

    if config_path="$(golangci_repo_config_path)"; then
      golangci_args+=(--config "$config_path")
    elif config_path="$(golangci_default_config_path)"; then
      if golangci_is_v2; then
        golangci_args+=(--config "$config_path")
      else
        log_warn "Detected golangci-lint v1; skipping Pragma's bundled v2 config"
      fi
    fi

    pragma_run "golangci-lint" "lint" 0 "" "$LINT_RERUN" "go lint failed" golangci-lint "${golangci_args[@]}" || return 1
  else
    # Fallback: go vet
    if has_tool go; then
      log_info "Linting Go files (go vet fallback)..."
      pragma_run "go" "lint" 0 "" "$LINT_RERUN" "go vet failed" go vet ./... || return 1
    else
      log_warn "Missing tool: ${BOLD}golangci-lint${RESET} or ${BOLD}go${RESET} (go linter)"
      pragma_add_failure "golangci-lint" "tool" 0 "" "$LINT_RERUN" "missing tool: golangci-lint or go" "" 1
      return 1
    fi
  fi
}

lint_rust() {
  local -a files=("$@")
  local -a rs_files=()
  filter_by_ext rs_files rs -- "${files[@]}"
  [[ ${#rs_files[@]} -eq 0 ]] && return 0

  if has_tool cargo; then
    log_info "Linting Rust files (clippy)..."
    pragma_run "cargo" "lint" 0 "" "$LINT_RERUN" "rust lint failed" cargo clippy --all-targets --all-features -- -D warnings || return 1
  else
    log_warn "cargo not found, skipping Rust lint"
    pragma_add_failure "cargo" "tool" 0 "" "$LINT_RERUN" "missing tool: cargo" "" 1
    return 1
  fi
}

lint_typescript() {
  local -a files=("$@")
  local -a ts_files=()
  filter_by_ext ts_files ts tsx js jsx -- "${files[@]}"
  [[ ${#ts_files[@]} -eq 0 ]] && return 0

  if has_tool eslint; then
    log_info "Linting TypeScript/JS files..."
    pragma_run "eslint" "lint" 0 "" "$LINT_RERUN" "typescript lint failed" eslint "${ts_files[@]}" || return 1
  else
    log_warn "Missing tool: ${BOLD}eslint${RESET} (typescript linter)"
    pragma_add_failure "eslint" "tool" 0 "" "$LINT_RERUN" "missing tool: eslint" "" 1
    return 1
  fi
}

lint_yaml() {
  local -a files=("$@")
  local -a yaml_files=()
  filter_by_ext yaml_files yml yaml -- "${files[@]}"
  [[ ${#yaml_files[@]} -eq 0 ]] && return 0

  if has_tool yamllint; then
    log_info "Linting YAML files..."
    pragma_run "yamllint" "lint" 0 "" "$LINT_RERUN" "yaml lint failed" yamllint -s "${yaml_files[@]}" || return 1
  else
    log_warn "Missing tool: ${BOLD}yamllint${RESET} (yaml linter)"
    pragma_add_failure "yamllint" "tool" 0 "" "$LINT_RERUN" "missing tool: yamllint" "" 1
    return 1
  fi
}

lint_docker() {
  local -a files=("$@")
  local -a docker_files=()
  local file

  for file in "${files[@]}"; do
    if is_dockerfile_path "$file"; then
      docker_files+=("$file")
    fi
  done

  [[ ${#docker_files[@]} -eq 0 ]] && return 0

  if has_tool hadolint; then
    log_info "Linting Dockerfiles..."
    pragma_run "hadolint" "lint" 0 "" "$LINT_RERUN" "docker lint failed" hadolint "${docker_files[@]}" || return 1
  else
    log_warn "Missing tool: ${BOLD}hadolint${RESET} (dockerfile linter)"
    pragma_add_failure "hadolint" "tool" 0 "" "$LINT_RERUN" "missing tool: hadolint" "" 1
    return 1
  fi
}

lint_shell() {
  local -a files=("$@")
  local -a sh_files=()
  filter_by_ext sh_files sh -- "${files[@]}"
  [[ ${#sh_files[@]} -eq 0 ]] && return 0

  if has_tool shellcheck; then
    log_info "Linting Shell files..."
    pragma_run "shellcheck" "lint" 0 "" "$LINT_RERUN" "shell lint failed" shellcheck -e SC2329 -x -P SCRIPTDIR "${sh_files[@]}" || return 1
  else
    log_warn "Missing tool: ${BOLD}shellcheck${RESET} (shell linter)"
    pragma_add_failure "shellcheck" "tool" 0 "" "$LINT_RERUN" "missing tool: shellcheck" "" 1
    return 1
  fi
}

lint_toml() {
  local -a files=("$@")
  local -a toml_files=()
  filter_by_ext toml_files toml -- "${files[@]}"
  [[ ${#toml_files[@]} -eq 0 ]] && return 0

  if has_tool taplo; then
    log_info "Checking TOML files..."
    pragma_run "taplo" "lint" 0 "" "$LINT_RERUN" "toml lint failed" taplo check "${toml_files[@]}" || return 1
  else
    log_warn "Missing tool: ${BOLD}taplo${RESET} (toml linter)"
    pragma_add_failure "taplo" "tool" 0 "" "$LINT_RERUN" "missing tool: taplo" "" 1
    return 1
  fi
}

lint_python() {
  local -a files=("$@")
  local -a py_files=()
  filter_by_ext py_files py -- "${files[@]}"
  [[ ${#py_files[@]} -eq 0 ]] && return 0

  if has_tool ruff; then
    log_info "Linting Python files..."
    pragma_run "ruff" "lint" 0 "" "$LINT_RERUN" "python lint failed" ruff check "${py_files[@]}" || return 1
  else
    log_warn "Missing tool: ${BOLD}ruff${RESET} (python linter)"
    pragma_add_failure "ruff" "tool" 0 "" "$LINT_RERUN" "missing tool: ruff" "" 1
    return 1
  fi
}

# ─── Dispatcher ───────────────────────────────────────────────────────────────

LINTERS=(
  "go:lint_go"
  "rust:lint_rust"
  "typescript:lint_typescript"
  "yaml:lint_yaml"
  "docker:lint_docker"
  "shell:lint_shell"
  "toml:lint_toml"
  "python:lint_python"
)

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  pragma_set_context "pre-commit" "lint"

  local -a files=("$@")
  if [[ ${#files[@]} -eq 0 ]]; then
    log_skip "No files to lint"
    exit 0
  fi

  log_header "Linting"

  local langs
  langs=$(detect_from_files "${files[@]}")

  if [[ -z "$langs" ]]; then
    log_skip "No recognized languages in staged files"
    exit 0
  fi

  for entry in "${LINTERS[@]}"; do
    local lang="${entry%%:*}"
    local func="${entry##*:}"
    if echo "$langs" | grep -qx "$lang"; then
      "$func" "${files[@]}" || record_failure
    fi
  done

  exit_with_status
}

main "$@"
