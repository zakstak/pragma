<p align="center">
  <img src="icon.png" alt="Pragma" width="200">
</p>

# Pragma

Language-aware Git hooks for Linux and macOS, powered by
[prek](https://github.com/j178/prek). Pre-commit formats and lints staged files
and scans staged changes for secrets. Pre-push runs project typechecks, tests,
and advisory ts-rust compiler comparisons.

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

TypeScript repositories also receive Pragma's pinned ts-rust shadow compiler.
The installer adds its own comparison hook without changing project compiler
dependencies. Shadow checking is enabled by default. See
[Review automatic ts-rust shadow checks](#review-automatic-ts-rust-shadow-checks)
for outputs, supported scopes, and opt-out settings.

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

Rust formatting uses each package's Cargo edition, including workspace
inheritance. Packages without an edition use Rust 2015; standalone files use
Rust 2021.

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
  Installation needs Python 3.10+ with `venv` support. Installing any Python
  fallback exposes all three pinned tools in `<pragma>/bin`.
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

## Review automatic ts-rust shadow checks

Pragma installs a checksum-pinned
[`tsc-rs`](https://github.com/pingdotgg/ts-rust) release for TypeScript
repositories. The complete compiler and its standard library files stay in
Pragma's ignored `bin/` directory. Pragma leaves project compiler dependencies
and lockfiles unchanged.

New installations include a separate `pragma-shadow` pre-push hook. It discovers
TypeScript packages, including nested packages, and records comparisons against
the installed Rust compiler. No shadow script or local opt-in is required. Your
existing project checks decide whether the push succeeds. Shadow failures,
crashes, timeouts, and unsupported configurations remain advisory findings.

Direct `tsc` commands retain their input arguments and project configurations.
Automatic comparisons disable emission and keep incremental caches in the
receipt directory. Receipts identify checks that cover only TypeScript source
files. Vue and Svelte template checks require their framework tools and are not
equivalent to a plain compiler comparison. Arbitrary shell commands are not
rewritten into compiler commands.

To capture comparisons without running other project checks, run:

```bash
~/.pragma/lib/shadow.sh
```

To disable shadow installation and capture in this clone, run:

```bash
git config --local pragma.shadow false
```

`PRAGMA_SHADOW=0` disables capture for one invocation. `PRAGMA_SHADOW=1`
overrides the local setting. Remove the local setting to restore the default:

```bash
git config --local --unset pragma.shadow
```

A project's explicit `typecheck:shadow` script overrides automatic planning. Use
the same configurations and compiler options as its normal `typecheck`. For
example:

```json
{
  "scripts": {
    "typecheck": "tsc --noEmit --pretty false -p tsconfig.json",
    "typecheck:shadow": "tsc-rs --noEmit --pretty false -p tsconfig.json"
  }
}
```

An explicit script owns its dependencies. Pragma does not install dependencies
during a hook. Keep emitted files and incremental caches separate when either
script writes output.

Every enabled run retains both checks' full stdout and stderr, even when they
succeed or agree. Each run has a unique directory under
`git rev-parse --git-path pragma/shadow`. Linked worktrees use their own Git
metadata directory. Set `PRAGMA_SHADOW_CACHE_DIR` to use another location. Use a
dedicated cache directory. Receipts remain local until you remove them. Pragma
never submits findings upstream or dumps your full environment.

Each receipt contains:

- Complete baseline and shadow stdout/stderr logs. Each comparison's metadata
  identifies its output files and hashes, including nested package checks.
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
- `summary.json`, with `schema: "pragma.shadow-summary"` and
  `schema_version: 1`. It records the repository, worktree, thread, compiler
  outcomes, findings, Pragma source hashes, and relative paths to the full logs.
- `report.md` and `notes.md`, for reviewing and recording local observations.

Direct shadow runs print the receipt path. Prek can hide output from passing
hooks; inspect the cache directory after a push. Different nonzero exit codes
alone do not count as a mismatch. Findings are candidates for investigation,
since compiler versions, Effect rule versions, and script options can differ.
Configure `--pretty false` in both scripts for consistent diagnostic parsing.
Raw outputs remain available when a failure cannot be parsed.

Advisory baseline and shadow commands each have a 120-second timeout. Set
`PRAGMA_SHADOW_TIMEOUT_SECONDS` to a positive number up to 2147483.647 to change
it. A timeout stops the shadow process group and retains its output. It does not
block a passing normal check. Cache setup errors are reported, and the normal
typecheck still runs. An interrupted capture can leave a receipt with
`state: "running"` and incomplete results. Cancelling with SIGINT or SIGTERM
stops the active compiler process group.

### Collect versioned summaries

To collect receipts from several repositories, run:

```bash
node ~/.pragma/tools/collect-shadow.js \
  --repo /path/to/first-repo --repo /path/to/second-repo > shadow-collection.json
```

For a shared cache, use `--cache /path/to/cache`. You can repeat both options.
Without options, the collector uses `PRAGMA_SHADOW_CACHE_DIR` or the current
worktree's Git cache. Add `--latest` to retain the latest completed run for each
repository, worktree, and thread combination. Separate threads retain separate
results, even when they share a repository. Legacy receipts without identities
form separate groups from identified runs; the collector does not infer a thread
or repository identity for old captures.

The output has `schema: "pragma.shadow-collection"` and `schema_version: 1`. Its
`runs` array pairs each absolute receipt path with its versioned summary. Each
summary's `baseline` and `shadow` fields retain the root project checks, or are
null when those checks did not run. Read `baseline_policy` to distinguish a
blocking project check from an advisory capture. The `comparisons` array records
individual compiler comparisons, which can have narrower coverage. The `skipped`
array records incomplete, invalid, or unsupported receipts with a reason.
Existing completed metadata version 2 receipts are adapted in memory; the
collector never changes their files. Collectors must check the schema name and
version before reading fields. Additional fields can be added within a version;
incompatible changes require a new version.

Pragma writes the run summary before publishing `metadata.json` with
`state: "complete"`. The collector excludes a capture until that marker exists.
Logs and receipts remain local and can contain source code or compiler output.

### Isolate concurrent agent threads

Use one worktree per agent thread before starting edits. With Node installed,
create or reuse the worktree for your current Codex thread:

```bash
node ~/.pragma/tools/thread-worktree.js "$CODEX_THREAD_ID" /path/to/repo
```

Change into the `worktree` path in the JSON output. For another agent runtime,
set `PRAGMA_THREAD_ID` to its stable thread ID and pass that value instead.
Without arguments, the helper uses `PRAGMA_THREAD_ID`, then `CODEX_THREAD_ID`,
and the current repository. IDs contain 1–128 printable characters without
surrounding whitespace.

The helper creates a separate branch and worktree under
`~/.cache/pragma/worktrees/`. Set `PRAGMA_WORKTREE_DIR` to change that base
directory. Reusing a thread preserves its dirty files and commits. Concurrent
creation for the same thread is serialized. Conflicting ownership, an occupied
branch, or an unowned destination causes an error that preserves existing work.

Ownership is stored in that worktree's Git metadata at `pragma/thread.json`.
Pragma's format, lint, secrets, and normal test hooks reject a different thread
ID before running checks. `PRAGMA_THREAD_ID` takes precedence over
`CODEX_THREAD_ID`; manual runs without either inherit the worktree owner.
Unclaimed checkouts remain usable, so run the helper for each concurrent thread.
These guards apply to Pragma hooks and helpers; they do not prevent a chat from
opening or intercept arbitrary file edits.

Shadow receipts record repository, worktree, and thread identities. Receipt
directories are unique even when several threads use the same shadow cache. The
versioned collector keeps their results separate without a shared summary file
that concurrent runs could overwrite.

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

Checks need Git, Go 1.26+, rustfmt with Rust 2024 support, and npm with a Node
version supported by the fallback Oxlint. From the Pragma checkout:

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
│   ├── shadow.sh        # Advisory comparison hook
│   ├── shadow-plan.js   # Supported compiler arguments
│   └── shadow.js        # Local compiler comparison receipts
├── tools/
│   ├── check.sh         # Repository checks
│   ├── install-tools.sh # Missing tool installation
│   └── versions.sh      # Core and fallback binary pins
└── tests/               # Installer and hook checks
```
