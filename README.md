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

# Dogfood pragma on this repo itself
./install.sh --agent .
```

Bootstrap expects the target to already be a Git repository.

`install.sh` also needs `lefthook` to be available before it can install the
hooks. If `lefthook` is not already on your `PATH`, either:

- install it yourself first (for example `brew install lefthook`,
  `go install github.com/evilmartians/lefthook@latest`, or
  `nix-env -iA nixpkgs.lefthook`), or
- run `install.sh --agent ...` on a machine with `go` or `nix-env` available so
  Pragma can install `lefthook` for you.

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

| Mode            | Flag        | Behavior                                  |
| --------------- | ----------- | ----------------------------------------- |
| **Interactive** | _(default)_ | Colored output, prompts for missing tools |
| **Agent**       | `--agent`   | Silent unless errors, auto-installs tools |

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
```

Binaries are placed in `~/.pragma/bin/` (or `<your-clone>/bin/`) and
automatically added to PATH by the hooks.

Some tools still rely on package managers:

- `prettier` and `eslint` use `npm` or `bun`
- `yamllint` uses `pip`, `pip3`, `pipx`, `uv`, or `python3`

Binary downloads require `curl`, and archive extraction may also need `tar`,
`gunzip`, or `unzip` depending on the tool.

## Repo Structure

```
pragma/
├── install.sh           # Bootstrap entrypoint
├── lefthook.yml         # Repo-local config for pragma itself
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
