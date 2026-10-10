#!/usr/bin/env bash
# Exercise committed wrappers across moved checkouts and independent clones.
set -euo pipefail

PRAGMA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

stub_bin="$tmp_dir/stubs"
pragma_copy="$tmp_dir/pragma copy"
repo_dir="$tmp_dir/repo"
mkdir -p "$stub_bin" "$pragma_copy" "$repo_dir"
cp -R "$PRAGMA_DIR/lib" "$PRAGMA_DIR/tools" "$pragma_copy/"
cp "$PRAGMA_DIR/install.sh" "$PRAGMA_DIR/kingfisher.yaml" "$pragma_copy/"
for tool in prek kingfisher; do
  printf '#!/bin/sh\nexit 0\n' >"$stub_bin/$tool"
  chmod +x "$stub_bin/$tool"
done
export PATH="$stub_bin:$PATH"
git init -q "$repo_dir"
bash "$pragma_copy/install.sh" --agent "$repo_dir" >/dev/null

# Use a visible marker to prove which checkout the generated wrapper executes.
printf '#!/bin/sh\nprintf "first-checkout\\n"\n' >"$pragma_copy/lib/format.sh"
cp "$repo_dir/.pragma-hooks/format.sh" "$tmp_dir/original-wrapper"
(cd "$repo_dir" && test "$(.pragma-hooks/format.sh)" = first-checkout)
printf 'PASS: wrappers resolve the local Git setting\n'

moved_pragma="$tmp_dir/moved pragma"
mv "$pragma_copy" "$moved_pragma"
git -C "$repo_dir" config --local pragma.home "$moved_pragma"
(cd "$repo_dir" && test "$(.pragma-hooks/format.sh)" = first-checkout)
cmp "$tmp_dir/original-wrapper" "$repo_dir/.pragma-hooks/format.sh"
printf 'PASS: checkout relocation requires no wrapper changes\n'

second_pragma="$tmp_dir/second pragma"
cp -R "$moved_pragma" "$second_pragma"
printf '#!/bin/sh\nprintf "second-checkout\\n"\n' >"$second_pragma/lib/format.sh"
(cd "$repo_dir" && test "$(PRAGMA_HOME="$second_pragma" .pragma-hooks/format.sh)" = second-checkout)
printf 'PASS: PRAGMA_HOME overrides the local Git setting\n'

home_dir="$tmp_dir/home"
mkdir -p "$home_dir"
cp -R "$second_pragma" "$home_dir/.pragma"
git -C "$repo_dir" config --local --unset pragma.home
(cd "$repo_dir" && test "$(HOME="$home_dir" .pragma-hooks/format.sh)" = second-checkout)
printf 'PASS: wrappers fall back to the current users home\n'

other_repo="$tmp_dir/independent clone"
mkdir -p "$other_repo"
git init -q "$other_repo"
bash "$moved_pragma/install.sh" --agent "$other_repo" >/dev/null
cmp "$repo_dir/prek.toml" "$other_repo/prek.toml"
cmp "$repo_dir/.pragma-hooks/format.sh" "$other_repo/.pragma-hooks/format.sh"
printf 'PASS: independent clones generate identical configuration\n'

if (cd "$repo_dir" && PRAGMA_HOME="$tmp_dir/missing" .pragma-hooks/format.sh >"$tmp_dir/missing.log" 2>&1); then
  printf 'FAIL: missing checkout unexpectedly succeeded\n'
  exit 1
fi
grep -Fq 'Set PRAGMA_HOME or rerun install.sh.' "$tmp_dir/missing.log"
printf 'PASS: missing checkouts produce an actionable error\n'
