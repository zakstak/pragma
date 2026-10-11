#!/usr/bin/env bash
# Exercise the compiler installer with checksum-pinned local release fixtures.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRAGMA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PRAGMA_DIR/tools/versions.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
fixture="$tmp_dir/pragma"
project="$tmp_dir/project"
mock_bin="$tmp_dir/mocks"
mkdir -p "$fixture/bin" "$project" "$mock_bin"
cp -R "$PRAGMA_DIR/lib" "$PRAGMA_DIR/tools" "$fixture/"
git -C "$project" init -q
printf '{"private":true}\n' >"$project/package.json"
for tool in prek kingfisher prettier oxlint; do
  printf '#!/bin/sh\nexit 0\n' >"$mock_bin/$tool"
  chmod +x "$mock_bin/$tool"
done
# A correctly named system compiler must never satisfy the owned pin.
printf '#!/bin/sh\nprintf "Version 7.1.0-dev\\n"\n' >"$mock_bin/tsc-rs"
chmod +x "$mock_bin/tsc-rs"
cat >"$mock_bin/curl" <<'SH'
#!/bin/sh
[ "${TEST_FAIL_CURL:-0}" != 1 ] || exit 22
url= destination=
while [ "$#" -gt 0 ]; do
  case "$1" in
    https:*) url=$1 ;;
    -o) shift; destination=$1 ;;
  esac
  shift
done
printf '%s\n' "$url" >>"$TEST_DOWNLOAD_LOG"
cp "$TEST_ARCHIVE" "$destination"
SH
cat >"$mock_bin/uname" <<'SH'
#!/bin/sh
case "$1" in
  -s) printf '%s\n' "${TEST_OS:-Linux}" ;;
  -m) printf '%s\n' "${TEST_ARCH:-x86_64}" ;;
  *) /usr/bin/uname "$@" ;;
esac
SH
cat >"$mock_bin/mv" <<'SH'
#!/bin/sh
if [ "${TEST_FAIL_WRAPPER_MOVE:-0}" = 1 ]; then
  case "$1" in */.tsc-rs-install.*/wrapper) exit 1 ;; esac
fi
exec /bin/mv "$@"
SH
chmod +x "$mock_bin/curl" "$mock_bin/uname" "$mock_bin/mv"
export TEST_DOWNLOAD_LOG="$tmp_dir/downloads.log"
export PRAGMA_GLOBAL_BIN_DIR="$mock_bin"
export PATH="$mock_bin:$PATH"
touch "$TEST_DOWNLOAD_LOG"

archive_fixture() {
  local platform="$1" kind="${2:-valid}" root
  root="tsc-rs-$TSC_RS_VERSION-$platform"
  rm -rf "$tmp_dir/archive"
  mkdir -p "$tmp_dir/archive/$root"
  cat >"$tmp_dir/archive/$root/tsc" <<'SH'
#!/bin/sh
dir=${0%/*}
[ -f "$dir/lib.es5.d.ts" ] || exit 70
printf 'Version 7.1.0-dev\n'
SH
  chmod +x "$tmp_dir/archive/$root/tsc"
  printf 'standard library\n' >"$tmp_dir/archive/$root/lib.es5.d.ts"
  printf 'second library\n' >"$tmp_dir/archive/$root/lib.dom.d.ts"
  printf 'license\n' >"$tmp_dir/archive/$root/LICENSE"
  printf 'notices\n' >"$tmp_dir/archive/$root/NOTICE.txt"
  case "$kind" in
    missing-library) rm "$tmp_dir/archive/$root/lib.es5.d.ts" ;;
    wrong-version) printf '#!/bin/sh\nprintf "Version 6.0.3\\n"\n' >"$tmp_dir/archive/$root/tsc" ;;
    wrong-layout)
      mv "$tmp_dir/archive/$root" "$tmp_dir/archive/unexpected"
      root=unexpected
      ;;
  esac
  export TEST_ARCHIVE="$tmp_dir/$platform-$kind.tar.gz"
  tar -czf "$TEST_ARCHIVE" -C "$tmp_dir/archive" "$root"
  # Replace only the committed digests in this disposable installer copy. The
  # production installer continues using all four real release checksums.
  python3 - "$PRAGMA_DIR/tools/install-tools.sh" "$fixture/tools/install-tools.sh" "$TEST_ARCHIVE" <<'PY'
import hashlib
import pathlib
import re
import sys

source, target, archive = map(pathlib.Path, sys.argv[1:])
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
text = source.read_text()
start = text.index("tsc_rs_archive_sha256()")
end = text.index("tsc_rs_install_name()", start)
text = text[:start] + re.sub(r"'[0-9a-f]{64}'", repr(digest), text[start:end]) + text[end:]
target.write_text(text)
PY
}

install_fixture() {
  (cd "$project" && /bin/bash "$fixture/tools/install-tools.sh" --agent "$@") >"$tmp_dir/output" 2>&1 || {
    cat "$tmp_dir/output"
    return 1
  }
}

assert_failed_install_preserves_pin() {
  local label="$1" previous before after
  previous="$fixture/bin/tsc-rs-$TSC_RS_VERSION-linux-x64"
  before="$(checksum_files "$fixture/bin/tsc-rs" "$previous/tsc" "$previous/receipt.json" "$previous/lib.es5.d.ts")"
  if install_fixture --update >"$tmp_dir/failed-output"; then
    printf 'FAIL: %s unexpectedly succeeded\n' "$label"
    cat "$tmp_dir/output"
    exit 1
  fi
  after="$(checksum_files "$fixture/bin/tsc-rs" "$previous/tsc" "$previous/receipt.json" "$previous/lib.es5.d.ts")"
  [[ "$before" == "$after" ]]
  [[ "$("$fixture/bin/tsc-rs" --version)" == 'Version 7.1.0-dev' ]]
  cmp "$fixture/bin/tsc-rs.receipt.json" "$previous/receipt.json"
  [[ -z "$(find "$fixture/bin" -name '.tsc-rs-install.*' -print)" ]]
  printf 'PASS: %s preserves the previous compiler and receipt\n' "$label"
}

checksum_files() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}

archive_fixture linux-x64
install_fixture
grep -q 'tsc-rs is missing' "$tmp_dir/output"
[[ -x "$fixture/bin/tsc-rs" && ! -e "$fixture/bin/tsc" ]]
[[ "$("$fixture/bin/tsc-rs" --version)" == 'Version 7.1.0-dev' ]]
python3 - "$fixture/bin/tsc-rs.receipt.json" "$TSC_RS_SOURCE_COMMIT" "$TEST_ARCHIVE" <<'PY'
import hashlib
import json
import pathlib
import sys

receipt_path, commit, archive = sys.argv[1:]
receipt = json.loads(pathlib.Path(receipt_path).read_text())
assert receipt["version"] == "0.3.0"
assert receipt["typescript_version"] == "7.1.0-dev"
assert receipt["source_commit"] == commit
assert receipt["platform"] == "linux-x64"
assert receipt["archive_sha256"] == hashlib.sha256(pathlib.Path(archive).read_bytes()).hexdigest()
assert receipt["url"].endswith("/v0.3.0/tsc-rs-0.3.0-linux-x64.tar.gz")
assert len(receipt["binary_sha256"]) == 64
PY
printf 'PASS: TypeScript detection installs the owned compiler and complete library with provenance\n'
before="$(wc -l <"$TEST_DOWNLOAD_LOG")"
install_fixture
[[ "$(wc -l <"$TEST_DOWNLOAD_LOG")" == "$before" ]]
grep -q 'tsc-rs is available' "$tmp_dir/output"
printf 'PASS: a valid owned pin is reused without downloading\n'
printf 'corrupted\n' >"$fixture/bin/tsc-rs-$TSC_RS_VERSION-linux-x64/lib.dom.d.ts"
install_fixture
[[ "$(cat "$fixture/bin/tsc-rs-$TSC_RS_VERSION-linux-x64/lib.dom.d.ts")" == 'second library' ]]
printf 'PASS: corrupt installed library files trigger repair\n'

export PRAGMA_INSTALL_ONLY_TOOLS=tsc-rs
export TEST_FAIL_CURL=1
assert_failed_install_preserves_pin 'download failure'
unset TEST_FAIL_CURL
printf 'corrupt archive\n' >"$TEST_ARCHIVE"
assert_failed_install_preserves_pin 'checksum mismatch'
grep -q 'Checksum mismatch' "$tmp_dir/output"
for kind in wrong-layout missing-library wrong-version; do
  archive_fixture linux-x64 "$kind"
  assert_failed_install_preserves_pin "$kind"
done
archive_fixture linux-x64
export TEST_FAIL_WRAPPER_MOVE=1
assert_failed_install_preserves_pin 'wrapper publication failure'
unset TEST_FAIL_WRAPPER_MOVE

# All Pragma-supported platform mappings select the upstream Node-style name.
for platform in linux-arm64 darwin-x64 darwin-arm64; do
  case "$platform" in
    linux-arm64) export TEST_OS=Linux TEST_ARCH=aarch64 ;;
    darwin-x64) export TEST_OS=Darwin TEST_ARCH=x86_64 ;;
    darwin-arm64) export TEST_OS=Darwin TEST_ARCH=arm64 ;;
  esac
  archive_fixture "$platform"
  install_fixture --update
  [[ -f "$fixture/bin/tsc-rs-$TSC_RS_VERSION-$platform/lib.es5.d.ts" ]]
  tail -n 1 "$TEST_DOWNLOAD_LOG" | grep -q "tsc-rs-$TSC_RS_VERSION-$platform.tar.gz"
  printf 'PASS: %s installs the correct complete archive\n' "$platform"
done
unset TEST_OS TEST_ARCH PRAGMA_INSTALL_ONLY_TOOLS

before="$(wc -l <"$TEST_DOWNLOAD_LOG")"
PRAGMA_SHADOW=0 install_fixture
[[ "$(wc -l <"$TEST_DOWNLOAD_LOG")" == "$before" ]]
if grep -q 'tsc-rs is' "$tmp_dir/output"; then exit 1; fi
git -C "$project" config pragma.shadow false
install_fixture
[[ "$(wc -l <"$TEST_DOWNLOAD_LOG")" == "$before" ]]
if grep -q 'tsc-rs is' "$tmp_dir/output"; then exit 1; fi
printf 'PASS: environment and repository opt-outs avoid shadow installation\n'
if PRAGMA_SHADOW=invalid install_fixture >/dev/null; then exit 1; fi
grep -q 'PRAGMA_SHADOW must be' "$tmp_dir/output"
git -C "$project" config pragma.shadow invalid
if install_fixture >/dev/null; then exit 1; fi
grep -q 'pragma.shadow must be' "$tmp_dir/output"
printf 'PASS: invalid environment and repository shadow settings fail explicitly\n'
git -C "$project" config --unset pragma.shadow
install_fixture --global
[[ "$(wc -l <"$TEST_DOWNLOAD_LOG")" == "$before" ]]
if grep -q 'tsc-rs is' "$tmp_dir/output"; then exit 1; fi
printf 'PASS: --global installs only core tools\n'
[[ "$(cat "$project/package.json")" == '{"private":true}' ]]
[[ ! -e "$project/package-lock.json" && ! -e "$project/node_modules" ]]
printf 'PASS: the installer never changes project package declarations or locks\n'
