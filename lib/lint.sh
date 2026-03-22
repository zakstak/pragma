#!/usr/bin/env bash
# lint.sh — Run linters on staged files, grouped by detected language
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/detect.sh"

# ─── Per-language linters ─────────────────────────────────────────────────────

lint_go() {
  local files="$1"
  local go_files
  go_files=$(filter_by_ext "$files" go)
  [[ -z "$go_files" ]] && return 0

  if require_tool golangci-lint "go linter"; then
    log_info "Linting Go files..."
    golangci-lint run --new-from-rev=HEAD --fix=false 2>&1 || {
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
  local files="$1"
  local rs_files
  rs_files=$(filter_by_ext "$files" rs)
  [[ -z "$rs_files" ]] && return 0

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
  local files="$1"
  local ts_files
  ts_files=$(filter_by_ext "$files" ts tsx js jsx)
  [[ -z "$ts_files" ]] && return 0

  if require_tool eslint "typescript linter"; then
    log_info "Linting TypeScript/JS files..."
    echo "$ts_files" | xargs eslint 2>&1 || {
      log_error "ESLint failed"
      return 1
    }
  else
    return 1
  fi
}

lint_yaml() {
  local files="$1"
  local yaml_files
  yaml_files=$(filter_by_ext "$files" yml yaml)
  [[ -z "$yaml_files" ]] && return 0

  if require_tool yamllint "yaml linter"; then
    log_info "Linting YAML files..."
    echo "$yaml_files" | xargs yamllint -s 2>&1 || {
      log_error "yamllint failed"
      return 1
    }
  else
    return 1
  fi
}

lint_docker() {
  local files="$1"
  local docker_files
  docker_files=$(echo "$files" | tr ' ' '\n' | grep -iE '(Dockerfile|\.dockerfile)$' || true)
  [[ -z "$docker_files" ]] && return 0

  if require_tool hadolint "dockerfile linter"; then
    log_info "Linting Dockerfiles..."
    echo "$docker_files" | xargs hadolint 2>&1 || {
      log_error "hadolint failed"
      return 1
    }
  else
    return 1
  fi
}

lint_shell() {
  local files="$1"
  local sh_files
  sh_files=$(filter_by_ext "$files" sh)
  [[ -z "$sh_files" ]] && return 0

  if require_tool shellcheck "shell linter"; then
    log_info "Linting Shell files..."
    echo "$sh_files" | xargs shellcheck 2>&1 || {
      log_error "shellcheck failed"
      return 1
    }
  else
    return 1
  fi
}

lint_toml() {
  local files="$1"
  local toml_files
  toml_files=$(filter_by_ext "$files" toml)
  [[ -z "$toml_files" ]] && return 0

  if require_tool taplo "toml linter"; then
    log_info "Checking TOML files..."
    echo "$toml_files" | xargs taplo check 2>&1 || {
      log_error "taplo check failed"
      return 1
    }
  else
    return 1
  fi
}

lint_python() {
  local files="$1"
  local py_files
  py_files=$(filter_by_ext "$files" py)
  [[ -z "$py_files" ]] && return 0

  if require_tool ruff "python linter"; then
    log_info "Linting Python files..."
    echo "$py_files" | xargs ruff check 2>&1 || {
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
  local files="${*:-}"
  if [[ -z "$files" ]]; then
    log_skip "No files to lint"
    exit 0
  fi

  log_header "Linting"

  local langs
  langs=$(detect_from_files "$files")

  if [[ -z "$langs" ]]; then
    log_skip "No recognized languages in staged files"
    exit 0
  fi

  for entry in "${LINTERS[@]}"; do
    local lang="${entry%%:*}"
    local func="${entry##*:}"
    if echo "$langs" | grep -qx "$lang"; then
      "$func" "$files" || record_failure
    fi
  done

  exit_with_status
}

main "$@"
