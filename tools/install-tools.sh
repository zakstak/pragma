#!/usr/bin/env bash
# install-tools.sh — Install missing tools for pragma
#
# Downloads pre-built binaries from GitHub Releases / official installers.
# No Go, Rust, or cargo required.
#
# Usage:
#   install-tools.sh [--agent]    # --agent for non-interactive auto-install
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(dirname "$SCRIPT_DIR")"
source "$PRAGMA_DIR/lib/common.sh"
source "$PRAGMA_DIR/lib/detect.sh"

AGENT_MODE="${1:-}"
[[ "$AGENT_MODE" == "--agent" ]] && AGENT_MODE="true" || AGENT_MODE="false"

BIN_DIR="$PRAGMA_DIR/bin"
mkdir -p "$BIN_DIR"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  ARCH_GO="amd64"; ARCH_ALT="x86_64" ;;
  aarch64|arm64) ARCH_GO="arm64"; ARCH_ALT="aarch64" ;;
  *) log_error "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# ─── Download helpers ─────────────────────────────────────────────────────────

# Download a binary from a URL and place in BIN_DIR
download_binary() {
  local name="$1" url="$2"
  log_info "Downloading $name..."
  curl -fsSL "$url" -o "$BIN_DIR/$name"
  chmod +x "$BIN_DIR/$name"
}

# Download + extract from a tar.gz (finds the binary inside)
download_tarball() {
  local name="$1" url="$2" strip="${3:-0}"
  log_info "Downloading $name..."
  local tmp
  tmp=$(mktemp -d)
  curl -fsSL "$url" | tar -xz -C "$tmp"
  # Find the binary
  local found
  found=$(find "$tmp" -name "$name" -type f | head -1)
  if [[ -n "$found" ]]; then
    mv "$found" "$BIN_DIR/$name"
    chmod +x "$BIN_DIR/$name"
  else
    log_error "Could not find $name in archive"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
}

# Download + extract from a .tar.xz
download_tarxz() {
  local name="$1" url="$2"
  log_info "Downloading $name..."
  local tmp
  tmp=$(mktemp -d)
  curl -fsSL "$url" | tar -xJ -C "$tmp"
  local found
  found=$(find "$tmp" -name "$name" -type f | head -1)
  if [[ -n "$found" ]]; then
    mv "$found" "$BIN_DIR/$name"
    chmod +x "$BIN_DIR/$name"
  else
    log_error "Could not find $name in archive"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
}

# Download + extract from a .zip
download_zip() {
  local name="$1" url="$2"
  log_info "Downloading $name..."
  local tmp
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/archive.zip"
  unzip -qo "$tmp/archive.zip" -d "$tmp"
  local found
  found=$(find "$tmp" -name "$name" -type f | head -1)
  if [[ -n "$found" ]]; then
    mv "$found" "$BIN_DIR/$name"
    chmod +x "$BIN_DIR/$name"
  else
    log_error "Could not find $name in archive"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
}

# ─── Tool installers ─────────────────────────────────────────────────────────
# Each function downloads a pre-built binary. No compilers needed.

install_lefthook() {
  local v
  v=$(curl -fsSL "https://api.github.com/repos/evilmartians/lefthook/releases/latest" | grep '"tag_name"' | cut -d '"' -f4)
  download_tarball lefthook \
    "https://github.com/evilmartians/lefthook/releases/download/${v}/lefthook_${v#v}_${OS}_${ARCH_GO}.tar.gz"
}

install_gitleaks() {
  local v
  v=$(curl -fsSL "https://api.github.com/repos/gitleaks/gitleaks/releases/latest" | grep '"tag_name"' | cut -d '"' -f4)
  local os_cap="${OS^}"  # Linux, Darwin
  download_tarball gitleaks \
    "https://github.com/gitleaks/gitleaks/releases/download/${v}/gitleaks_${v#v}_${os_cap}_${ARCH_ALT}.tar.gz"
}

install_goimports() {
  if has_tool go; then
    log_info "Installing goimports via go install..."
    GOBIN="$BIN_DIR" go install golang.org/x/tools/cmd/goimports@latest
  else
    log_warn "goimports requires Go — skipping"
    return 1
  fi
}

install_golangci-lint() {
  curl -fsSL https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh \
    | sh -s -- -b "$BIN_DIR" latest
}

install_prettier() {
  if has_tool npm; then
    log_info "Installing prettier via npm..."
    npm install --no-fund --no-audit --prefix "$PRAGMA_DIR/.npm-packages" prettier
    # Create a wrapper script in BIN_DIR
    cat > "$BIN_DIR/prettier" <<'WRAPPER'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(dirname "$SCRIPT_DIR")"
exec node "$PRAGMA_DIR/.npm-packages/node_modules/.bin/prettier" "$@"
WRAPPER
    chmod +x "$BIN_DIR/prettier"
  elif has_tool bun; then
    log_info "Installing prettier via bun..."
    bun install -g prettier
  else
    log_warn "prettier requires npm or bun — skipping"
    return 1
  fi
}

install_eslint() {
  if has_tool npm; then
    log_info "Installing eslint via npm..."
    npm install --no-fund --no-audit --prefix "$PRAGMA_DIR/.npm-packages" eslint
    cat > "$BIN_DIR/eslint" <<'WRAPPER'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(dirname "$SCRIPT_DIR")"
exec node "$PRAGMA_DIR/.npm-packages/node_modules/.bin/eslint" "$@"
WRAPPER
    chmod +x "$BIN_DIR/eslint"
  elif has_tool bun; then
    log_info "Installing eslint via bun..."
    bun install -g eslint
  else
    log_warn "eslint requires npm or bun — skipping"
    return 1
  fi
}

install_yamllint() {
  if has_tool pip; then
    log_info "Installing yamllint via pip..."
    pip install --break-system-packages --quiet yamllint 2>/dev/null || pip install --quiet yamllint
  elif has_tool pip3; then
    log_info "Installing yamllint via pip3..."
    pip3 install --break-system-packages --quiet yamllint 2>/dev/null || pip3 install --quiet yamllint
  elif has_tool pipx; then
    log_info "Installing yamllint via pipx..."
    pipx install yamllint
  elif has_tool uv; then
    log_info "Installing yamllint via uv..."
    uv tool install yamllint
  elif has_tool python3; then
    log_info "Installing yamllint via python3 -m pip..."
    python3 -m pip install --break-system-packages --quiet yamllint 2>/dev/null \
      || python3 -m pip install --user --quiet yamllint
  else
    log_warn "yamllint requires pip, pipx, uv, or python3 — skipping"
    return 1
  fi
}

install_hadolint() {
  download_binary hadolint \
    "https://github.com/hadolint/hadolint/releases/latest/download/hadolint-Linux-${ARCH_ALT}"
}

install_shellcheck() {
  local v
  v=$(curl -fsSL "https://api.github.com/repos/koalaman/shellcheck/releases/latest" | grep '"tag_name"' | cut -d '"' -f4)
  download_tarxz shellcheck \
    "https://github.com/koalaman/shellcheck/releases/download/${v}/shellcheck-${v}.${OS}.${ARCH_ALT}.tar.xz"
}

install_shfmt() {
  local v
  v=$(curl -fsSL "https://api.github.com/repos/mvdan/sh/releases/latest" | grep '"tag_name"' | cut -d '"' -f4)
  download_binary shfmt \
    "https://github.com/mvdan/sh/releases/download/${v}/shfmt_${v}_${OS}_${ARCH_GO}"
}

install_taplo() {
  local v
  v=$(curl -fsSL "https://api.github.com/repos/tamasfe/taplo/releases/latest" | grep '"tag_name"' | cut -d '"' -f4)
  local gz="taplo-full-${OS}-${ARCH_ALT}.gz"
  log_info "Downloading taplo..."
  curl -fsSL "https://github.com/tamasfe/taplo/releases/download/${v}/${gz}" \
    | gunzip > "$BIN_DIR/taplo"
  chmod +x "$BIN_DIR/taplo"
}

install_ruff() {
  curl -fsSL https://astral.sh/ruff/install.sh | RUFF_INSTALL_DIR="$BIN_DIR" sh
}

install_rustfmt() {
  # rustfmt/clippy come with rustup, not standalone binaries
  if has_tool rustup; then
    log_info "Adding rustfmt via rustup..."
    rustup component add rustfmt
  else
    log_warn "rustfmt requires rustup — skipping"
    return 1
  fi
}

install_clippy() {
  if has_tool rustup; then
    log_info "Adding clippy via rustup..."
    rustup component add clippy
  else
    log_warn "clippy requires rustup — skipping"
    return 1
  fi
}

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

  # Add bin dir to PATH for this session
  export PATH="$BIN_DIR:$PATH"

  # Always need these
  local required_tools=("lefthook" "gitleaks")

  # Detect languages and add their tools
  local langs
  langs=$(detect_from_repo)
  log_info "Detected languages: $(echo "$langs" | tr '\n' ' ')"

  while IFS= read -r lang; do
    [[ -z "$lang" ]] && continue
    for tool in $(tools_for_lang "$lang"); do
      local already=false
      for existing in "${required_tools[@]}"; do
        [[ "$existing" == "$tool" ]] && already=true && break
      done
      $already || required_tools+=("$tool")
    done
  done <<< "$langs"

  # Check what's missing
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
  log_info "${#missing[@]} tool(s) to install: ${BOLD}${missing[*]}${RESET}"
  log_info "Binaries will be placed in ${BOLD}$BIN_DIR${RESET}"

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
    if declare -f "install_${tool}" > /dev/null 2>&1; then
      if "install_${tool}"; then
        log_success "Installed $tool"
      else
        log_error "Failed to install $tool"
        failed+=("$tool")
      fi
    # Handle tools with hyphens (golangci-lint)
    elif declare -f "install_${tool//-/_}" > /dev/null 2>&1; then
      if "install_${tool}"; then
        log_success "Installed $tool"
      else
        log_error "Failed to install $tool"
        failed+=("$tool")
      fi
    else
      log_warn "No installer for $tool"
      failed+=("$tool")
    fi
  done

  if [[ ${#failed[@]} -gt 0 ]]; then
    echo ""
    log_error "Failed to install: ${failed[*]}"
    log_info "Please install these manually"
    return 1
  fi

  echo ""
  log_success "All tools installed to $BIN_DIR"
}

main
