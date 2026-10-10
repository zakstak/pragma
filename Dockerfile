FROM golang:1.27.2-bookworm@sha256:5cf287a799e6b94384bad13d16b14904c531f51ba65792237e122ce42b392f61 AS go-toolchain

FROM node:24-bookworm-slim@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    PATH=/opt/pragma/bin:/usr/local/go/bin:/usr/local/cargo/bin:$PATH

# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    build-essential \
    ca-certificates \
    curl \
    git \
    gzip \
    python-is-python3 \
    python3 \
    python3-venv \
    tar \
    xz-utils \
 && rm -rf /var/lib/apt/lists/*

COPY --from=go-toolchain /usr/local/go /usr/local/go

COPY .npm-packages/package.json .npm-packages/package-lock.json /opt/pragma/.npm-packages/
COPY lib/common.sh lib/detect.sh /opt/pragma/lib/
COPY tools/install-tools.sh tools/versions.sh /opt/pragma/tools/
COPY tools/internal/goimports/ /opt/pragma/tools/internal/goimports/
COPY tools/requirements/ /opt/pragma/tools/requirements/

# Use the same versions, lockfiles, checksums, and installer as native hosts.
RUN PRAGMA_INSTALL_ONLY_TOOLS="prek kingfisher goimports golangci-lint prettier eslint ruff yamllint pytest hadolint shellcheck shfmt taplo" \
    /opt/pragma/tools/install-tools.sh --agent \
 && chmod -R a+rX /opt/pragma

# hadolint ignore=DL3003
RUN set -eux; \
    . /opt/pragma/tools/versions.sh; \
    case "$(uname -m)" in \
      x86_64) rustup_target="x86_64-unknown-linux-gnu" ;; \
      aarch64|arm64) rustup_target="aarch64-unknown-linux-gnu" ;; \
      *) echo "Unsupported architecture" >&2; exit 1 ;; \
    esac; \
    tmpdir="$(mktemp -d)"; \
    curl -fsSL -o "$tmpdir/rustup-init" "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rustup_target}/rustup-init"; \
    curl -fsSL -o "$tmpdir/rustup-init.sha256" "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rustup_target}/rustup-init.sha256"; \
    (cd "$tmpdir" && sha256sum -c rustup-init.sha256); \
    chmod +x "$tmpdir/rustup-init"; \
    "$tmpdir/rustup-init" -y --profile minimal --default-toolchain "$RUST_VERSION" --component clippy,rustfmt; \
    chmod -R a+rX /usr/local/cargo /usr/local/rustup; \
    rm -rf "$tmpdir"

WORKDIR /workspace

CMD ["bash"]
