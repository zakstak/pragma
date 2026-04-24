#!/usr/bin/env bash
# install.sh — Bootstrap pragma into a target repository
#
# Usage:
#   pragma/install.sh [--agent] [--docker-tools] [/path/to/target-repo]
#
# Options:
#   --agent         Non-interactive mode (auto-install tools, no prompts)
#   --docker-tools  Use the Docker tooling image instead of host-installed tools
#
# If no target repo is specified, uses the current directory.
set -euo pipefail

PRAGMA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PRAGMA_DIR/lib/common.sh"

UNSUPPORTED_HOST_ERROR="Unsupported host: Pragma bootstrap/install-tools are supported on macOS and Linux only."

case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
  darwin | linux) ;;
  *)
    log_error "$UNSUPPORTED_HOST_ERROR"
    exit 1
    ;;
esac

# ─── Parse arguments ─────────────────────────────────────────────────────────

AGENT_MODE=false
DOCKER_TOOLS=false
TARGET_REPO=""

for arg in "$@"; do
  case "$arg" in
    --agent) AGENT_MODE=true ;;
    --docker-tools) DOCKER_TOOLS=true ;;
    *) TARGET_REPO="$arg" ;;
  esac
done

TARGET_REPO="${TARGET_REPO:-.}"

if [[ ! -e "$TARGET_REPO" ]]; then
  log_error "$TARGET_REPO does not exist"
  exit 1
fi

if [[ ! -d "$TARGET_REPO" ]]; then
  log_error "$TARGET_REPO is not a directory"
  exit 1
fi

TARGET_REPO="$(cd "$TARGET_REPO" && pwd)"
SELF_INSTALL=false
LEFTHOOK_TEMPLATE="$PRAGMA_DIR/lefthook.yml"
DOCKER_WRAPPER_BIN_DIR="$PRAGMA_DIR/bin/docker"

if [[ "$TARGET_REPO" == "$PRAGMA_DIR" ]]; then
  SELF_INSTALL=true
fi

# ─── Validation ───────────────────────────────────────────────────────────────

if ! git -C "$TARGET_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log_error "$TARGET_REPO is not a git repository"
  exit 1
fi

# Add pragma/bin to PATH if it exists (installed binaries or Docker wrappers)
pragma_prepend_path "$PRAGMA_DIR/bin"

# Add GOPATH/bin to PATH so go-installed tools are found in native mode.
if ! $DOCKER_TOOLS; then
  _gobin="${GOBIN:-}"

  if [[ -z "$_gobin" ]] && has_tool go; then
    _gobin="$(go env GOBIN 2>/dev/null || true)"

    if [[ -z "$_gobin" ]]; then
      _gopath="$(go env GOPATH 2>/dev/null || true)"
      _gobin="${_gopath:+$_gopath/bin}"
      unset _gopath
    fi
  fi

  _gobin="${_gobin:-$HOME/go/bin}"
  if [[ -d "$_gobin" ]] && [[ ":$PATH:" != *":$_gobin:"* ]]; then
    pragma_prepend_path "$_gobin"
  fi
  unset _gobin
fi

log_header "Pragma Setup"
log_info "Pragma dir: ${BOLD}$PRAGMA_DIR${RESET}"
log_info "Target repo:   ${BOLD}$TARGET_REPO${RESET}"
log_info "Mode:          ${BOLD}$(if $AGENT_MODE; then echo "agent (non-interactive)"; else echo "interactive"; fi)${RESET}"
log_info "Tooling:       ${BOLD}$(if $DOCKER_TOOLS; then echo "docker image"; else echo "host install"; fi)${RESET}"
echo ""

shell_escape_arg() {
  printf '%q' "$1"
}

render_command_prefix() {
  if $DOCKER_TOOLS; then
    printf 'PRAGMA_DOCKER_BIN_DIR=%s ' "$(shell_escape_arg "$DOCKER_WRAPPER_BIN_DIR")"
  fi
}

if $DOCKER_TOOLS; then
  if $AGENT_MODE; then
    (cd "$TARGET_REPO" && "$PRAGMA_DIR/tools/install-tools.sh" --docker --agent) || {
      log_error "docker tooling setup failed"
      exit 1
    }
  else
    (cd "$TARGET_REPO" && "$PRAGMA_DIR/tools/install-tools.sh" --docker) || {
      log_error "docker tooling setup failed"
      exit 1
    }
  fi

  pragma_prepend_path "$DOCKER_WRAPPER_BIN_DIR"
  hash -r 2>/dev/null || true
  echo ""
fi

# ─── Step 1: Install lefthook if needed ───────────────────────────────────────

if ! has_tool lefthook; then
  log_warn "lefthook is not installed"

  if $AGENT_MODE; then
    log_info "Installing lefthook..."
    if (cd "$TARGET_REPO" && PRAGMA_INSTALL_ONLY_TOOLS="lefthook" "$PRAGMA_DIR/tools/install-tools.sh" --agent); then
      :
    elif has_tool nix-env; then
      nix-env -iA nixpkgs.lefthook
    else
      log_error "Cannot install lefthook automatically"
      log_info "Install manually: https://github.com/evilmartians/lefthook/blob/master/docs/install.md"
      exit 1
    fi
  else
    log_info "Install lefthook via one of:"
    echo "  $PRAGMA_DIR/tools/install-tools.sh --agent"
    echo "  nix-env -iA nixpkgs.lefthook"
    echo "  brew install lefthook"
    echo ""
    read -rp "Attempt auto-install via Pragma's pinned installer? [Y/n] " answer
    if [[ ! "$answer" =~ ^[Nn] ]]; then
      (cd "$TARGET_REPO" && PRAGMA_INSTALL_ONLY_TOOLS="lefthook" "$PRAGMA_DIR/tools/install-tools.sh" --agent) || {
        log_error "Failed to install lefthook"
        exit 1
      }
    else
      log_error "lefthook is required. Please install and re-run."
      exit 1
    fi
  fi

  # Ensure GOPATH/bin is in PATH so we can find the just-installed binary
  GOBIN_DIR="${GOBIN:-$(go env GOBIN 2>/dev/null)}"
  GOBIN_DIR="${GOBIN_DIR:-$(go env GOPATH 2>/dev/null)/bin}"
  GOBIN_DIR="${GOBIN_DIR:-$HOME/go/bin}"
  if [[ -d "$GOBIN_DIR" ]] && [[ ":$PATH:" != *":$GOBIN_DIR:"* ]]; then
    export PATH="$GOBIN_DIR:$PATH"
    hash -r 2>/dev/null || true
  fi

  if has_tool lefthook; then
    log_success "lefthook installed"
  else
    log_error "lefthook installation failed"
    exit 1
  fi
else
  log_success "lefthook is available ($(lefthook version 2>/dev/null || echo 'unknown version'))"
fi

# ─── Step 2: Generate lefthook.yml in target repo ────────────────────────────

LEFTHOOK_CONFIG="$TARGET_REPO/lefthook.yml"

render_config_line() {
  local line="$1"
  local command_prefix
  command_prefix="$(render_command_prefix)"

  if [[ "$line" == *"./lib/"* ]]; then
    local prefix suffix script_path remainder
    prefix="${line%%./lib/*}"
    suffix="${line#*./lib/}"
    script_path="${suffix%% *}"
    remainder="${suffix#"$script_path"}"

    if $SELF_INSTALL; then
      printf '%s%s./lib/%s%s\n' "$prefix" "$command_prefix" "$script_path" "$remainder"
    else
      printf '%s%s%s%s\n' "$prefix" "$command_prefix" "$(shell_escape_arg "$PRAGMA_DIR/lib/$script_path")" "$remainder"
    fi
    return
  fi

  printf '%s\n' "$line"
}

write_self_install_template() {
  local output_path="$1"

  if git -C "$TARGET_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
    git -C "$TARGET_REPO" show HEAD:lefthook.yml >"$output_path" 2>/dev/null; then
    return 0
  fi

  cp "$LEFTHOOK_TEMPLATE" "$output_path"
}

generate_config() {
  local template_source="$LEFTHOOK_TEMPLATE"
  local temp_template=""

  if $SELF_INSTALL; then
    temp_template="$(mktemp)"
    write_self_install_template "$temp_template"
    template_source="$temp_template"
  fi

  {
    printf '# Generated by pragma — https://github.com/zakstak/pragma\n'
    printf '# To regenerate: %s/install.sh%s %s\n\n' "$PRAGMA_DIR" "$(if $DOCKER_TOOLS; then printf ' --docker-tools'; fi)" "$TARGET_REPO"

    while IFS= read -r line || [[ -n "$line" ]]; do
      render_config_line "$line"
    done <"$template_source"
  } >"$LEFTHOOK_CONFIG"

  if [[ -n "$temp_template" ]]; then
    rm -f "$temp_template"
  fi
}

restore_self_install_config() {
  local temp_template

  temp_template="$(mktemp)"
  write_self_install_template "$temp_template"
  cp "$temp_template" "$LEFTHOOK_CONFIG"
  rm -f "$temp_template"
}

if [[ ! -f "$LEFTHOOK_TEMPLATE" ]]; then
  log_error "Missing canonical lefthook config: $LEFTHOOK_TEMPLATE"
  exit 1
fi

if $SELF_INSTALL; then
  if [[ -f "$LEFTHOOK_CONFIG" ]]; then
    if $DOCKER_TOOLS; then
      log_info "Self-install detected; updating repo-local lefthook.yml for Docker-backed tools"
      generate_config
      log_success "Updated repo-local lefthook.yml at $LEFTHOOK_CONFIG"
    elif grep -Fq 'PRAGMA_DOCKER_BIN_DIR=' "$LEFTHOOK_CONFIG"; then
      log_info "Self-install detected; restoring repo-local lefthook.yml from tracked template"
      restore_self_install_config
      log_success "Restored repo-local lefthook.yml at $LEFTHOOK_CONFIG"
    else
      log_info "Self-install detected; keeping repo-local lefthook.yml"
      log_success "Using repo-local lefthook.yml at $LEFTHOOK_CONFIG"
    fi
  else
    log_error "Self-install requires repo-local lefthook.yml at $LEFTHOOK_CONFIG"
    exit 1
  fi
elif [[ -f "$LEFTHOOK_CONFIG" ]]; then
  if $AGENT_MODE; then
    log_info "Overwriting existing lefthook.yml"
    generate_config
  else
    log_warn "lefthook.yml already exists in target repo"
    read -rp "Overwrite? [y/N] " answer
    if [[ "$answer" =~ ^[Yy] ]]; then
      generate_config
    else
      log_info "Keeping existing lefthook.yml"
    fi
  fi
else
  generate_config
fi

if ! $SELF_INSTALL; then
  log_success "lefthook.yml written to $LEFTHOOK_CONFIG"
fi

# ─── Step 3: Copy gitleaks config if target doesn't have one ──────────────────

if [[ ! -f "$TARGET_REPO/.gitleaks.toml" ]]; then
  cp "$PRAGMA_DIR/.gitleaks.toml" "$TARGET_REPO/.gitleaks.toml"
  log_success "Copied default .gitleaks.toml"
else
  log_skip "Target repo already has .gitleaks.toml"
fi

# ─── Step 4: Run lefthook install ─────────────────────────────────────────────

log_info "Installing git hooks via lefthook..."
(cd "$TARGET_REPO" && lefthook install) || {
  log_error "lefthook install failed"
  exit 1
}
log_success "Git hooks installed"

# ─── Step 5: Install required tools ───────────────────────────────────────────

echo ""
if $DOCKER_TOOLS; then
  log_skip "Docker-backed tool wrappers already installed"
elif $AGENT_MODE; then
  (cd "$TARGET_REPO" && "$PRAGMA_DIR/tools/install-tools.sh" --agent)
else
  (cd "$TARGET_REPO" && "$PRAGMA_DIR/tools/install-tools.sh")
fi

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
log_header "Setup Complete"
log_success "Pragma is configured for ${BOLD}$TARGET_REPO${RESET}"
echo ""
log_info "Hooks installed:"
echo "  ${GREEN}pre-commit${RESET} → format + lint + gitleaks"
echo "  ${GREEN}pre-push${RESET}   → tests"
echo ""
log_info "To skip hooks temporarily:"
echo "  git commit --no-verify"
echo "  git push --no-verify"
echo ""
log_info "To uninstall:"
echo "  cd $TARGET_REPO && lefthook uninstall"
