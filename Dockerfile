FROM golang:1.25-bookworm@sha256:29e59af995c51a5bf63d072eca973b918e0e7af4db0e4667aa73f1b8da1a6d8c

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive
ARG RUSTUP_VERSION=1.28.2
ARG PRETTIER_VERSION=3.8.3
ARG ESLINT_VERSION=9.39.4
ARG PYTEST_VERSION=9.0.3
ARG RUFF_VERSION=0.15.11
ARG YAMLLINT_VERSION=1.38.0
ARG GOIMPORTS_VERSION=v0.44.0
ARG TEMPL_VERSION=v0.3.1001
ARG GOLANGCI_LINT_VERSION=v2.11.4
ARG HADOLINT_VERSION=v2.14.0
ARG GITLEAKS_VERSION=v8.30.1
ARG SHELLCHECK_VERSION=v0.11.0
ARG SHFMT_VERSION=v3.13.1
ARG TAPLO_VERSION=0.10.0

ENV CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    PATH=/usr/local/cargo/bin:/usr/local/bin:$PATH

# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    build-essential \
    ca-certificates \
    curl \
    git \
    gzip \
    nodejs \
    npm \
    python-is-python3 \
    python3 \
    python3-pip \
    tar \
    unzip \
    xz-utils \
 && rm -rf /var/lib/apt/lists/*

COPY .npm-packages/package.json .npm-packages/package-lock.json /opt/pragma-npm-tools/
RUN npm ci --ignore-scripts --no-fund --no-audit --prefix /opt/pragma-npm-tools \
 && ln -sf /opt/pragma-npm-tools/node_modules/.bin/prek /usr/local/bin/prek \
 && ln -sf /opt/pragma-npm-tools/node_modules/.bin/prettier /usr/local/bin/prettier \
 && ln -sf /opt/pragma-npm-tools/node_modules/.bin/eslint /usr/local/bin/eslint

COPY tools/requirements/docker-python.txt /tmp/pragma-python-requirements.txt
RUN python3 -m pip install --break-system-packages --no-cache-dir --require-hashes -r /tmp/pragma-python-requirements.txt \
 && rm -f /tmp/pragma-python-requirements.txt

COPY tools/internal/goimports /tmp/goimports
RUN go build -C /tmp/goimports -mod=readonly -o /usr/local/bin/goimports golang.org/x/tools/cmd/goimports \
 && rm -rf /tmp/goimports

COPY tools/internal/templ /tmp/templ
RUN go build -C /tmp/templ -mod=readonly -o /usr/local/bin/templ github.com/a-h/templ/cmd/templ \
 && rm -rf /tmp/templ

# hadolint ignore=DL3003
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64) rustup_target="x86_64-unknown-linux-gnu" ;; \
      aarch64|arm64) rustup_target="aarch64-unknown-linux-gnu" ;; \
      *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    tmpdir="$(mktemp -d)"; \
    curl -fsSL -o "$tmpdir/rustup-init" "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rustup_target}/rustup-init"; \
    curl -fsSL -o "$tmpdir/rustup-init.sha256" "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rustup_target}/rustup-init.sha256"; \
    (cd "$tmpdir" && sha256sum -c rustup-init.sha256); \
    chmod +x "$tmpdir/rustup-init"; \
    "$tmpdir/rustup-init" -y --profile minimal --component clippy,rustfmt; \
    rm -rf "$tmpdir"

# hadolint ignore=DL3003
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64) hadolint_arch="x86_64"; gitleaks_arch="x64"; golangci_arch="amd64"; shellcheck_arch="x86_64"; shfmt_arch="amd64"; taplo_arch="x86_64" ;; \
      aarch64|arm64) hadolint_arch="arm64"; gitleaks_arch="arm64"; golangci_arch="arm64"; shellcheck_arch="aarch64"; shfmt_arch="arm64"; taplo_arch="aarch64" ;; \
      *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    tmpdir="$(mktemp -d)"; \
    extract_checksum_entry() { \
      local asset_name="$1"; \
      local checksums_file="$2"; \
      local output_file="$3"; \
      awk -v asset="$asset_name" '$2 == asset || $2 == "*" asset { print; exit }' "$checksums_file" >"$output_file"; \
      [ -s "$output_file" ]; \
    }; \
    golangci_asset="golangci-lint-${GOLANGCI_LINT_VERSION#v}-linux-${golangci_arch}.tar.gz"; \
    curl -fsSL -o "$tmpdir/$golangci_asset" "https://github.com/golangci/golangci-lint/releases/download/${GOLANGCI_LINT_VERSION}/${golangci_asset}"; \
    curl -fsSL -o "$tmpdir/golangci-checksums.txt" "https://github.com/golangci/golangci-lint/releases/download/${GOLANGCI_LINT_VERSION}/golangci-lint-${GOLANGCI_LINT_VERSION#v}-checksums.txt"; \
    extract_checksum_entry "$tmpdir/$golangci_asset" "$tmpdir/golangci-checksums.txt" "$tmpdir/golangci.sha256"; \
    (cd "$tmpdir" && sha256sum -c golangci.sha256); \
    mkdir "$tmpdir/golangci"; \
    tar -xzf "$tmpdir/$golangci_asset" -C "$tmpdir/golangci"; \
    install -m 0755 "$(find "$tmpdir/golangci" -name golangci-lint -type f | head -n 1)" /usr/local/bin/golangci-lint; \
    hadolint_asset="hadolint-linux-${hadolint_arch}"; \
    curl -fsSL -o "$tmpdir/$hadolint_asset" "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/${hadolint_asset}"; \
    curl -fsSL -o "$tmpdir/hadolint.sha256" "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/${hadolint_asset}.sha256"; \
    (cd "$tmpdir" && sha256sum -c hadolint.sha256); \
    install -m 0755 "$tmpdir/$hadolint_asset" /usr/local/bin/hadolint; \
    gitleaks_asset="gitleaks_${GITLEAKS_VERSION#v}_linux_${gitleaks_arch}.tar.gz"; \
    curl -fsSL -o "$tmpdir/$gitleaks_asset" "https://github.com/gitleaks/gitleaks/releases/download/${GITLEAKS_VERSION}/${gitleaks_asset}"; \
    curl -fsSL -o "$tmpdir/gitleaks-checksums.txt" "https://github.com/gitleaks/gitleaks/releases/download/${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION#v}_checksums.txt"; \
    extract_checksum_entry "$tmpdir/$gitleaks_asset" "$tmpdir/gitleaks-checksums.txt" "$tmpdir/gitleaks.sha256"; \
    (cd "$tmpdir" && sha256sum -c gitleaks.sha256); \
    mkdir "$tmpdir/gitleaks"; \
    tar -xzf "$tmpdir/$gitleaks_asset" -C "$tmpdir/gitleaks"; \
    install -m 0755 "$(find "$tmpdir/gitleaks" -name gitleaks -type f | head -n 1)" /usr/local/bin/gitleaks; \
    shellcheck_asset="shellcheck-${SHELLCHECK_VERSION}.linux.${shellcheck_arch}.tar.xz"; \
    curl -fsSL -o "$tmpdir/$shellcheck_asset" "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/${shellcheck_asset}"; \
    case "$shellcheck_arch" in \
      x86_64) echo "8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198  $tmpdir/$shellcheck_asset" | sha256sum -c - ;; \
      aarch64) echo "12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588  $tmpdir/$shellcheck_asset" | sha256sum -c - ;; \
    esac; \
    mkdir "$tmpdir/shellcheck"; \
    tar -xJf "$tmpdir/$shellcheck_asset" -C "$tmpdir/shellcheck"; \
    install -m 0755 "$(find "$tmpdir/shellcheck" -name shellcheck -type f | head -n 1)" /usr/local/bin/shellcheck; \
    shfmt_asset="shfmt_${SHFMT_VERSION}_linux_${shfmt_arch}"; \
    curl -fsSL -o "$tmpdir/$shfmt_asset" "https://github.com/mvdan/sh/releases/download/${SHFMT_VERSION}/${shfmt_asset}"; \
    case "$shfmt_arch" in \
      amd64) echo "fb096c5d1ac6beabbdbaa2874d025badb03ee07929f0c9ff67563ce8c75398b1  $tmpdir/$shfmt_asset" | sha256sum -c - ;; \
      arm64) echo "32d92acaa5cd8abb29fc49dac123dc412442d5713967819d8af2c29f1b3857c7  $tmpdir/$shfmt_asset" | sha256sum -c - ;; \
    esac; \
    install -m 0755 "$tmpdir/$shfmt_asset" /usr/local/bin/shfmt; \
    taplo_asset="taplo-linux-${taplo_arch}.gz"; \
    curl -fsSL -o "$tmpdir/$taplo_asset" "https://github.com/tamasfe/taplo/releases/download/${TAPLO_VERSION}/${taplo_asset}"; \
    case "$taplo_arch" in \
      x86_64) echo "8fe196b894ccf9072f98d4e1013a180306e17d244830b03986ee5e8eabeb6156  $tmpdir/$taplo_asset" | sha256sum -c - ;; \
      aarch64) echo "033681d01eec8376c3fd38fa3703c79316f5e14bb013d859943b60a07bccdcc3  $tmpdir/$taplo_asset" | sha256sum -c - ;; \
    esac; \
    gunzip -c "$tmpdir/$taplo_asset" > /usr/local/bin/taplo; \
    chmod +x /usr/local/bin/taplo; \
    rm -rf "$tmpdir"

RUN mkdir -p /workspace && chmod 0777 /workspace

WORKDIR /workspace

CMD ["bash"]
