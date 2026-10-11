#!/usr/bin/env bash
# Exercise real rustfmt with package, inherited workspace, and standalone editions.
set -euo pipefail
PRAGMA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v rustfmt >/dev/null || {
  printf 'Missing integration-test dependency: rustfmt\n' >&2
  exit 1
}
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
TEST_REAL_RUSTFMT="$(command -v rustfmt)"
export TEST_REAL_RUSTFMT
export TEST_RUSTFMT_ARGS="$tmp_dir/rustfmt.args"
mkdir -p "$tmp_dir/bin" "$tmp_dir/project/src"
cat >"$tmp_dir/bin/rustfmt" <<'TOOL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_RUSTFMT_ARGS"
exec "$TEST_REAL_RUSTFMT" "$@"
TOOL
cat >"$tmp_dir/bin/cargo" <<'TOOL'
#!/bin/sh
printf 'Unexpected cargo formatting fallback\n' >&2
exit 97
TOOL
chmod +x "$tmp_dir/bin/rustfmt" "$tmp_dir/bin/cargo"
export PATH="$tmp_dir/bin:$PATH"
export PRAGMA_SKIP_INTERNAL_BIN_PATH=1 PRAGMA_OUTPUT_FORMAT=gpt
cd "$tmp_dir/project"
git init -q
cat >Cargo.toml <<'MANIFEST'
[package]
name = "modern"
version = "0.1.0"
edition = '2024' # Single-quoted TOML is valid too.
MANIFEST
cat >src/lib.rs <<'RUST'
mod child;
pub fn answer() {if let Some(value) = Some(42) && value > 0 {println!("{value}");}}
RUST
printf 'pub fn child() {println!("child");}\n' >src/child.rs
git add .
index_before="$(git write-tree)"
bash "$PRAGMA_DIR/lib/format.sh" src/lib.rs src/child.rs
first_diff="$(git diff)"
[[ -n "$first_diff" ]]
bash "$PRAGMA_DIR/lib/format.sh" src/lib.rs src/child.rs
[[ "$(git diff)" == "$first_diff" && "$(git write-tree)" == "$index_before" ]]
grep -Fq -- '--edition 2024' "$TEST_RUSTFMT_ARGS"
printf 'PASS: edition 2024 let-chains and child modules reach stable formatting without changing the index\n'

mkdir -p "$tmp_dir/workspace/modern/src" "$tmp_dir/workspace/legacy/src" "$tmp_dir/workspace/implicit/src" "$tmp_dir/workspace/nested/src"
cd "$tmp_dir/workspace"
git init -q
cat >Cargo.toml <<'MANIFEST'
[workspace]
members = ["modern", "legacy", "implicit"]
exclude = ["nested"]
resolver = "3"
[workspace.package]
edition = "2024"
MANIFEST
cat >modern/Cargo.toml <<'MANIFEST'
[package]
name = "inherited"
version = "0.1.0"
[package.edition]
workspace = true
MANIFEST
cp "$tmp_dir/project/src/lib.rs" modern/src/lib.rs
cp "$tmp_dir/project/src/child.rs" modern/src/child.rs
cat >legacy/Cargo.toml <<'MANIFEST'
[package]
name = "legacy"
version = "0.1.0"
edition = "2021"
MANIFEST
printf 'pub async fn legacy() { }\n' >legacy/src/lib.rs
cat >implicit/Cargo.toml <<'MANIFEST'
[package]
name = "implicit"
version = "0.1.0"
MANIFEST
printf 'pub fn implicit() { }\n' >implicit/src/lib.rs
cat >nested/Cargo.toml <<'MANIFEST'
[package]
name = "nested"
version = "0.1.0"
edition = "2018"
MANIFEST
printf 'pub async fn nested() { }\n' >nested/src/lib.rs
: >"$TEST_RUSTFMT_ARGS"
git add .
index_before="$(git write-tree)"
bash "$PRAGMA_DIR/lib/format.sh" modern/src/lib.rs legacy/src/lib.rs implicit/src/lib.rs nested/src/lib.rs
first_diff="$(git diff)"
bash "$PRAGMA_DIR/lib/format.sh" modern/src/lib.rs legacy/src/lib.rs implicit/src/lib.rs nested/src/lib.rs
[[ "$(git diff)" == "$first_diff" && "$(git write-tree)" == "$index_before" ]]
for edition in 2015 2018 2021 2024; do
  grep -Fq -- "--edition $edition" "$TEST_RUSTFMT_ARGS"
done
printf 'PASS: workspace inheritance, nested crates, and Cargo default editions are formatted separately and stay stable\n'
# Also cover dotted and inline inheritance forms accepted by Cargo.
for declaration in 'edition.workspace = true' 'edition = { workspace = true }'; do
  printf '[package]\nname = "inherited"\nversion = "0.1.0"\n%s\n' "$declaration" >modern/Cargo.toml
  bash "$PRAGMA_DIR/lib/format.sh" modern/src/lib.rs
  [[ "$(git write-tree)" == "$index_before" ]]
done
printf 'PASS: dotted and inline workspace inheritance select edition 2024\n'

mkdir -p "$tmp_dir/standalone"
cd "$tmp_dir/standalone"
git init -q
printf 'pub async fn standalone() { }\n' >standalone.rs
: >"$TEST_RUSTFMT_ARGS"
bash "$PRAGMA_DIR/lib/format.sh" standalone.rs
grep -Fq -- '--edition 2021' "$TEST_RUSTFMT_ARGS"
printf 'PASS: standalone Rust files retain edition 2021\n'

# A package can inherit from a workspace that is not its directory ancestor.
mkdir -p "$tmp_dir/external/src"
cd "$tmp_dir/external"
git init -q
cat >Cargo.toml <<'MANIFEST'
[package]
name = "external"
version = "0.1.0"
workspace = "../workspace"
edition.workspace = true
MANIFEST
cp "$tmp_dir/project/src/lib.rs" src/lib.rs
cp "$tmp_dir/project/src/child.rs" src/child.rs
: >"$TEST_RUSTFMT_ARGS"
bash "$PRAGMA_DIR/lib/format.sh" src/lib.rs
grep -Fq -- '--edition 2024' "$TEST_RUSTFMT_ARGS"
printf 'PASS: explicit workspace paths resolve inherited editions\n'
# Invalid inheritance must fail before any edition-dependent changes occur.
sed 's#../workspace#../standalone#' Cargo.toml >Cargo.next
mv Cargo.next Cargo.toml
: >"$TEST_RUSTFMT_ARGS"
if bash "$PRAGMA_DIR/lib/format.sh" src/lib.rs >"$tmp_dir/invalid.log" 2>&1; then
  printf 'FAIL: unresolved workspace edition was accepted\n'
  exit 1
fi
[[ ! -s "$TEST_RUSTFMT_ARGS" ]]
grep -Fq 'cannot resolve Rust edition' "$tmp_dir/invalid.log"
printf 'PASS: unresolved workspace editions fail before formatting\n'
