#!/usr/bin/env bash
# lint.sh — Run linters on staged files, grouped by detected language
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/detect.sh"

# ─── Per-language linters ─────────────────────────────────────────────────────

golangci_config_path() {
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

  if require_tool golangci-lint "go linter"; then
    log_info "Linting Go files..."
    local -a golangci_args=(run --new-from-rev=HEAD --fix=false)
    local config_path

    if config_path="$(golangci_config_path)"; then
      golangci_args+=(--config "$config_path")
    fi

    golangci-lint "${golangci_args[@]}" 2>&1 || {
      log_error "Go lint failed"
      return 1
    }
  else
    # Fallback: go vet
    if has_tool go; then
      log_info "Linting Go files (go vet fallback)..."
      go vet ./... 2>&1 || {
        log_error "go vet failed"
        return 1
      }
    else
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
    cargo clippy --all-targets --all-features -- -D warnings 2>&1 || {
      log_error "Rust lint (clippy) failed"
      return 1
    }
  else
    log_warn "cargo not found, skipping Rust lint"
    return 1
  fi
}

lint_typescript() {
  local -a files=("$@")
  local -a ts_files=()
  filter_by_ext ts_files ts tsx js jsx -- "${files[@]}"
  [[ ${#ts_files[@]} -eq 0 ]] && return 0

  if require_tool eslint "typescript linter"; then
    log_info "Linting TypeScript/JS files..."
    eslint "${ts_files[@]}" 2>&1 || {
      log_error "ESLint failed"
      return 1
    }
  else
    return 1
  fi
}

lint_yaml() {
  local -a files=("$@")
  local -a yaml_files=()
  filter_by_ext yaml_files yml yaml -- "${files[@]}"
  [[ ${#yaml_files[@]} -eq 0 ]] && return 0

  if require_tool yamllint "yaml linter"; then
    log_info "Linting YAML files..."
    yamllint -s "${yaml_files[@]}" 2>&1 || {
      log_error "yamllint failed"
      return 1
    }
  else
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

  if require_tool hadolint "dockerfile linter"; then
    log_info "Linting Dockerfiles..."
    hadolint "${docker_files[@]}" 2>&1 || {
      log_error "hadolint failed"
      return 1
    }
  else
    return 1
  fi
}

lint_shell() {
  local -a files=("$@")
  local -a sh_files=()
  filter_by_ext sh_files sh -- "${files[@]}"
  [[ ${#sh_files[@]} -eq 0 ]] && return 0

  if require_tool shellcheck "shell linter"; then
    log_info "Linting Shell files..."
    shellcheck -e SC2329 -x -P SCRIPTDIR "${sh_files[@]}" 2>&1 || {
      log_error "shellcheck failed"
      return 1
    }
  else
    return 1
  fi
}

lint_toml() {
  local -a files=("$@")
  local -a toml_files=()
  filter_by_ext toml_files toml -- "${files[@]}"
  [[ ${#toml_files[@]} -eq 0 ]] && return 0

  if require_tool taplo "toml linter"; then
    log_info "Checking TOML files..."
    taplo check "${toml_files[@]}" 2>&1 || {
      log_error "taplo check failed"
      return 1
    }
  else
    return 1
  fi
}

lint_python() {
  local -a files=("$@")
  local -a py_files=()
  filter_by_ext py_files py -- "${files[@]}"
  [[ ${#py_files[@]} -eq 0 ]] && return 0

  if require_tool ruff "python linter"; then
    log_info "Linting Python files..."
    ruff check "${py_files[@]}" 2>&1 || {
      log_error "ruff check failed"
      return 1
    }
  else
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
