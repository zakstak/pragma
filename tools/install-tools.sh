#!/usr/bin/env bash
# install-tools.sh — Install missing tools for pragma
#
# Downloads pre-built binaries from GitHub Releases / official installers.
# No Go, Rust, or cargo required.
#
# Usage:
#   install-tools.sh [--agent] [--docker]
#     --agent  Non-interactive auto-install
#     --docker Install Docker-backed wrappers instead of host tools
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(dirname "$SCRIPT_DIR")"
source "$PRAGMA_DIR/lib/common.sh"
source "$PRAGMA_DIR/lib/detect.sh"

UNSUPPORTED_HOST_ERROR="Unsupported host: Pragma bootstrap/install-tools are supported on macOS and Linux only."

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$OS" in
  linux)
    OS_GITLEAKS="Linux"
    ;;
  darwin)
    OS_GITLEAKS="Darwin"
    ;;
  *)
    log_error "$UNSUPPORTED_HOST_ERROR"
    exit 1
    ;;
esac

AGENT_MODE=false
DOCKER_MODE=false

for arg in "$@"; do
  case "$arg" in
    --agent) AGENT_MODE=true ;;
    --docker) DOCKER_MODE=true ;;
    *)
      log_error "Unknown option: $arg"
      exit 1
      ;;
  esac
done

BIN_DIR="$PRAGMA_DIR/bin"
mkdir -p "$BIN_DIR"
if [[ "${PRAGMA_SKIP_INTERNAL_BIN_PATH:-0}" != "1" ]]; then
  pragma_prepend_path "$BIN_DIR"
fi
DOCKER_BIN_DIR="$BIN_DIR/docker"

DOCKER_WRAPPED_TOOLS=(
  prek
  gitleaks
  go
  goimports
  templ
  golangci-lint
  cargo
  rustfmt
  npm
  prettier
  eslint
  python
  pytest
  yamllint
  hadolint
  shellcheck
  shfmt
  taplo
  ruff
)

GOLANGCI_LINT_VERSION="v2.11.4"
HADOLINT_VERSION="v2.14.0"
GITLEAKS_VERSION="v8.30.1"
SHELLCHECK_VERSION="v0.11.0"
SHFMT_VERSION="v3.13.1"
TAPLO_VERSION="0.10.0"

ARCH="$(uname -m)"

case "$ARCH" in
  x86_64)
    ARCH_GO="amd64"
    ARCH_ALT="x86_64"
    ARCH_HADOLINT="x86_64"
    ARCH_GITLEAKS="x64"
    ARCH_GOLANGCI="amd64"
    ;;
  aarch64 | arm64)
    ARCH_GO="arm64"
    ARCH_ALT="aarch64"
    ARCH_HADOLINT="arm64"
    ARCH_GITLEAKS="arm64"
    ARCH_GOLANGCI="arm64"
    ;;
  *)
    log_error "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

# ─── Download helpers ─────────────────────────────────────────────────────────

# Download a binary from a URL and place in BIN_DIR
require_commands() {
  local missing=()
  local tool

  for tool in "$@"; do
    if ! has_tool "$tool"; then
      missing+=("$tool")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tool(s): ${missing[*]}"
    return 1
  fi

  return 0
}

verify_checksum_file() {
  local checksum_file="$1"
  local checksum_dir
  local checksum_name

  checksum_dir="$(dirname "$checksum_file")"
  checksum_name="$(basename "$checksum_file")"

  if has_tool sha256sum; then
    (cd "$checksum_dir" && sha256sum -c "$checksum_name" >/dev/null)
  elif has_tool shasum; then
    (cd "$checksum_dir" && shasum -a 256 -c "$checksum_name" >/dev/null)
  else
    log_error "Missing checksum tool: sha256sum or shasum"
    return 1
  fi
}

file_sha256() {
  local file_path="$1"

  if has_tool sha256sum; then
    sha256sum "$file_path" | awk '{print $1}'
  elif has_tool shasum; then
    shasum -a 256 "$file_path" | awk '{print $1}'
  else
    log_error "Missing checksum tool: sha256sum or shasum"
    return 1
  fi
}

verify_expected_sha256() {
  local file_path="$1"
  local expected_sha="$2"
  local actual_sha

  actual_sha="$(file_sha256 "$file_path")" || return 1

  if [[ "$actual_sha" != "$expected_sha" ]]; then
    log_error "Checksum mismatch for $(basename "$file_path")"
    log_error "Expected: $expected_sha"
    log_error "Actual:   $actual_sha"
    return 1
  fi

  return 0
}

extract_checksum_entry() {
  local checksums_file="$1"
  local asset_name="$2"
  local output_file="$3"

  awk -v asset="$asset_name" '$2 == asset || $2 == "*" asset { print; exit }' "$checksums_file" >"$output_file"
  [[ -s "$output_file" ]]
}

ensure_npm_tooling_installed() {
  require_commands npm || return 1

  if [[ ! -f "$PRAGMA_DIR/.npm-packages/package-lock.json" ]]; then
    log_error "Missing npm lockfile at $PRAGMA_DIR/.npm-packages/package-lock.json"
    return 1
  fi

  npm ci --ignore-scripts --no-fund --no-audit --prefix "$PRAGMA_DIR/.npm-packages"
}

ensure_python_tooling_installed() {
  local requirements_file="$1"
  local venv_dir="$PRAGMA_DIR/.venv"

  require_commands python3 || return 1

  if [[ ! -f "$requirements_file" ]]; then
    log_error "Missing Python requirements file: $requirements_file"
    return 1
  fi

  python3 -m venv "$venv_dir"
  "$venv_dir/bin/pip" install --quiet --require-hashes -r "$requirements_file"
}

download_binary() {
  local name="$1" url="$2"
  require_commands curl || return 1
  log_info "Downloading $name..."
  curl -fsSL "$url" -o "$BIN_DIR/$name"
  chmod +x "$BIN_DIR/$name"
}

download_binary_with_checksum() {
  local name="$1"
  local url="$2"
  local checksum_url="$3"
  local asset_name="$4"
  local tmp

  require_commands curl dirname basename awk || return 1

  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/$asset_name"
  curl -fsSL "$checksum_url" -o "$tmp/checksums.txt"

  if ! extract_checksum_entry "$tmp/checksums.txt" "$asset_name" "$tmp/checksum.txt"; then
    log_error "Could not find checksum for $asset_name"
    rm -rf "$tmp"
    return 1
  fi

  verify_checksum_file "$tmp/checksum.txt" || {
    rm -rf "$tmp"
    return 1
  }

  mv "$tmp/$asset_name" "$BIN_DIR/$name"
  chmod +x "$BIN_DIR/$name"
  rm -rf "$tmp"
}

download_binary_with_expected_sha256() {
  local name="$1"
  local url="$2"
  local asset_name="$3"
  local expected_sha="$4"
  local tmp

  require_commands curl basename awk || return 1

  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/$asset_name"

  verify_expected_sha256 "$tmp/$asset_name" "$expected_sha" || {
    rm -rf "$tmp"
    return 1
  }

  mv "$tmp/$asset_name" "$BIN_DIR/$name"
  chmod +x "$BIN_DIR/$name"
  rm -rf "$tmp"
}

download_gzip_binary_with_checksum() {
  local name="$1"
  local url="$2"
  local checksum_url="$3"
  local asset_name="$4"
  local tmp

  require_commands curl gunzip dirname basename awk || return 1

  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/$asset_name"
  curl -fsSL "$checksum_url" -o "$tmp/checksums.txt"

  if ! extract_checksum_entry "$tmp/checksums.txt" "$asset_name" "$tmp/checksum.txt"; then
    log_error "Could not find checksum for $asset_name"
    rm -rf "$tmp"
    return 1
  fi

  verify_checksum_file "$tmp/checksum.txt" || {
    rm -rf "$tmp"
    return 1
  }

  gunzip -c "$tmp/$asset_name" >"$BIN_DIR/$name"
  chmod +x "$BIN_DIR/$name"
  rm -rf "$tmp"
}

download_gzip_binary_with_expected_sha256() {
  local name="$1"
  local url="$2"
  local asset_name="$3"
  local expected_sha="$4"
  local tmp

  require_commands curl gunzip basename awk || return 1

  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/$asset_name"

  verify_expected_sha256 "$tmp/$asset_name" "$expected_sha" || {
    rm -rf "$tmp"
    return 1
  }

  gunzip -c "$tmp/$asset_name" >"$BIN_DIR/$name"
  chmod +x "$BIN_DIR/$name"
  rm -rf "$tmp"
}

# Download + extract from a tar.gz (finds the binary inside)
download_tarball() {
  local name="$1" url="$2"
  require_commands curl tar || return 1
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

download_tarball_with_checksum() {
  local name="$1"
  local url="$2"
  local checksum_url="$3"
  local asset_name="$4"
  local tmp

  require_commands curl tar dirname basename awk || return 1

  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/$asset_name"
  curl -fsSL "$checksum_url" -o "$tmp/checksums.txt"

  if ! extract_checksum_entry "$tmp/checksums.txt" "$asset_name" "$tmp/checksum.txt"; then
    log_error "Could not find checksum for $asset_name"
    rm -rf "$tmp"
    return 1
  fi

  verify_checksum_file "$tmp/checksum.txt" || {
    rm -rf "$tmp"
    return 1
  }

  tar -xzf "$tmp/$asset_name" -C "$tmp"

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
  require_commands curl tar || return 1
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

download_tarxz_with_expected_sha256() {
  local name="$1"
  local url="$2"
  local asset_name="$3"
  local expected_sha="$4"
  local tmp

  require_commands curl tar basename awk || return 1
  log_info "Downloading $name..."

  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/$asset_name"

  verify_expected_sha256 "$tmp/$asset_name" "$expected_sha" || {
    rm -rf "$tmp"
    return 1
  }

  tar -xJf "$tmp/$asset_name" -C "$tmp"

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
  require_commands curl unzip || return 1
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

install_prek() {
  if has_tool npm; then
    log_info "Installing prek via npm lockfile..."
    ensure_npm_tooling_installed || return 1
    cat >"$BIN_DIR/prek" <<'WRAPPER'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(dirname "$SCRIPT_DIR")"
exec "$PRAGMA_DIR/.npm-packages/node_modules/.bin/prek" "$@"
WRAPPER
    chmod +x "$BIN_DIR/prek"
  else
    log_warn "prek requires npm — skipping"
    return 1
  fi
}

install_gitleaks() {
  local asset_name="gitleaks_${GITLEAKS_VERSION#v}_${OS_GITLEAKS}_${ARCH_GITLEAKS}.tar.gz"
  download_tarball_with_checksum \
    gitleaks \
    "https://github.com/gitleaks/gitleaks/releases/download/${GITLEAKS_VERSION}/${asset_name}" \
    "https://github.com/gitleaks/gitleaks/releases/download/${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION#v}_checksums.txt" \
    "$asset_name"
}

install_goimports() {
  if has_tool go; then
    log_info "Installing goimports from pinned module source..."
    go build -C "$PRAGMA_DIR/tools/internal/goimports" -mod=readonly -o "$BIN_DIR/goimports" golang.org/x/tools/cmd/goimports
  else
    log_warn "goimports requires Go — skipping"
    return 1
  fi
}

install_templ() {
  if has_tool go; then
    log_info "Installing templ via pinned module source..."
    go build -C "$PRAGMA_DIR/tools/internal/templ" -mod=readonly -o "$BIN_DIR/templ" github.com/a-h/templ/cmd/templ
  else
    log_warn "templ requires Go — skipping"
    return 1
  fi
}

install_golangci_lint() {
  local asset_name="golangci-lint-${GOLANGCI_LINT_VERSION#v}-${OS}-${ARCH_GOLANGCI}.tar.gz"
  download_tarball_with_checksum \
    golangci-lint \
    "https://github.com/golangci/golangci-lint/releases/download/${GOLANGCI_LINT_VERSION}/${asset_name}" \
    "https://github.com/golangci/golangci-lint/releases/download/${GOLANGCI_LINT_VERSION}/golangci-lint-${GOLANGCI_LINT_VERSION#v}-checksums.txt" \
    "$asset_name"
}

install_prettier() {
  if has_tool npm; then
    log_info "Installing prettier via npm lockfile..."
    ensure_npm_tooling_installed || return 1
    cat >"$BIN_DIR/prettier" <<'WRAPPER'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(dirname "$SCRIPT_DIR")"
exec node "$PRAGMA_DIR/.npm-packages/node_modules/.bin/prettier" "$@"
WRAPPER
    chmod +x "$BIN_DIR/prettier"
  else
    log_warn "prettier requires npm — skipping"
    return 1
  fi
}

install_eslint() {
  if has_tool npm; then
    log_info "Installing eslint via npm lockfile..."
    ensure_npm_tooling_installed || return 1
    cat >"$BIN_DIR/eslint" <<'WRAPPER'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(dirname "$SCRIPT_DIR")"
exec node "$PRAGMA_DIR/.npm-packages/node_modules/.bin/eslint" "$@"
WRAPPER
    chmod +x "$BIN_DIR/eslint"
  else
    log_warn "eslint requires npm — skipping"
    return 1
  fi
}

install_yamllint() {
  if has_tool python3; then
    log_info "Installing yamllint via pinned Python requirements..."
    ensure_python_tooling_installed "$PRAGMA_DIR/tools/requirements/host-python.txt" || return 1
    cat >"$BIN_DIR/yamllint" <<'WRAPPER'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(dirname "$SCRIPT_DIR")"
exec "$PRAGMA_DIR/.venv/bin/yamllint" "$@"
WRAPPER
    chmod +x "$BIN_DIR/yamllint"
  else
    log_warn "yamllint requires python3 — skipping"
    return 1
  fi
}

install_hadolint() {
  local hadolint_os

  case "$OS" in
    linux) hadolint_os="linux" ;;
    darwin) hadolint_os="macos" ;;
    *)
      log_warn "hadolint is not available for $OS — skipping"
      return 1
      ;;
  esac

  local asset_name="hadolint-${hadolint_os}-${ARCH_HADOLINT}"
  download_binary_with_checksum \
    hadolint \
    "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/${asset_name}" \
    "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/${asset_name}.sha256" \
    "$asset_name"
}

install_shellcheck() {
  local asset_name="shellcheck-${SHELLCHECK_VERSION}.${OS}.${ARCH_ALT}.tar.xz"
  local expected_sha

  case "$OS:$ARCH_ALT" in
    linux:x86_64) expected_sha="8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198" ;;
    linux:aarch64) expected_sha="12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588" ;;
    darwin:x86_64) expected_sha="3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6" ;;
    darwin:aarch64) expected_sha="56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79" ;;
    *)
      log_warn "shellcheck is not available for $OS/$ARCH_ALT — skipping"
      return 1
      ;;
  esac

  download_tarxz_with_expected_sha256 shellcheck \
    "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/${asset_name}" \
    "$asset_name" \
    "$expected_sha"
}

install_shfmt() {
  local asset_name="shfmt_${SHFMT_VERSION}_${OS}_${ARCH_GO}"
  local expected_sha

  case "$OS:$ARCH_GO" in
    linux:amd64) expected_sha="fb096c5d1ac6beabbdbaa2874d025badb03ee07929f0c9ff67563ce8c75398b1" ;;
    linux:arm64) expected_sha="32d92acaa5cd8abb29fc49dac123dc412442d5713967819d8af2c29f1b3857c7" ;;
    darwin:amd64) expected_sha="6feedafc72915794163114f512348e2437d080d0047ef8b8fa2ec63b575f12af" ;;
    darwin:arm64) expected_sha="9680526be4a66ea1ffe988ed08af58e1400fe1e4f4aef5bd88b20bb9b3da33f8" ;;
    *)
      log_warn "shfmt is not available for $OS/$ARCH_GO — skipping"
      return 1
      ;;
  esac

  download_binary_with_expected_sha256 shfmt \
    "https://github.com/mvdan/sh/releases/download/${SHFMT_VERSION}/${asset_name}" \
    "$asset_name" \
    "$expected_sha"
}

install_taplo() {
  local asset_name="taplo-${OS}-${ARCH_ALT}.gz"
  local expected_sha

  case "$OS:$ARCH_ALT" in
    linux:x86_64) expected_sha="8fe196b894ccf9072f98d4e1013a180306e17d244830b03986ee5e8eabeb6156" ;;
    linux:aarch64) expected_sha="033681d01eec8376c3fd38fa3703c79316f5e14bb013d859943b60a07bccdcc3" ;;
    darwin:x86_64) expected_sha="898122cde3a0b1cd1cbc2d52d3624f23338218c91b5ddb71518236a4c2c10ef2" ;;
    darwin:aarch64) expected_sha="713734314c3e71894b9e77513c5349835eefbd52908445a0d73b0c7dc469347d" ;;
    *)
      log_warn "taplo is not available for $OS/$ARCH_ALT — skipping"
      return 1
      ;;
  esac

  download_gzip_binary_with_expected_sha256 taplo \
    "https://github.com/tamasfe/taplo/releases/download/${TAPLO_VERSION}/${asset_name}" \
    "$asset_name" \
    "$expected_sha"
}

install_ruff() {
  if has_tool python3; then
    log_info "Installing ruff via pinned Python requirements..."
    ensure_python_tooling_installed "$PRAGMA_DIR/tools/requirements/host-python.txt" || return 1
    cat >"$BIN_DIR/ruff" <<'WRAPPER'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(dirname "$SCRIPT_DIR")"
exec "$PRAGMA_DIR/.venv/bin/ruff" "$@"
WRAPPER
    chmod +x "$BIN_DIR/ruff"
  else
    log_warn "ruff requires python3 — skipping"
    return 1
  fi
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

cargo_has_subcommand() {
  local subcommand="$1"

  if ! has_tool cargo; then
    return 1
  fi

  cargo "$subcommand" --version >/dev/null 2>&1
}

has_repo_tool() {
  local tool="$1"

  case "$tool" in
    golangci-lint)
      has_tool golangci-lint
      ;;
    clippy)
      cargo_has_subcommand clippy
      ;;
    *)
      has_tool "$tool"
      ;;
  esac
}

# ─── Language → required tools mapping ────────────────────────────────────────

tools_for_lang() {
  local lang="$1"
  case "$lang" in
    go) echo "goimports golangci-lint" ;;
    rust) echo "rustfmt clippy" ;;
    typescript) echo "prettier eslint" ;;
    templ) echo "templ prettier" ;;
    html) echo "prettier" ;;
    yaml) echo "prettier yamllint" ;;
    docker) echo "hadolint" ;;
    shell) echo "shellcheck shfmt" ;;
    markdown) echo "prettier" ;;
    toml) echo "taplo" ;;
    json) echo "prettier" ;;
    python) echo "ruff" ;;
    *) echo "" ;;
  esac
}

install_docker_tool_wrapper() {
  local tool="$1"

  mkdir -p "$DOCKER_BIN_DIR"

  cat >"$DOCKER_BIN_DIR/$tool" <<EOF
#!/usr/bin/env bash
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="\$(cd "\$SCRIPT_DIR/../.." && pwd)"
exec "\$PRAGMA_DIR/tools/docker-run.sh" "$tool" "\$@"
EOF

  chmod +x "$DOCKER_BIN_DIR/$tool"
}

install_docker_wrappers() {
  if ! has_tool docker; then
    log_error "docker is required for --docker mode"
    return 1
  fi

  log_header "Docker Tooling Setup"

  local tool
  for tool in "${DOCKER_WRAPPED_TOOLS[@]}"; do
    install_docker_tool_wrapper "$tool"
  done

  log_success "Docker-backed tools installed to $DOCKER_BIN_DIR"
  log_info "Set PRAGMA_DOCKER_IMAGE to override the default image tag (pragma-tools:local)"
  return 0
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  if $DOCKER_MODE; then
    install_docker_wrappers
    return $?
  fi

  log_header "Tool Installation Check"

  # Add bin dir to PATH for this session
  if [[ "${PRAGMA_SKIP_INTERNAL_BIN_PATH:-0}" != "1" ]]; then
    export PATH="$BIN_DIR:$PATH"
  fi

  local required_tools=()

  if [[ -n "${PRAGMA_INSTALL_ONLY_TOOLS:-}" ]]; then
    read -r -a required_tools <<<"$PRAGMA_INSTALL_ONLY_TOOLS"
  else
    # Always need these
    required_tools=("prek" "gitleaks")

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
    done <<<"$langs"
  fi

  # Check what's missing
  local missing=()
  for tool in "${required_tools[@]}"; do
    if has_repo_tool "$tool"; then
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

  if ! $AGENT_MODE; then
    echo ""
    read -rp "Install missing tools? [Y/n] " answer
    [[ "$answer" =~ ^[Nn] ]] && {
      log_warn "Skipping tool installation"
      return 1
    }
  fi

  local failed=()
  for tool in "${missing[@]}"; do
    local installer_name="install_${tool//-/_}"

    if declare -f "$installer_name" >/dev/null 2>&1; then
      if "$installer_name"; then
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
