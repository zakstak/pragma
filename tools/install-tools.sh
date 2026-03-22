#!/usr/bin/env bash
# install-tools.sh — Install missing tools for pragma
#
# Usage:
#   install-tools.sh [--agent]    # --agent for non-interactive auto-install
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/detect.sh"

AGENT_MODE="${1:-}"
[[ "$AGENT_MODE" == "--agent" ]] && AGENT_MODE="true" || AGENT_MODE="false"

# ─── Install helpers ──────────────────────────────────────────────────────────

try_install() {
  local tool="$1"
  local method="$2"
  local package="$3"

  case "$method" in
    nix)
      if has_tool nix-env; then
        log_info "Installing $tool via nix..."
        nix-env -iA "nixpkgs.$package"
        return $?
      fi
      return 1
      ;;
    go)
      if has_tool go; then
        log_info "Installing $tool via go install..."
        go install "$package"
        return $?
      fi
      return 1
      ;;
    cargo)
      if has_tool cargo; then
        log_info "Installing $tool via cargo install..."
        cargo install "$package"
        return $?
      fi
      return 1
      ;;
    npm)
      if has_tool npm; then
        log_info "Installing $tool via npm..."
        npm install -g "$package"
        return $?
      elif has_tool bun; then
        log_info "Installing $tool via bun..."
        bun install -g "$package"
        return $?
      fi
      return 1
      ;;
    pip)
      if has_tool pip; then
        log_info "Installing $tool via pip..."
        pip install "$package"
        return $?
      elif has_tool pipx; then
        log_info "Installing $tool via pipx..."
        pipx install "$package"
        return $?
      fi
      return 1
      ;;
    binary)
      log_info "Installing $tool via direct download..."
      eval "$package"
      return $?
      ;;
    *)
      return 1
      ;;
  esac
}

# Tool → install methods (tried in order)
declare -A TOOL_INSTALLS=(
  # Core
  [lefthook]="nix:lefthook go:github.com/evilmartians/lefthook@latest"
  [gitleaks]="nix:gitleaks go:github.com/gitleaks/gitleaks/v8@latest"

  # Go
  [goimports]="go:golang.org/x/tools/cmd/goimports@latest"
  [golangci-lint]="nix:golangci-lint go:github.com/golangci/golangci-lint/cmd/golangci-lint@latest"

  # Rust (usually already present if Rust is used)
  [rustfmt]="nix:rustfmt"
  [clippy]="nix:clippy"

  # Node/TS
  [prettier]="npm:prettier"
  [eslint]="npm:eslint"

  # YAML
  [yamllint]="pip:yamllint nix:yamllint"

  # Docker
  [hadolint]="nix:hadolint"

  # Shell
  [shellcheck]="nix:shellcheck"
  [shfmt]="nix:shfmt go:mvdan.cc/sh/v3/cmd/shfmt@latest"

  # TOML
  [taplo]="cargo:taplo-cli nix:taplo"

  # Python
  [ruff]="pip:ruff nix:ruff cargo:ruff"
)

# ─── Language → required tools mapping ────────────────────────────────────────

tools_for_lang() {
  local lang="$1"
  case "$lang" in
    go)         echo "goimports golangci-lint" ;;
    rust)       echo "rustfmt" ;;
    typescript) echo "prettier eslint" ;;
    html)       echo "prettier" ;;
    yaml)       echo "prettier yamllint" ;;
    docker)     echo "hadolint" ;;
    shell)      echo "shellcheck shfmt" ;;
    markdown)   echo "prettier" ;;
    toml)       echo "taplo" ;;
    json)       echo "prettier" ;;
    python)     echo "ruff" ;;
    *)          echo "" ;;
  esac
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  log_header "Tool Installation Check"

  # Always need these
  local required_tools=("lefthook" "gitleaks")

  # Detect languages and add their tools
  local langs
  langs=$(detect_from_repo)
  log_info "Detected languages: $(echo "$langs" | tr '\n' ' ')"

  while IFS= read -r lang; do
    [[ -z "$lang" ]] && continue
    for tool in $(tools_for_lang "$lang"); do
      # Deduplicate
      local already=false
      for existing in "${required_tools[@]}"; do
        [[ "$existing" == "$tool" ]] && already=true && break
      done
      $already || required_tools+=("$tool")
    done
  done <<< "$langs"

  # Check and install
  local missing=()
  for tool in "${required_tools[@]}"; do
    if has_tool "$tool"; then
      log_success "$tool is available"
    else
      missing+=("$tool")
      log_warn "$tool is ${BOLD}missing${RESET}"
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    log_success "All tools are installed!"
    return 0
  fi

  echo ""
  log_info "${#missing[@]} tool(s) need to be installed: ${BOLD}${missing[*]}${RESET}"

  if [[ "$AGENT_MODE" == "false" ]]; then
    echo ""
    read -rp "Install missing tools? [Y/n] " answer
    [[ "$answer" =~ ^[Nn] ]] && {
      log_warn "Skipping tool installation"
      return 1
    }
  fi

  local failed=()
  for tool in "${missing[@]}"; do
    local methods="${TOOL_INSTALLS[$tool]:-}"
    if [[ -z "$methods" ]]; then
      log_warn "No install method known for $tool"
      failed+=("$tool")
      continue
    fi

    local installed=false
    for entry in $methods; do
      local method="${entry%%:*}"
      local package="${entry##*:}"
      if try_install "$tool" "$method" "$package"; then
        log_success "Installed $tool"
        installed=true
        break
      fi
    done

    if ! $installed; then
      log_error "Failed to install $tool"
      failed+=("$tool")
    fi
  done

  if [[ ${#failed[@]} -gt 0 ]]; then
    echo ""
    log_error "Failed to install: ${failed[*]}"
    log_info "Please install these manually and re-run"
    return 1
  fi

  log_success "All tools installed!"
}

main
