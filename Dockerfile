# Pragma — all linting/formatting tools in one image
# Usage:
#   docker build -t pragma .
#   docker run --rm -v $(pwd):/repo pragma /repo/install.sh --agent /repo
FROM alpine:3.21

# ─── System deps ──────────────────────────────────────────────────────────────
RUN apk add --no-cache \
    bash \
    git \
    curl \
    go \
    rust \
    cargo \
    nodejs \
    npm \
    python3 \
    py3-pip \
    shellcheck \
    shfmt

# ─── Go tools ─────────────────────────────────────────────────────────────────
ENV GOPATH=/go PATH="/go/bin:/usr/local/go/bin:$PATH"

RUN go install github.com/evilmartians/lefthook@latest && \
    go install github.com/gitleaks/gitleaks/v8@latest && \
    go install golang.org/x/tools/cmd/goimports@latest && \
    go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest && \
    rm -rf /go/pkg /root/.cache/go-build

# ─── Rust tools ───────────────────────────────────────────────────────────────
RUN rustup-init -y --default-toolchain stable --component clippy rustfmt 2>/dev/null || true && \
    cargo install taplo-cli && \
    rm -rf /root/.cargo/registry /root/.cargo/git

ENV PATH="/root/.cargo/bin:$PATH"

# ─── Node tools ───────────────────────────────────────────────────────────────
RUN npm install -g --no-fund --no-audit \
    prettier \
    eslint

# ─── Python tools ─────────────────────────────────────────────────────────────
RUN pip install --break-system-packages --no-cache-dir \
    yamllint \
    ruff

# ─── Hadolint (static binary) ────────────────────────────────────────────────
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then ARCH="x86_64"; \
    elif [ "$ARCH" = "aarch64" ]; then ARCH="arm64"; fi && \
    curl -fsSL "https://github.com/hadolint/hadolint/releases/latest/download/hadolint-Linux-${ARCH}" \
      -o /usr/local/bin/hadolint && \
    chmod +x /usr/local/bin/hadolint

# ─── Copy pragma scripts ─────────────────────────────────────────────────────
COPY . /opt/pragma
ENV PATH="/opt/pragma:$PATH"

WORKDIR /repo
ENTRYPOINT ["/opt/pragma/install.sh"]
