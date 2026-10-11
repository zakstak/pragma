#!/usr/bin/env bash
# Check ownership boundaries with distinct project, active, and fallback tools.
set -euo pipefail
PRAGMA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
copy="$tmp_dir/pragma"
repo="$tmp_dir/project with spaces"
active="$tmp_dir/active"
export PRAGMA_GLOBAL_BIN_DIR="$tmp_dir/global"
mkdir -p "$copy/bin" "$repo/node_modules/.bin" "$repo/.venv/bin" "$active" "$PRAGMA_GLOBAL_BIN_DIR"
cp -R "$PRAGMA_DIR/lib" "$PRAGMA_DIR/tools" "$copy/"
cp "$PRAGMA_DIR/.golangci.yml" "$copy/"
git init -q "$repo"
marker_tool() {
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$2" >"$1"
  chmod +x "$1"
}
for tool in prek kingfisher; do
  marker_tool "$PRAGMA_GLOBAL_BIN_DIR/$tool" "global-$tool"
  marker_tool "$copy/bin/$tool" "old-$tool"
done
for tool in prettier eslint ruff pytest yamllint python golangci-lint; do
  marker_tool "$active/$tool" "active-$tool"
  marker_tool "$copy/bin/$tool" "fallback-$tool"
done
marker_tool "$repo/node_modules/.bin/prettier" project-prettier
marker_tool "$repo/node_modules/.bin/eslint" project-eslint
for tool in ruff pytest yamllint python; do
  marker_tool "$repo/.venv/bin/$tool" "project-$tool"
done
export PATH="$active:$PATH"
cd "$repo"
source "$copy/lib/common.sh"
for tool in prek kingfisher; do
  [[ "$(pragma_exec "$tool")" == "global-$tool" ]]
done
printf 'PASS: global core overrides old checkout binaries\n'
for tool in prettier eslint ruff pytest yamllint python; do
  [[ "$(pragma_exec "$tool")" == "project-$tool" ]]
done
printf 'PASS: project npm and Python tools precede active and fallback versions\n'
(cd node_modules && [[ "$(pragma_exec prettier)" == project-prettier ]])
printf 'PASS: project tools resolve from nested directories\n'
mkdir -p "$repo/custom-env/bin"
marker_tool "$repo/custom-env/bin/ruff" custom-ruff
[[ "$(UV_PROJECT_ENVIRONMENT=custom-env pragma_exec ruff)" == custom-ruff ]]
printf 'PASS: custom uv project environment is respected\n'
printf '{"devDependencies":{"prettier":"3.0.0","eslint":"9.0.0"}}\n' >package.json
output="$(PRAGMA_INSTALL_ONLY_TOOLS='prettier eslint ruff' bash "$copy/tools/install-tools.sh" --agent --update)"
[[ "$output" == *'uses the project selection'* ]]
[[ "$(pragma_exec prettier)" == project-prettier ]]
printf 'PASS: update preserves project selections without fallback installation\n'
rm node_modules/.bin/prettier
if pragma_exec prettier >"$tmp_dir/missing.log" 2>&1; then
  printf 'FAIL: missing declared prettier used another version\n'
  exit 1
fi
if PRAGMA_INSTALL_ONLY_TOOLS=prettier bash "$copy/tools/install-tools.sh" --agent >"$tmp_dir/install.log" 2>&1; then
  printf 'FAIL: installer replaced a missing declared project tool\n'
  exit 1
fi
rg -q 'dependencies first' "$tmp_dir/install.log"
printf 'PASS: missing declared npm tools fail instead of using fallback versions\n'
printf '{}\n' >package.json
[[ "$(pragma_exec prettier)" == active-prettier ]]
rm "$active/prettier"
rm package.json
[[ "$(PATH="$copy/bin" pragma_exec prettier)" == fallback-prettier ]]
printf 'PASS: active PATH precedes the shared fallback for unselected tools\n'
mkdir -p nested
cat >nested/go.mod <<'MOD'
module example.com/project

go 1.24

tool (
  golang.org/x/tools/cmd/goimports
  github.com/golangci/golangci-lint/v2/cmd/golangci-lint
)
MOD
cat >"$active/go" <<'GO'
#!/bin/sh
if [ "$1" = tool ] && [ "$3" = version ]; then
  printf '2.14.0\n'
else
  printf 'module-tool:%s:%s\n' "$PWD" "$*"
  printf 'module-tool:%s:%s\n' "$PWD" "$*" >>"${TEST_GO_CAPTURE:-/dev/null}"
  [ "${TEST_GO_TOOL_FAIL:-0}" != 1 ] || exit 1
fi
GO
chmod +x "$active/go"
(cd nested && [[ "$(pragma_exec goimports -w file.go)" == "module-tool:$repo/nested:tool golang.org/x/tools/cmd/goimports -w file.go" ]] && golangci_is_v2)
printf 'PASS: Go module tools select project versions in the module directory\n'
(cd nested && PRAGMA_INSTALL_ONLY_TOOLS='goimports golangci-lint' bash "$copy/tools/install-tools.sh" --agent --update >"$tmp_dir/go-install.log")
rg -q 'uses the project selection' "$tmp_dir/go-install.log"
printf 'PASS: update leaves Go module tools to the project\n'
printf 'package project\n' >nested/file.go
TEST_GO_CAPTURE="$tmp_dir/go-calls" bash "$copy/lib/format.sh" nested/file.go
TEST_GO_CAPTURE="$tmp_dir/go-calls" bash "$copy/lib/lint.sh" nested/file.go
rg -q "module-tool:$repo/nested:tool golang.org/x/tools/cmd/goimports -w ../nested/file.go" "$tmp_dir/go-calls"
rg -q "module-tool:$repo/nested:tool github.com/golangci/golangci-lint/v2/cmd/golangci-lint run" "$tmp_dir/go-calls"
printf 'PASS: formatting and linting invoke nested module tool selections\n'
if TEST_GO_TOOL_FAIL=1 bash "$copy/lib/format.sh" nested/file.go >"$tmp_dir/go-failure.log"; then
  printf 'FAIL: project Go tool failure was ignored\n'
  exit 1
fi
rg -q '"tool":"goimports"' "$tmp_dir/go-failure.log"
printf 'PASS: project Go formatter errors retain hook diagnostics\n'
# A core-only install must need neither project dependencies nor local tool dirs.
rm -rf "${copy:?}/bin"
output="$(bash "$copy/tools/install-tools.sh" --global --agent)"
[[ "$output" == *'All tools are installed'* && ! -d "$copy/bin" ]]
printf 'PASS: core-only installation creates no checkout tooling artifacts\n'
if PRAGMA_INSTALL_ONLY_TOOLS=ruff bash "$copy/tools/install-tools.sh" --global --agent >"$tmp_dir/core.log" 2>&1; then
  printf 'FAIL: global mode installed a language tool\n'
  exit 1
fi
printf 'PASS: global mode rejects language tools\n'
