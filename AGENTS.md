# Pragma

Pragma owns shared Git hooks, tool selection, pinned tool installation, and
compiler comparison helpers for Linux and macOS. Target repositories own their
application code, dependencies, and project-specific hook policy.

These instructions guide development agents only. Do not inject this file or
other repository instructions into an application's runtime chat prompts.

## Scope and implementation

- Read the relevant hook, installer path, and fixture tests before editing. Keep
  runtime hooks, generated wrappers, `prek.toml`, tests, and README behavior
  consistent.
- Treat this as greenfield code. Update callers and remove obsolete behavior
  together. Do not add compatibility shims, deprecated aliases, or migration
  paths for retired tools.
- Preserve unrelated changes. Use a separate worktree when the checkout is
  dirty, and respect existing thread ownership guards.
- Keep shell code compatible with Bash 3.2 and macOS system utilities. Avoid
  Linux-only commands in shared paths unless platform dispatch selects them.
- Resolve tools through the existing helpers. Prefer project selections, then
  the active PATH, then Pragma fallbacks. Preserve project dependency manifests
  and lockfiles during bootstrap.
- Keep tool versions and dependency locks in the existing versioned manifests.
  Preserve checksum verification and explicit failures for unsupported hosts or
  missing required tools.

## Index and artifact policy

- Commit checks inspect the proposed Git index. Unstaged content must not change
  their decisions. Hooks must leave index entries and contents unchanged.
- Handle unborn repositories, linked worktrees, alternate indexes, spaces, and
  newlines in filenames. Preserve the repository's object format.
- Keep build outputs, caches, downloaded binaries, models, and local receipts
  out of commits. Standard lockfiles and Pragma hook configuration are source
  inputs.
- Generated-artifact exceptions belong in staged `.gitattributes`. Keep them
  narrow and explain their purpose. Machine-local settings must not bypass the
  check. Document recognition limits instead of claiming complete provenance
  detection.

## Safe experiments and checks

Use disposable repositories and synthetic fixtures. For bootstrap experiments,
follow the README's disposable-install workflow with a fresh clone, an empty
repository, and a temporary `PRAGMA_GLOBAL_BIN_DIR` placed first on PATH.
Missing Rust components still use the existing rustup installation.

Never copy a checkout's `.git` file into a fixture. Create independent fixture
Git metadata and seed a fixture commit when history is needed. Check that tests
leave the source index and unrelated worktrees unchanged.

For behavior changes, run `tools/check.sh` with the required tools available.
Add focused regression coverage for changed behavior and exercise the actual
commit or push path when hook wiring changes. For documentation-only changes,
run the relevant formatting checks. State platform coverage and any blocked
checks accurately.

## Delivery

Use a feature branch and pull request. A source change does not update installed
Pragma copies or target repositories automatically. Identify which checkout was
tested, distinguish published source from local installation, and document any
required hook regeneration. Preserve project-specific hooks when bootstrapping
an existing repository.
