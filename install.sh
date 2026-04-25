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
DOCKER_WRAPPER_BIN_DIR="$PRAGMA_DIR/bin/docker"
HOOK_WRAPPER_DIR="$TARGET_REPO/.pragma-hooks"

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

render_runtime_pragma_dir() {
  if [[ "$PRAGMA_DIR" == "$HOME/.pragma" ]]; then
    printf '"%s/.pragma"' "\$HOME"
  else
    shell_escape_arg "$PRAGMA_DIR"
  fi
}

render_regenerate_command() {
  local install_root="$PRAGMA_DIR"

  if [[ "$PRAGMA_DIR" == "$HOME/.pragma" ]]; then
    install_root="${PRAGMA_DIR/#$HOME/\~}"
  fi

  printf '%s/install.sh%s %s' \
    "$install_root" \
    "$(if $DOCKER_TOOLS; then printf ' --docker-tools'; fi)" \
    "$TARGET_REPO"
}

toml_escape_string() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s' "$value"
}

render_entry_path() {
  local script_path="$1"

  if $SELF_INSTALL; then
    printf './lib/%s' "$script_path"
  else
    printf '.pragma-hooks/%s' "$script_path"
  fi
}

write_env_line() {
  if $SELF_INSTALL && $DOCKER_TOOLS; then
    printf 'env = { PRAGMA_DOCKER_BIN_DIR = "%s" }\n' "$(toml_escape_string "$DOCKER_WRAPPER_BIN_DIR")"
  fi
}

write_canonical_template() {
  local output_path="$1"

  cat >"$output_path" <<'EOF'
[[repos]]
repo = "local"

[[repos.hooks]]
id = "format"
name = "format"
entry = "./lib/format.sh"
language = "script"
files = '\.(go|rs|ts|tsx|js|jsx|html|htm|templ|yml|yaml|sh|md|toml|json|py)$'
stages = ["pre-commit"]

[[repos.hooks]]
id = "lint"
name = "lint"
entry = "./lib/lint.sh"
language = "script"
files = '(\.(go|rs|ts|tsx|js|jsx|yml|yaml|sh|toml|py)$)|((^|/)([Dd]ockerfile(\.[^/]+)?|[^/]+\.[Dd]ockerfile)$)'
stages = ["pre-commit"]

[[repos.hooks]]
id = "gitleaks"
name = "gitleaks"
entry = "./lib/secrets.sh"
language = "script"
pass_filenames = false
always_run = true
stages = ["pre-commit"]

[[repos.hooks]]
id = "test"
name = "test"
entry = "./lib/test.sh"
language = "script"
pass_filenames = false
always_run = true
stages = ["pre-push"]
EOF
}

write_hook_wrapper() {
  local script_path="$1"
  local wrapper_path="$HOOK_WRAPPER_DIR/$script_path"
  local runtime_pragma_dir

  runtime_pragma_dir="$(render_runtime_pragma_dir)"

  mkdir -p "$HOOK_WRAPPER_DIR"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    if $DOCKER_TOOLS; then
      printf 'export PRAGMA_DOCKER_BIN_DIR=%s\n' "$(shell_escape_arg "$DOCKER_WRAPPER_BIN_DIR")"
    fi
    printf 'exec %s/lib/%s "$@"\n' "$runtime_pragma_dir" "$script_path"
  } >"$wrapper_path"

  chmod +x "$wrapper_path"
}

generate_target_wrappers() {
  $SELF_INSTALL && return 0

  write_hook_wrapper format.sh
  write_hook_wrapper lint.sh
  write_hook_wrapper secrets.sh
  write_hook_wrapper test.sh
}

remove_stale_lefthook_shim() {
  local hook_name="$1"
  local hook_path

  hook_path="$(git -C "$TARGET_REPO" rev-parse --git-path "hooks/$hook_name")"

  if [[ -f "$hook_path" ]] && grep -Fq 'lefthook' "$hook_path"; then
    rm -f "$hook_path"
    log_info "Removed stale lefthook shim for $hook_name"
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

# ─── Step 1: Install prek if needed ───────────────────────────────────────────

if ! has_tool prek; then
  log_warn "prek is not installed"

  if $AGENT_MODE; then
    log_info "Installing prek..."
    if (cd "$TARGET_REPO" && PRAGMA_INSTALL_ONLY_TOOLS="prek" "$PRAGMA_DIR/tools/install-tools.sh" --agent); then
      :
    else
      log_error "Cannot install prek automatically"
      log_info "Install manually: npm install -g @j178/prek"
      exit 1
    fi
  else
    log_info "Install prek via one of:"
    echo "  $PRAGMA_DIR/tools/install-tools.sh --agent"
    echo "  npm install -g @j178/prek"
    echo ""
    read -rp "Attempt auto-install via Pragma's pinned installer? [Y/n] " answer
    if [[ ! "$answer" =~ ^[Nn] ]]; then
      (cd "$TARGET_REPO" && PRAGMA_INSTALL_ONLY_TOOLS="prek" "$PRAGMA_DIR/tools/install-tools.sh" --agent) || {
        log_error "Failed to install prek"
        exit 1
      }
    else
      log_error "prek is required. Please install and re-run."
      exit 1
    fi
  fi

  pragma_prepend_path "$PRAGMA_DIR/bin"

  # Ensure GOPATH/bin is in PATH so we can find the just-installed binary
  GOBIN_DIR="${GOBIN:-$(go env GOBIN 2>/dev/null)}"
  GOBIN_DIR="${GOBIN_DIR:-$(go env GOPATH 2>/dev/null)/bin}"
  GOBIN_DIR="${GOBIN_DIR:-$HOME/go/bin}"
  if [[ -d "$GOBIN_DIR" ]] && [[ ":$PATH:" != *":$GOBIN_DIR:"* ]]; then
    export PATH="$GOBIN_DIR:$PATH"
  fi

  hash -r 2>/dev/null || true

  if has_tool prek; then
    log_success "prek installed"
  else
    log_error "prek installation failed"
    exit 1
  fi
else
  log_success "prek is available ($(prek --version 2>/dev/null || echo 'unknown version'))"
fi

# ─── Step 2: Generate prek.toml in target repo ───────────────────────────────

PREK_CONFIG="$TARGET_REPO/prek.toml"

write_self_install_template() {
  local output_path="$1"

  write_canonical_template "$output_path"
}

generate_config() {
  {
    printf '# Generated by pragma — https://github.com/zakstak/pragma\n'
    printf '# To regenerate: %s\n\n' "$(render_regenerate_command)"

    printf '[[repos]]\n'
    printf 'repo = "local"\n\n'

    printf '[[repos.hooks]]\n'
    printf 'id = "format"\n'
    printf 'name = "format"\n'
    printf 'entry = "%s"\n' "$(toml_escape_string "$(render_entry_path format.sh)")"
    printf 'language = "script"\n'
    write_env_line
    printf "files = '\\\\.(go|rs|ts|tsx|js|jsx|html|htm|templ|yml|yaml|sh|md|toml|json|py)$'\n"
    printf 'stages = ["pre-commit"]\n\n'

    printf '[[repos.hooks]]\n'
    printf 'id = "lint"\n'
    printf 'name = "lint"\n'
    printf 'entry = "%s"\n' "$(toml_escape_string "$(render_entry_path lint.sh)")"
    printf 'language = "script"\n'
    write_env_line
    printf "files = '(\\\\.(go|rs|ts|tsx|js|jsx|yml|yaml|sh|toml|py)$)|((^|/)([Dd]ockerfile(\\\\.[^/]+)?|[^/]+\\\\.[Dd]ockerfile)$)'\n"
    printf 'stages = ["pre-commit"]\n\n'

    printf '[[repos.hooks]]\n'
    printf 'id = "gitleaks"\n'
    printf 'name = "gitleaks"\n'
    printf 'entry = "%s"\n' "$(toml_escape_string "$(render_entry_path secrets.sh)")"
    printf 'language = "script"\n'
    write_env_line
    printf 'pass_filenames = false\n'
    printf 'always_run = true\n'
    printf 'stages = ["pre-commit"]\n\n'

    printf '[[repos.hooks]]\n'
    printf 'id = "test"\n'
    printf 'name = "test"\n'
    printf 'entry = "%s"\n' "$(toml_escape_string "$(render_entry_path test.sh)")"
    printf 'language = "script"\n'
    write_env_line
    printf 'pass_filenames = false\n'
    printf 'always_run = true\n'
    printf 'stages = ["pre-push"]\n'
  } >"$PREK_CONFIG"
}

restore_self_install_config() {
  local temp_template

  temp_template="$(mktemp)"
  write_self_install_template "$temp_template"
  cp "$temp_template" "$PREK_CONFIG"
  rm -f "$temp_template"
}

if ! $SELF_INSTALL; then
  generate_target_wrappers
fi

if $SELF_INSTALL; then
  if [[ -f "$PREK_CONFIG" ]]; then
    if $DOCKER_TOOLS; then
      log_info "Self-install detected; updating repo-local prek.toml for Docker-backed tools"
      generate_config
      log_success "Updated repo-local prek.toml at $PREK_CONFIG"
    elif grep -Fq 'PRAGMA_DOCKER_BIN_DIR' "$PREK_CONFIG"; then
      log_info "Self-install detected; restoring repo-local prek.toml from tracked template"
      restore_self_install_config
      log_success "Restored repo-local prek.toml at $PREK_CONFIG"
    else
      log_info "Self-install detected; keeping repo-local prek.toml"
      log_success "Using repo-local prek.toml at $PREK_CONFIG"
    fi
  else
    log_error "Self-install requires repo-local prek.toml at $PREK_CONFIG"
    exit 1
  fi
elif [[ -f "$PREK_CONFIG" ]]; then
  if $AGENT_MODE; then
    log_info "Overwriting existing prek.toml"
    generate_config
  else
    log_warn "prek.toml already exists in target repo"
    read -rp "Overwrite? [y/N] " answer
    if [[ "$answer" =~ ^[Yy] ]]; then
      generate_config
    else
      log_info "Keeping existing prek.toml"
    fi
  fi
else
  generate_config
fi

if ! $SELF_INSTALL; then
  log_success "prek.toml written to $PREK_CONFIG"
fi

# ─── Step 3: Copy gitleaks config if target doesn't have one ──────────────────

if [[ ! -f "$TARGET_REPO/.gitleaks.toml" ]]; then
  cp "$PRAGMA_DIR/.gitleaks.toml" "$TARGET_REPO/.gitleaks.toml"
  log_success "Copied default .gitleaks.toml"
else
  log_skip "Target repo already has .gitleaks.toml"
fi

# ─── Step 4: Run prek install ─────────────────────────────────────────────────

remove_stale_lefthook_shim pre-commit
remove_stale_lefthook_shim pre-push
remove_stale_lefthook_shim prepare-commit-msg

log_info "Installing git hooks via prek..."
(cd "$TARGET_REPO" && prek install --overwrite --hook-type pre-commit --hook-type pre-push) || {
  log_error "prek install failed"
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
echo "  cd $TARGET_REPO && prek uninstall"
