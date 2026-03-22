<p align="center">
  <img src="icon.png" alt="Pragma" width="200">
</p>

# Pragma

Opinionated, language-aware git hooks for all your repos. Enforces **formatting**, **linting**, **tests**, and **secret scanning** on every commit and push.

Powered by [lefthook](https://github.com/evilmartians/lefthook).

## Quick Start

```bash
# Clone pragma
git clone https://github.com/zakstak/pragma.git ~/.pragma

# Bootstrap into any repo
~/.pragma/install.sh /path/to/your-repo

# Or for CI/agent environments (non-interactive)
~/.pragma/install.sh --agent /path/to/your-repo
```

## What It Does

### Pre-commit (fast, staged files only)
- **Formats** code with the right formatter per language
- **Lints** code with the right linter per language
- **Scans for secrets** with [gitleaks](https://github.com/gitleaks/gitleaks)

### Pre-push (full repo)
- **Runs tests** for all detected languages

## Supported Languages

| Language   | Formatter    | Linter           | Test Runner       |
|------------|-------------|------------------|-------------------|
| Go         | `goimports` | `golangci-lint`  | `go test ./...`   |
| Rust       | `rustfmt`   | `clippy`         | `cargo test`      |
| TypeScript | `prettier`  | `eslint`         | `bun test` / `npm test` |
| HTML       | `prettier`  | —                | —                 |
| YAML       | `prettier`  | `yamllint`       | —                 |
| Docker     | —           | `hadolint`       | —                 |
| Shell      | `shfmt`     | `shellcheck`     | —                 |
| Markdown   | `prettier`  | —                | —                 |
| TOML       | `taplo`     | `taplo check`    | —                 |
| JSON       | `prettier`  | —                | —                 |
| Python     | `ruff`      | `ruff check`     | `pytest`          |

All repos also get **gitleaks** secret scanning.

## Language Detection

Pragma auto-detects languages by:
- **Pre-commit**: checking file extensions of staged files
- **Pre-push**: scanning for project markers (`go.mod`, `Cargo.toml`, `tsconfig.json`, etc.)

No configuration needed — it figures out what to run.

## Bootstrap Modes

| Mode | Flag | Behavior |
|------|------|----------|
| **Interactive** | _(default)_ | Colored output, prompts for missing tools |
| **Agent** | `--agent` | Silent unless errors, auto-installs tools |

## Skipping Hooks

```bash
# Skip all hooks for one commit/push
git commit --no-verify
git push --no-verify
```

## Uninstall

```bash
cd /path/to/your-repo
lefthook uninstall
rm lefthook.yml
```

## Installing Missing Tools

Pragma will check for required tools during setup. To re-check and install:

```bash
~/.pragma/tools/install-tools.sh         # interactive
~/.pragma/tools/install-tools.sh --agent  # auto-install
```

Tool install priority: `nix` → `go install` → `cargo install` → `npm` → `pip`

## Docker

Pre-built image with all tools — no build needed:

```bash
# Pull from GitHub Container Registry
docker pull ghcr.io/zakstak/pragma:latest

# Run against your repo
docker run --rm -v $(pwd):/repo ghcr.io/zakstak/pragma:latest --agent /repo

# Or build locally
docker build -t pragma .
```

## Repo Structure

```
pragma/
├── install.sh           # Bootstrap entrypoint
├── Dockerfile           # All tools pre-installed
├── lefthook.yml         # Shared hook config template
├── lib/
│   ├── common.sh        # Utilities (colors, logging, tool checks)
│   ├── detect.sh        # Language detection
│   ├── format.sh        # Formatter dispatch
│   ├── lint.sh          # Linter dispatch
│   └── test.sh          # Test runner dispatch
├── tools/
│   └── install-tools.sh # Auto-install missing tools
└── .gitleaks.toml       # Default gitleaks config
```

