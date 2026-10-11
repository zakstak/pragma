<p align="center">
  <img src="icon.png" alt="Pragma" width="200">
</p>

# Pragma

Language-aware Git hooks for Linux and macOS, powered by
[prek](https://github.com/j178/prek). Pre-commit formats and lints staged files
and scans staged changes for secrets. Pre-push runs project typechecks and
tests.

## Install

Clone Pragma and bootstrap an existing Git repository:

```bash
git clone https://github.com/zakstak/pragma.git ~/.pragma
~/.pragma/install.sh /path/to/your-repo
```

The installer prompts before installing missing tools or replacing an existing
`prek.toml`. Use `--agent` to skip prompts and overwrite the generated hook
configuration:

```bash
~/.pragma/install.sh --agent /path/to/your-repo
```

Both modes print setup progress. If you omit the repository path, the installer
uses your current directory. Windows is unsupported.

Bootstrap installs prek and Kingfisher as per-user core tools in `~/.local/bin`.
Add that directory to your shell's `PATH` to run them directly:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Set `PRAGMA_GLOBAL_BIN_DIR` to use another core installation directory. Core
installation uses release binaries and does not require Node or Go.

Language tools use project selections first, followed by your active `PATH` and
Pragma's pinned fallbacks. Install your project's dependencies before bootstrap.
See [Tool selection](#tool-selection) for the supported selections.

To install hooks for Pragma itself, run `./install.sh --agent .` from this
checkout. Self-install keeps the existing `prek.toml` unchanged and requires it
to exist.

## Try a disposable install

Clone a fresh checkout so existing tool caches and virtualenvs are excluded.
This example installs core tools and hooks inside a temporary directory:

```bash
sandbox="$(mktemp -d)"
git clone https://github.com/zakstak/pragma.git "$sandbox/pragma"
git init "$sandbox/example"
(
  export PRAGMA_GLOBAL_BIN_DIR="$sandbox/core-bin"
  export PATH="$PRAGMA_GLOBAL_BIN_DIR:$PATH"
  "$sandbox/pragma/install.sh" --agent "$sandbox/example"
  cd "$sandbox/example"
  prek run --all-files
)
```

The empty example repository does not need language tools. If you add Rust
files, installing missing Rust components uses your existing rustup toolchain.

## Hook behavior

Pre-commit runs formatters and linters for recognized staged files, then
[Kingfisher](https://github.com/mongodb/kingfisher) scans staged changes. When
formatting changes files, the commit stops. Review the changes, stage them, and
commit again. Hooks leave the Git index unchanged.

Pre-push runs test suites for detected Go, Rust, JavaScript, TypeScript, and
Python projects. For JavaScript and TypeScript, a repository-root
`scripts.typecheck` command runs before tests when declared in `package.json`.
Bun projects use `bun run typecheck`; other projects use `npm run typecheck`. A
failing typecheck blocks the push, including in projects without a test script.

| Language              | Formatter                    | Linter             | Test runner             |
| --------------------- | ---------------------------- | ------------------ | ----------------------- |
| Go                    | `goimports` / `gofmt`        | `golangci-lint` v2 | `go test ./...`         |
| Rust                  | `rustfmt`                    | `clippy`           | `cargo test`            |
| JavaScript/TypeScript | `prettier`                   | `oxlint`           | `bun test` / `npm test` |
| HTML                  | `prettier` (plain HTML only) | —                  | —                       |
| YAML                  | `prettier`                   | `yamllint`         | —                       |
| Dockerfiles           | —                            | `hadolint`         | —                       |
| Shell                 | `shfmt`                      | `shellcheck`       | —                       |
| Markdown              | `prettier`                   | —                  | —                       |
| TOML                  | `taplo`                      | `taplo check`      | —                       |
| JSON                  | `prettier`                   | —                  | —                       |
| Python                | `ruff`                       | `ruff check`       | `pytest`                |

Pre-commit detects languages from file names. Bootstrap and pre-push inspect
project files such as `go.mod`, `Cargo.toml`, `package.json`, and Python
manifests.

Golangci-lint v2 is required. Go templ files (`.templ`) are ignored.

Oxlint checks JavaScript and TypeScript files with `--deny-warnings`. It uses
your project's Oxlint configuration and does not apply fixes. Existing ESLint
configurations need
[migration to Oxlint](https://oxc.rs/docs/guide/usage/linter/migrate-from-eslint.html).

HTML files containing template delimiters such as `{{ ... }}`, `{% ... %}`, or
`{# ... #}` skip HTML formatting. Plain HTML, including HTMX attributes, uses
Prettier.

## Tool selection

Core binaries are shared across Pragma checkouts in `~/.local/bin`, or
`PRAGMA_GLOBAL_BIN_DIR`. Language fallbacks live in `<pragma>/bin`.

Hooks and the installer prefer these project selections:

- Prettier and Oxlint from the repository root's `node_modules/.bin`.
- Python, pytest, Ruff, and yamllint from `<environment>/bin`. The environment
  is `UV_PROJECT_ENVIRONMENT` when set, or the repository root's `.venv`.
  Pragma's own fallback virtualenv is excluded.
- Go module `tool` directives for goimports and golangci-lint v2, invoked with
  [`go tool`](https://go.dev/ref/mod#go-mod-file-tool) from each module
  directory.

Without a project selection, tools on your active `PATH` take precedence over
Pragma's pinned fallbacks. Toolchain managers can select Go, Rust, and Node
through `PATH` and their project configuration.

A Prettier or Oxlint dependency declared in `package.json` but absent from
`node_modules/.bin` causes an error. Hooks do not install npm dependencies or
fetch tools through `npx`.

To check and install missing language tools, run the installer from the target
repository:

```bash
cd /path/to/your-repo
~/.pragma/tools/install-tools.sh --agent
```

Omit `--agent` to prompt before installation. To install only the global core,
run:

```bash
~/.pragma/tools/install-tools.sh --global --agent
```

Most fallback tools use prebuilt release binaries. The remaining requirements
are:

- goimports builds from Pragma's pinned Go module and needs Go 1.26 or newer.
- Prettier and Oxlint use Pragma's `package-lock.json` through `npm ci`. The
  fallback Oxlint needs Node 20.19+ or 22.12+.
- Ruff, yamllint, and pytest use hashed requirements in Pragma's `.venv`.
  Installation needs Python 3.10+ with `venv` support.
- Rust components use your installed rustup toolchain.

Downloads require `curl` and a SHA-256 checksum utility. Archive extraction also
needs `tar`, `gunzip`, or `xz`, depending on the tool.

## Effect projects

Keep Effect tooling and TypeScript pinned in the project. For the native
`@effect/tsgo` integration, install a compatible TypeScript 7 toolchain,
`oxlint`, and `oxlint-tsgolint`. Follow the
[Effect Oxlint setup](https://effect.website/docs/v4/getting-started/devtools#oxlint)
to configure the plugin, patch the project tools, and extend the recommended
preset. Pragma runs the project's patched Oxlint and reads its configuration.

Declare the project's typecheck command in `package.json`, for example:

```json
{
  "scripts": {
    "typecheck": "tsc --noEmit"
  }
}
```

Use the compiler command and project configurations your repository needs. For a
monorepo, let the root script check all packages. Pragma runs this script before
tests on pre-push and leaves compiler versions and Effect rules to the project.
Editor diagnostics alone do not run during a push.

## Cache a ts-rust shadow check

Install and pin [`tsc-rs`](https://github.com/pingdotgg/ts-rust) in the target
project. Declare a shadow script that uses the same project configurations and
compiler options as the normal typecheck. For example:

```json
{
  "scripts": {
    "typecheck": "tsc --noEmit --pretty false -p tsconfig.json",
    "typecheck:shadow": "tsc-rs --noEmit --pretty false -p tsconfig.json"
  }
}
```

For repeated comparisons, disable incremental caching in both scripts when
supported, or use separate compiler caches. Use separate output directories if
your typecheck scripts emit files.

Enable shadow capture for one push:

```bash
PRAGMA_SHADOW=1 git push
```

To enable it for future pushes in this clone:

```bash
git config --local pragma.shadow true
```

`PRAGMA_SHADOW=0` overrides the local setting. To run checks directly, use
`~/.pragma/lib/test.sh --shadow` from the project. The shadow runs after the
normal typecheck, including when the normal check fails. Only the normal check
decides whether typechecking blocks the push. Tests run after a passing normal
check. Pragma does not install shadow dependencies during a hook. Projects
without a normal `typecheck` script report a skip and do not create a
comparison.

Every enabled run retains both checks' full stdout and stderr, even when they
succeed or agree. Each run has a unique directory under
`git rev-parse --git-path pragma/shadow`. Linked worktrees use their own Git
metadata directory. Set `PRAGMA_SHADOW_CACHE_DIR` to use another location. Use a
dedicated cache directory. Receipts remain local until you remove them. Pragma
never submits findings upstream or dumps your full environment.

Each receipt contains:

- `baseline.stdout.log`, `baseline.stderr.log`, `shadow.stdout.log`, and
  `shadow.stderr.log`, with complete output and hashes recorded in metadata.
- `metadata.json`, with commands, script definitions, exit codes, signals,
  timestamps, timings, compiler and package versions, Pragma version and source
  hashes, host information, runtime paths, and Git HEAD, branch, status, and
  tree before and after the checks. Git status and input hashes exclude the
  capture cache itself. An unborn repository records a null HEAD.
- `git-staged.patch` and `git-worktree.patch`, including binary changes.
- `inputs-before.json` and `inputs-after.json`, with hashes of Git-listed
  JavaScript, TypeScript, and compiler configuration inputs. Ignored generated
  sources are excluded. `inputs/` retains copies of configs and lockfiles.
- `findings.json`, with normalized TypeScript diagnostic differences, outcome
  differences, crashes, timeouts, and changes to the repository during the run.
- `report.md` and `notes.md`, for reviewing and recording local observations.

Direct shadow runs print the receipt path. Prek can hide output from passing
hooks; inspect the cache directory after a push. Different nonzero exit codes
alone do not count as a mismatch. Findings are candidates for investigation,
since compiler versions, Effect rule versions, and script options can differ.
Configure `--pretty false` in both scripts for consistent diagnostic parsing.
Raw outputs remain available when a failure cannot be parsed.

The shadow has a 120-second timeout. Set `PRAGMA_SHADOW_TIMEOUT_SECONDS` to a
positive number up to 2147483.647 to change it. A timeout stops the shadow
process group and retains its output. It does not block a passing normal check.
Cache setup errors are reported, and the normal typecheck still runs. An
interrupted capture can leave a receipt with `state: "running"` and incomplete
results. Cancelling with SIGINT or SIGTERM stops the active compiler process
group.

## Update an existing install

Bootstrap replaces generated hooks and `prek.toml` in target repos. Review
custom hook configuration before using `--agent`. Existing `kingfisher.yaml`
files are preserved.

Update the checkout, refresh core and fallback pins from the target repository,
and regenerate its hooks:

```bash
git -C ~/.pragma pull --ff-only
cd /path/to/your-repo
~/.pragma/tools/install-tools.sh --agent --update
~/.pragma/install.sh --agent .
```

`--update` preserves installed project tools and Go module tool declarations. It
does not change project dependency versions.

Existing `.gitleaks.toml` rules are not converted automatically. Move custom
rules to Kingfisher's YAML configuration before retiring that file. Bootstrap
leaves it in place.

## Portable hook configuration

Generated hook scripts resolve the Pragma checkout in this order:

1. `PRAGMA_HOME`, if set.
2. `git config --path --get pragma.home`.
3. `~/.pragma`.

Bootstrap stores custom checkout paths in local Git config. Generated scripts
and `prek.toml` contain no machine-specific paths. Commit them and bootstrap
each clone on its own machine.

After moving a Pragma checkout, rerun bootstrap or update the local setting:

```bash
git config --local pragma.home /new/path/to/pragma
```

To use a checkout temporarily:

```bash
PRAGMA_HOME=/path/to/pragma prek run --all-files
```

## Secret scanning

Kingfisher scans staged changes with two workers. It redacts findings and
disables credential validation and update checks. A finding or scanner error
blocks the commit. The first scan can take longer while rules compile, and later
scans reuse Kingfisher's rule cache.

Bootstrap copies `kingfisher.yaml` into the target repository if it is absent.
The hook loads that file explicitly, using Pragma's defaults when it is missing.
Edit the project's `filters` or `rules` for its policy. Use `kingfisher:ignore`
to suppress an intentional finding inline.

## Hook output

Hooks are quiet on success. Failures emit one compact JSON line with the hook,
step, failed tools, exit codes, and a tail of each tool's output. For example:

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
      "tail": "FAIL suite",
      "code": 1
    }
  ],
  "code": 1
}
```

For human-readable output during debugging:

```bash
PRAGMA_OUTPUT_FORMAT=human git commit
PRAGMA_OUTPUT_FORMAT=human git push
```

## Skip hooks

```bash
# Skip all hooks for one commit or push
git commit --no-verify
git push --no-verify

# Skip pre-push typechecking and tests
PRAGMA_SKIP_TESTS=1 git push
```

## Uninstall hooks

```bash
cd /path/to/your-repo
prek uninstall
rm prek.toml
```

Core tools and Pragma's checkout remain available for other repositories.

## Run the checks

Checks need Git, Go 1.26+, and npm with a Node version supported by the fallback
Oxlint. From the Pragma checkout:

```bash
PRAGMA_INSTALL_ONLY_TOOLS="prek kingfisher goimports golangci-lint prettier oxlint shfmt shellcheck yamllint" \
  ./tools/install-tools.sh --agent
export PATH="${PRAGMA_GLOBAL_BIN_DIR:-$HOME/.local/bin}:$PATH"
./tools/check.sh
```

Checks use temporary repositories and a local Git remote. They exercise real
commits and pushes, formatter changes, lint and secret rejection, passing and
failing typechecks, Go and npm tests, tool precedence, preservation of project
versions during updates, and shadow capture across successes, differences,
crashes, timeouts, and linked worktrees.

## Maintain fallback versions

Binary versions are in `tools/versions.sh`, Node packages in
`.npm-packages/package.json`, and Python packages in
`tools/requirements/python.in`.

After changing Node or Python packages, regenerate their lockfiles:

```bash
npm install --package-lock-only --ignore-scripts --prefix .npm-packages
uv pip compile --universal --python-version 3.10 --generate-hashes --no-header \
  --output-file tools/requirements/python.txt tools/requirements/python.in
```

For binaries with hardcoded checksums, update the platform hashes in
`tools/install-tools.sh` as well.

## Main files

```text
pragma/
├── install.sh           # Bootstrap entrypoint
├── prek.toml            # Hooks for Pragma itself
├── kingfisher.yaml      # Default secret scan configuration
├── lib/
│   ├── common.sh        # Logging and shared helpers
│   ├── tooling.sh       # Global and project tool selection
│   ├── detect.sh        # Language detection
│   ├── format.sh        # Formatter dispatch
│   ├── lint.sh          # Linter dispatch
│   ├── secrets.sh       # Kingfisher invocation
│   ├── test.sh          # Project typecheck and test dispatch
│   └── shadow.js        # Local compiler comparison receipts
├── tools/
│   ├── check.sh         # Repository checks
│   ├── install-tools.sh # Missing tool installation
│   └── versions.sh      # Core and fallback binary pins
└── tests/               # Installer and hook checks
```
