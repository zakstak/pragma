<p align="center">
  <img src="icon.png" alt="Pragma" width="200">
</p>

# Pragma

Opinionated, language-aware git hooks for all your repos. Enforces
**formatting**, **linting**, **tests**, and **secret scanning** on every commit
and push.

Powered by [prek](https://github.com/j178/prek).

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

## Portable hook configuration

Generated hooks resolve Pragma in this order:

1. `PRAGMA_HOME`, if set.
2. `git config --path --get pragma.home`.
3. `~/.pragma`.

Bootstrap stores a custom checkout path in local Git config. Generated wrappers
and `prek.toml` contain no machine-specific checkout paths. You can commit them
and bootstrap each clone on its own machine.

If you move your Pragma checkout, rerun bootstrap or update the local setting:

```bash
git config --local pragma.home /new/path/to/pragma
```

For a temporary override:

```bash
PRAGMA_HOME=/path/to/pragma prek run --all-files
```

Go remains supported with `goimports`, golangci-lint v2, and `go test ./...`.
Golangci-lint v1 compatibility and Go templ support have been removed. `.templ`
files are ignored. Older linters must be upgraded; hooks do not fall back to
`go vet` or skip the v2 configuration. To update an existing repository's
generated hooks, rerun `install.sh`.

## Docker Tooling Mode

If you want Pragma to run against a prebuilt Docker toolchain on macOS or Linux
instead of host formatter/linter/test installs, build the tooling image once and
bootstrap with `--docker-tools`:

```bash
docker build -t pragma-tools:local ~/.pragma
~/.pragma/install.sh --agent --docker-tools /path/to/your-repo
```

Pragma's Docker wrappers follow the common `docker run --user uid:gid` pattern
used by tools like Composer:

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

In native mode, `install.sh` still needs `prek` to finish bootstrap. If it is
not already on your `PATH`, Pragma first tries its own pinned release binary
installer. You can also install `prek` yourself first. Node is not required to
install `prek`. The hook manager runs on the host in both native and Docker
modes.

For self-installs, Docker mode updates the repo-local `prek.toml` in place to
inject a repo-scoped `PRAGMA_TOOL_MODE=docker` hook environment while keeping
the existing relative `./lib/...` entries. Native self-installs continue to keep
the checked-in `prek.toml` unchanged. Self-installs require an existing
repo-local `prek.toml`; `install.sh` will not generate one from scratch for the
Pragma repo itself.

## What It Does

### Pre-commit (fast, staged files only)

- **Formats** code with the right formatter per language
- **Lints** code with the right linter per language
- **Scans for secrets** with [Kingfisher](https://github.com/mongodb/kingfisher)

When formatting changes files, the commit stops. Review the changes, stage the
files, and commit again. Hooks leave the Git index unchanged.

### Pre-push (full repo)

- **Runs tests** for all detected languages

## Secret scanning

The pre-commit hook uses Kingfisher 2.11.1 to scan staged changes. It uses two
scan workers, redacts findings, and disables credential validation and update
checks. Any finding or nonzero scanner exit blocks the commit.

Bootstrap copies `kingfisher.yaml` into the target repository unless it already
exists. The hook loads that file explicitly, falling back to Pragma's defaults
when it is absent. The default exclusions and placeholder patterns carry over
from the previous scanner. Edit the project's `filters` or `rules` settings for
its own policy; `kingfisher:ignore` suppresses an intentional finding inline.

Rerun `install.sh` in existing repositories to replace the Gitleaks hook. Custom
`.gitleaks.toml` rules are not converted automatically: move them to
Kingfisher's YAML configuration and custom rule format before retiring that
file. Pragma leaves existing project files in place.

Kingfisher reuses its compiled rule cache on native hosts. Docker wrappers mount
a private cache at `${XDG_CACHE_HOME:-$HOME/.cache}/pragma/kingfisher-docker` so
repeated container runs reuse it too. The first scan can take longer while rules
compile.

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

| Language   | Formatter                    | Linter             | Test Runner             |
| ---------- | ---------------------------- | ------------------ | ----------------------- |
| Go         | `goimports` / `gofmt`        | `golangci-lint` v2 | `go test ./...`         |
| Rust       | `rustfmt`                    | `clippy`           | `cargo test`            |
| TypeScript | `prettier`                   | `eslint`           | `bun test` / `npm test` |
| HTML       | `prettier` (plain HTML only) | —                  | —                       |
| YAML       | `prettier`                   | `yamllint`         | —                       |
| Docker     | —                            | `hadolint`         | —                       |
| Shell      | `shfmt`                      | `shellcheck`       | —                       |
| Markdown   | `prettier`                   | —                  | —                       |
| TOML       | `taplo`                      | `taplo check`      | —                       |
| JSON       | `prettier`                   | —                  | —                       |
| Python     | `ruff`                       | `ruff check`       | `pytest`                |

All repos also get **Kingfisher** secret scanning.

## Language Detection

Pragma auto-detects languages by:

- **Pre-commit**: checking file extensions of staged files
- **Pre-push**: scanning for project markers (`go.mod`, `Cargo.toml`,
  `package.json`, `tsconfig.json`, and Python manifests)

No configuration needed — it figures out what to run.

## Template HTML Safety

Pragma treats **plain HTML** and **templated HTML** differently on purpose.

- Plain `.html` / `.htm` files are formatted with `prettier`.
- `.html` / `.htm` files that contain template delimiters like `{{ ... }}`,
  `{% ... %}`, or `{# ... #}` are **not** sent through the generic HTML
  formatter.

That keeps Pragma from fighting Askama/Jinja-style templates where delimiter
whitespace and block structure are part of the template language, not just HTML
layout. HTMX attributes work inside plain HTML because they are regular HTML
attributes.

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
prek uninstall
rm prek.toml
```

## Installing Missing Tools

After bootstrap, Pragma detects the languages in the target repo and installs
any missing formatter/linter/test dependencies it needs.

Most tools are downloaded as pre-built binaries from GitHub Releases.
`goimports` requires Go 1.26+ to build:

```bash
~/.pragma/tools/install-tools.sh         # interactive
~/.pragma/tools/install-tools.sh --agent  # auto-install
~/.pragma/tools/install-tools.sh --agent --update  # refresh to committed versions
~/.pragma/tools/install-tools.sh --docker --agent  # install Docker-backed wrappers
```

Binaries are placed in `~/.pragma/bin/` (or `<your-clone>/bin/`) and
automatically added to PATH by the hooks.

In Docker mode those binaries are lightweight wrappers that call
`tools/docker-run.sh`, which in turn runs the requested tool in the configured
tooling image as your host UID/GID. Docker-backed wrappers live under
`bin/docker/` so native installs and Docker installs do not stomp on each other.

Some tools still rely on package managers:

- `goimports` builds from its pinned module using your installed Go toolchain.
  Docker includes a pinned Go toolchain.
- `prettier` and `eslint` install from Pragma's committed `package-lock.json`
  via `npm ci`; ESLint v10 requires Node 20.19+, 22.13+, or 24+
- `ruff`, `yamllint`, and `pytest` install from Pragma's committed hashed
  requirements via a repo-local Python venv

Binary downloads require `curl`, and archive extraction may also need `tar`,
`gunzip`, or `xz` depending on the tool. Python tools require Python 3.10+ with
`venv` support.

## Update tool versions

Native installs and Docker use the same installer. Binary versions are in
`tools/versions.sh`. Node tools are in `.npm-packages/package.json`, and Python
tools are in `tools/requirements/python.in`.

After changing Node or Python versions, regenerate their lockfiles:

```bash
npm install --package-lock-only --ignore-scripts --prefix .npm-packages
uv pip compile --universal --python-version 3.10 --generate-hashes --no-header \
  --output-file tools/requirements/python.txt tools/requirements/python.in
```

When updating a binary with a hardcoded checksum, update its platform hashes in
`tools/install-tools.sh` too. The Go and Node image digests are in `Dockerfile`.
Rebuild the Docker image after changing tool versions.

## Experiment in a disposable copy

Copy the checkout into a temporary directory before installing tools or hooks:

```bash
sandbox="$(mktemp -d)"
cp -R ~/.pragma "$sandbox/pragma"
git init "$sandbox/example"
"$sandbox/pragma/install.sh" --agent "$sandbox/example"
```

The installer writes tools inside the copied Pragma checkout and hooks inside
`example`. Rust component installation uses your existing rustup installation.
Use Docker mode if you need an isolated Rust toolchain.

## Run the checks

The native checks need Git, Go 1.26+, and npm with a supported Node version.
Install the tools used by the test fixtures before running them:

```bash
PRAGMA_INSTALL_ONLY_TOOLS="prek kingfisher goimports golangci-lint prettier shfmt shellcheck hadolint yamllint" \
  ./tools/install-tools.sh --agent
./tools/check.sh
```

These checks exercise real commits and pushes against a temporary local Git
remote. They verify Go and shell formatting, lint rejection, secret rejection,
and passing and failing Go and npm pre-push tests. Docker wrapper tests use a
stub daemon.

To build the image and repeat the real Git-hook checks with Docker-backed tools,
run this with access to a Docker daemon:

```bash
./tools/check.sh --docker
```

## Repo Structure

```
pragma/
├── install.sh           # Bootstrap entrypoint
├── Dockerfile           # Optional tooling image build
├── prek.toml            # Repo-local prek config for pragma itself
├── lib/
│   ├── common.sh        # Utilities (colors, logging, tool checks)
│   ├── detect.sh        # Language detection
│   ├── format.sh        # Formatter dispatch
│   ├── lint.sh          # Linter dispatch
│   └── test.sh          # Test runner dispatch
├── tools/
│   ├── docker-run.sh    # Runs tools inside the Docker image
│   └── install-tools.sh # Auto-install missing tools
└── kingfisher.yaml       # Default Kingfisher config
```
