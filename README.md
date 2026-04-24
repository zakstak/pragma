<p align="center">
  <img src="icon.png" alt="Pragma" width="200">
</p>

# Pragma

Opinionated, language-aware git hooks for all your repos. Enforces
**formatting**, **linting**, **tests**, and **secret scanning** on every commit
and push.

Powered by [lefthook](https://github.com/evilmartians/lefthook).

## Install

```bash
# Clone pragma
git clone https://github.com/zakstak/pragma.git ~/.pragma

# Bootstrap into the current git repo
(cd /path/to/your-repo && ~/.pragma/install.sh)

# Or bootstrap a specific git repo by path
~/.pragma/install.sh /path/to/your-repo

# Or for CI/agent environments (non-interactive)
~/.pragma/install.sh --agent /path/to/your-repo

# Or use the Docker tooling image instead of host-installed tools
~/.pragma/install.sh --agent --docker-tools /path/to/your-repo

# Dogfood pragma on this repo itself with Docker-backed tools
./install.sh --agent --docker-tools .

# Dogfood pragma on this repo itself
./install.sh --agent .
```

Bootstrap expects the target to already be a Git repository.

Bootstrap and tool installation are supported on macOS and Linux only. Windows
hosts are not supported, including when using `--docker-tools`.

## Docker Tooling Mode

If you want Pragma to run against a prebuilt Docker toolchain on macOS or Linux
instead of host formatter/linter/test installs, build the tooling image once and
bootstrap with `--docker-tools`:

```bash
docker build -t pragma-tools:local ~/.pragma
~/.pragma/install.sh --agent --docker-tools /path/to/your-repo
```

Pragma's Docker wrappers follow the common `docker run --user uid:gid` pattern
used by tools like Composer and golangci-lint:

- bind-mount the target repo at `/workspace`
- run container processes as your host UID/GID
- keep container `HOME` and cache paths under `/tmp` inside the container
- scope Docker wrappers to Docker-enabled repos instead of globally changing all
  repos
- never `chown` the mounted repo

That means formatted files stay owned by the host user instead of becoming
root-owned after a hook run.

You can override the image tag with `PRAGMA_DOCKER_IMAGE`, for example:

```bash
PRAGMA_DOCKER_IMAGE=ghcr.io/your-org/pragma-tools:latest git commit
```

To switch an already-bootstrapped normal repo back to native host tools, rerun
bootstrap without `--docker-tools`:

```bash
~/.pragma/install.sh --agent /path/to/your-repo
```

In native mode, `install.sh` still needs `lefthook` to finish bootstrap. If it
is not already on your `PATH`, Pragma first tries its own pinned installer and
falls back to `nix-env` if available. You can also install `lefthook` yourself
first (for example `brew install lefthook` or `nix-env -iA nixpkgs.lefthook`).

For self-installs, Docker mode updates the repo-local `lefthook.yml` in place to
inject the repo-scoped `PRAGMA_DOCKER_BIN_DIR=...` prefix while keeping the
existing relative `./lib/...` commands. Native self-installs continue to keep
the checked-in `lefthook.yml` unchanged.

## What It Does

### Pre-commit (fast, staged files only)

- **Formats** code with the right formatter per language
- **Lints** code with the right linter per language
- **Scans for secrets** with [gitleaks](https://github.com/gitleaks/gitleaks)

### Pre-push (full repo)

- **Runs tests** for all detected languages

## Hook Output

Hook scripts are quiet on success. On failure they emit one compact JSON line
that is optimized for GPT-style agents and other automation.

```json
{
  "v": 1,
  "hook": "pre-push",
  "step": "test",
  "fails": [
    {
      "tool": "npm",
      "cls": "test",
      "skip": 1,
      "skip_cmd": "PRAGMA_SKIP_TESTS=1 git push",
      "rerun": "./lib/test.sh",
      "msg": "npm tests failed",
      "tail": "FAIL suite\nECONNREFUSED",
      "code": 1
    }
  ],
  "code": 1
}
```

If you want the older human-readable output while debugging locally:

```bash
PRAGMA_OUTPUT_FORMAT=human git commit
PRAGMA_OUTPUT_FORMAT=human git push
```

## Supported Languages

| Language   | Formatter   | Linter          | Test Runner             |
| ---------- | ----------- | --------------- | ----------------------- |
| Go         | `goimports` | `golangci-lint` | `go test ./...`         |
| Rust       | `rustfmt`   | `clippy`        | `cargo test`            |
| TypeScript | `prettier`  | `eslint`        | `bun test` / `npm test` |
| HTML       | `prettier`  | —               | —                       |
| YAML       | `prettier`  | `yamllint`      | —                       |
| Docker     | —           | `hadolint`      | —                       |
| Shell      | `shfmt`     | `shellcheck`    | —                       |
| Markdown   | `prettier`  | —               | —                       |
| TOML       | `taplo`     | `taplo check`   | —                       |
| JSON       | `prettier`  | —               | —                       |
| Python     | `ruff`      | `ruff check`    | `pytest`                |

All repos also get **gitleaks** secret scanning.

## Language Detection

Pragma auto-detects languages by:

- **Pre-commit**: checking file extensions of staged files
- **Pre-push**: scanning for project markers (`go.mod`, `Cargo.toml`,
  `tsconfig.json`, etc.)

No configuration needed — it figures out what to run.

## Bootstrap Modes

| Mode            | Flag             | Behavior                                                 |
| --------------- | ---------------- | -------------------------------------------------------- |
| **Interactive** | _(default)_      | Colored output, prompts for missing tools                |
| **Agent**       | `--agent`        | Silent unless errors, auto-installs tools                |
| **Docker**      | `--docker-tools` | Use Docker-backed tool wrappers instead of host installs |

## Skipping Hooks

```bash
# Skip all hooks for one commit/push
git commit --no-verify
git push --no-verify

# Skip only pre-push tests
PRAGMA_SKIP_TESTS=1 git push
```

## Uninstall

```bash
cd /path/to/your-repo
lefthook uninstall
rm lefthook.yml
```

## Installing Missing Tools

After bootstrap, Pragma detects the languages in the target repo and installs
any missing formatter/linter/test dependencies it needs.

Most tools are downloaded as pre-built binaries from GitHub Releases — no Go,
Rust, or compilation required:

```bash
~/.pragma/tools/install-tools.sh         # interactive
~/.pragma/tools/install-tools.sh --agent  # auto-install
~/.pragma/tools/install-tools.sh --docker --agent  # install Docker-backed wrappers
```

Binaries are placed in `~/.pragma/bin/` (or `<your-clone>/bin/`) and
automatically added to PATH by the hooks.

In Docker mode those binaries are lightweight wrappers that call
`tools/docker-run.sh`, which in turn runs the requested tool in the configured
tooling image as your host UID/GID. Docker-backed wrappers live under
`bin/docker/` so native installs and Docker installs do not stomp on each other.

Some tools still rely on package managers:

- `prettier` and `eslint` install from Pragma's committed `package-lock.json`
  via `npm ci`
- `ruff` and `yamllint` install from Pragma's committed hashed requirements via
  a repo-local Python venv

Binary downloads require `curl`, and archive extraction may also need `tar`,
`gunzip`, or `unzip` depending on the tool.

## Repo Structure

```
pragma/
├── install.sh           # Bootstrap entrypoint
├── Dockerfile           # Optional tooling image build
├── lefthook.yml         # Repo-local config for pragma itself
├── lib/
│   ├── common.sh        # Utilities (colors, logging, tool checks)
│   ├── detect.sh        # Language detection
│   ├── format.sh        # Formatter dispatch
│   ├── lint.sh          # Linter dispatch
│   └── test.sh          # Test runner dispatch
├── tools/
│   ├── docker-run.sh    # Runs tools inside the Docker image
│   └── install-tools.sh # Auto-install missing tools
└── .gitleaks.toml       # Default gitleaks config
```
