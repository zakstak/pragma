#!/usr/bin/env bash
# install-tools.sh — Install missing tools for pragma
#
# Downloads pre-built binaries from GitHub Releases / official installers.
# Go is needed only to build goimports; Rust tooling uses rustup.
#
# Usage:
#   install-tools.sh [--agent] [--update] [--global]
#     --agent  Non-interactive auto-install
#     --update Reinstall fallback tools at committed versions; keep project selections
#     --global Install only the per-user core tools
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(dirname "$SCRIPT_DIR")"
source "$PRAGMA_DIR/lib/common.sh"
source "$PRAGMA_DIR/lib/detect.sh"
source "$PRAGMA_DIR/tools/versions.sh"

UNSUPPORTED_HOST_ERROR="Unsupported host: Pragma bootstrap/install-tools are supported on macOS and Linux only."

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$OS" in
  linux | darwin) ;;
  *)
    log_error "$UNSUPPORTED_HOST_ERROR"
    exit 1
    ;;
esac

AGENT_MODE=false
UPDATE_TOOLS=false
GLOBAL_MODE=false

for arg in "$@"; do
  case "$arg" in
    --agent) AGENT_MODE=true ;;
    --update) UPDATE_TOOLS=true ;;
    --global) GLOBAL_MODE=true ;;
    *)
      log_error "Unknown option: $arg"
      exit 1
      ;;
  esac
done

NATIVE_BIN_DIR="$PRAGMA_DIR/bin"
GLOBAL_BIN_DIR="$(pragma_global_bin_dir)"
BIN_DIR="$NATIVE_BIN_DIR"
ARCH="$(uname -m)"

case "$ARCH" in
  x86_64)
    ARCH_BINARY="amd64"
    ARCH_ALT="x86_64"
    ARCH_HADOLINT="x86_64"
    ARCH_KINGFISHER="x64"
    ;;
  aarch64 | arm64)
    ARCH_BINARY="arm64"
    ARCH_ALT="aarch64"
    ARCH_HADOLINT="arm64"
    ARCH_KINGFISHER="arm64"
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

NPM_TOOLING_INSTALLED=false
PYTHON_TOOLING_INSTALLED=false

ensure_npm_tooling_installed() {
  $NPM_TOOLING_INSTALLED && return 0
  require_commands npm || return 1

  if [[ ! -f "$PRAGMA_DIR/.npm-packages/package-lock.json" ]]; then
    log_error "Missing npm lockfile at $PRAGMA_DIR/.npm-packages/package-lock.json"
    return 1
  fi

  npm ci --ignore-scripts --no-fund --no-audit --prefix "$PRAGMA_DIR/.npm-packages" || return 1
  NPM_TOOLING_INSTALLED=true
}

node_supports_eslint() {
  has_tool node || return 1

  local version major minor patch
  version="$(node --version 2>/dev/null)" || return 1
  version="${version#v}"
  IFS='.' read -r major minor patch <<<"$version"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]] || return 1

  ((major >= 24)) ||
    ((major == 22 && minor >= 13)) ||
    ((major == 20 && minor >= 19))
}

ensure_python_tooling_installed() {
  $PYTHON_TOOLING_INSTALLED && return 0
  local requirements_file="$PRAGMA_DIR/tools/requirements/python.txt"
  local venv_dir="$PRAGMA_DIR/.venv"

  require_commands python3 || return 1

  if [[ ! -f "$requirements_file" ]]; then
    log_error "Missing Python requirements file: $requirements_file"
    return 1
  fi

  python3 -m venv "$venv_dir" || return 1
  "$venv_dir/bin/python" -m pip install --quiet --require-hashes -r "$requirements_file" || return 1
  PYTHON_TOOLING_INSTALLED=true
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

# Download + extract from a compressed tar archive
download_archive_with_expected_sha256() {
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

  tar -xf "$tmp/$asset_name" -C "$tmp"

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
# Use pinned binaries, lockfiles, or the pinned goimports module.

install_prek() {
  local target_os
  case "$OS" in
    linux) target_os="unknown-linux-gnu" ;;
    darwin) target_os="apple-darwin" ;;
  esac
  local asset_name="prek-${ARCH_ALT}-${target_os}.tar.gz"
  download_tarball_with_checksum prek \
    "https://github.com/j178/prek/releases/download/${PREK_VERSION}/${asset_name}" \
    "https://github.com/j178/prek/releases/download/${PREK_VERSION}/${asset_name}.sha256" \
    "$asset_name"
}

install_kingfisher() {
  local asset_name="kingfisher-${OS}-${ARCH_KINGFISHER}.tgz"
  local expected_sha

  case "$OS:$ARCH_KINGFISHER" in
    linux:x64) expected_sha="84e4a4c45814f05e80aa8eee768e5170d758736fa116ffaf03565da4d5a77447" ;;
    linux:arm64) expected_sha="da7508a90ff36337b41d12e63814cca3ac5586abdcf8c194898059c1ed5e1f81" ;;
    darwin:x64) expected_sha="e91b74c447b759fc72f993373b80ce7a6122a275f5793df61928b9c3c4eac1e3" ;;
    darwin:arm64) expected_sha="131de009409be38ae595550acfa8811ff3d43912715687758ff6a84157f1ef5e" ;;
  esac

  download_archive_with_expected_sha256 kingfisher \
    "https://github.com/mongodb/kingfisher/releases/download/${KINGFISHER_VERSION}/${asset_name}" \
    "$asset_name" "$expected_sha"
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

install_golangci_lint() {
  local asset_name="golangci-lint-${GOLANGCI_LINT_VERSION#v}-${OS}-${ARCH_BINARY}.tar.gz"
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
  if has_tool npm && node_supports_eslint; then
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
    log_warn "eslint requires npm and Node 20.19+, 22.13+, or 24+ — skipping"
    return 1
  fi
}

install_yamllint() {
  if has_tool python3; then
    log_info "Installing yamllint via pinned Python requirements..."
    ensure_python_tooling_installed || return 1
    cat >"$BIN_DIR/yamllint" <<'WRAPPER'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(dirname "$SCRIPT_DIR")"
exec "$PRAGMA_DIR/.venv/bin/python" -m yamllint "$@"
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
    "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/checksums.sha256" \
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

  download_archive_with_expected_sha256 shellcheck \
    "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/${asset_name}" \
    "$asset_name" \
    "$expected_sha"
}

install_shfmt() {
  local asset_name="shfmt_${SHFMT_VERSION}_${OS}_${ARCH_BINARY}"
  local expected_sha

  case "$OS:$ARCH_BINARY" in
    linux:amd64) expected_sha="76e77641faa025814b77f153b29796b8e6fa2fca03e0c76a691608b86c7ea7bf" ;;
    linux:arm64) expected_sha="5f2db09dae91fca848f7adbdd014632e921a383863a2ad7e0450ad3aba0c6489" ;;
    darwin:amd64) expected_sha="d33eee0da0f92835b3562e9767a05cee7e4eaeef47daa03bfd09da17b4b590a6" ;;
    darwin:arm64) expected_sha="b7c872db63553ccffc7253aba3ed7d4885a27d83f1ba567b1138c6315a5847e5" ;;
    *)
      log_warn "shfmt is not available for $OS/$ARCH_BINARY — skipping"
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

install_pytest() {
  ensure_python_tooling_installed || return 1
  cat >"$BIN_DIR/pytest" <<'WRAPPER'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(dirname "$SCRIPT_DIR")"
exec "$PRAGMA_DIR/.venv/bin/python" -m pytest "$@"
WRAPPER
  chmod +x "$BIN_DIR/pytest"
}

install_ruff() {
  if has_tool python3; then
    log_info "Installing ruff via pinned Python requirements..."
    ensure_python_tooling_installed || return 1
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
      golangci_is_v2
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
    html) echo "prettier" ;;
    yaml) echo "prettier yamllint" ;;
    docker) echo "hadolint" ;;
    shell) echo "shellcheck shfmt" ;;
    markdown) echo "prettier" ;;
    toml) echo "taplo" ;;
    json) echo "prettier" ;;
    python) echo "ruff pytest" ;;
    *) echo "" ;;
  esac
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  log_header "Tool Installation Check"

  local required_tools=()

  if [[ -n "${PRAGMA_INSTALL_ONLY_TOOLS:-}" ]]; then
    read -r -a required_tools <<<"$PRAGMA_INSTALL_ONLY_TOOLS"
  else
    required_tools=("prek" "kingfisher")
  fi

  if ! $GLOBAL_MODE && [[ -z "${PRAGMA_INSTALL_ONLY_TOOLS:-}" ]]; then

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
  local project_path project_status
  local project_errors=()
  for tool in "${required_tools[@]}"; do
    if $GLOBAL_MODE && ! pragma_is_core_tool "$tool"; then
      log_error "$tool is a language tool; --global installs only prek and Kingfisher"
      return 1
    fi
    if ! pragma_is_core_tool "$tool"; then
      case "$tool" in
        goimports | golangci-lint)
          if project_path="$(pragma_go_tool_package "$tool")"; then
            if ! command -v go >/dev/null 2>&1; then
              log_error "$tool uses a Go module tool; install the project's Go toolchain first"
              project_errors+=("$tool")
              continue
            fi
            log_success "$tool uses the project selection ($project_path)"
            continue
          fi
          ;;
        *)
          if project_path="$(pragma_project_tool_path "$tool")"; then
            log_success "$tool uses the project selection ($project_path)"
            continue
          else
            project_status=$?
            if [[ $project_status == 2 ]]; then
              log_error "$tool is declared by the project but unavailable; install the project's dependencies first"
              project_errors+=("$tool")
              continue
            fi
          fi
          ;;
      esac
    fi
    local available=false
    if pragma_is_core_tool "$tool"; then
      [[ ! -x "$GLOBAL_BIN_DIR/$tool" ]] || available=true
    elif has_repo_tool "$tool"; then
      available=true
    fi
    if ! $UPDATE_TOOLS && $available; then
      log_success "$tool is available"
    else
      missing+=("$tool")
      log_warn "$tool is ${BOLD}missing${RESET}"
    fi
  done

  if [[ ${#project_errors[@]} -gt 0 ]]; then
    return 1
  fi

  if [[ ${#missing[@]} -eq 0 ]]; then
    log_success "All tools are installed!"
    return 0
  fi

  echo ""
  log_info "${#missing[@]} tool(s) to install: ${BOLD}${missing[*]}${RESET}"
  log_info "Core tools: $GLOBAL_BIN_DIR; language fallbacks: $NATIVE_BIN_DIR"

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
    BIN_DIR="$NATIVE_BIN_DIR"
    if pragma_is_core_tool "$tool"; then
      BIN_DIR="$GLOBAL_BIN_DIR"
    fi
    mkdir -p "$BIN_DIR"
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
  log_success "All requested tools installed"
}

main
