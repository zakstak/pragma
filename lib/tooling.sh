#!/usr/bin/env bash
# Shared tool ownership and project selection for installers and hooks.

pragma_global_bin_dir() {
  printf '%s\n' "${PRAGMA_GLOBAL_BIN_DIR:-$HOME/.local/bin}"
}

pragma_is_core_tool() {
  [[ "$1" == prek || "$1" == kingfisher ]]
}

pragma_project_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

# Go's tool directive owns both the package and its version.
pragma_go_tool_package() {
  local package dir root
  case "$1" in
    goimports) package=golang.org/x/tools/cmd/goimports ;;
    golangci-lint) package=github.com/golangci/golangci-lint/v2/cmd/golangci-lint ;;
    *) return 1 ;;
  esac
  dir="$(pwd)"
  root="$(pragma_project_root)"
  while [[ ! -f "$dir/go.mod" && "$dir" != "$root" && "$dir" != / ]]; do
    dir="$(dirname "$dir")"
  done
  [[ -f "$dir/go.mod" ]] || return 1
  awk -v package="$package" '
    { sub(/\/\/.*$/, ""); gsub(/"/, "") }
    $1 == "tool" && $2 == "(" { block = 1; next }
    block && $1 == ")" { block = 0; next }
    $1 == "tool" && $2 == package { found = 1 }
    block && $1 == package { found = 1 }
    END { exit !found }
  ' "$dir/go.mod" || return 1
  printf '%s\n' "$package"
}

# 0: installed project tool; 1: no project selection; 2: declared but unavailable.
pragma_project_tool_path() {
  local tool="$1" root candidate
  case "$tool" in
    prettier | oxlint | python | pytest | ruff | yamllint) root="$(pragma_project_root)" ;;
    *) return 1 ;;
  esac
  case "$tool" in
    prettier | oxlint)
      candidate="$root/node_modules/.bin/$tool"
      if [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      [[ -f "$root/package.json" ]] || return 1
      command -v node >/dev/null 2>&1 || return 2
      node -e '
        const fs = require("node:fs");
        try {
          const pkg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
          const tool = process.argv[2];
          const declared = ["dependencies", "devDependencies", "optionalDependencies"]
            .some(key => Object.hasOwn(pkg[key] || {}, tool));
          process.exit(declared ? 2 : 1);
        } catch { process.exit(2); }
      ' "$root/package.json" "$tool"
      ;;
    python | pytest | ruff | yamllint)
      [[ "$root" != "$(pragma_dir)" ]] || return 1
      candidate="${UV_PROJECT_ENVIRONMENT:-$root/.venv}"
      [[ "$candidate" == /* ]] || candidate="$root/$candidate"
      candidate="$candidate/bin/$tool"
      [[ -x "$candidate" ]] || return 1
      printf '%s\n' "$candidate"
      ;;
    *) return 1 ;;
  esac
}

pragma_tool_path() {
  local tool="$1" candidate status
  if [[ "$tool" == tsc-rs ]]; then
    candidate="$(pragma_dir)/bin/tsc-rs"
    [[ -x "$candidate" ]] || return 1
    printf '%s\n' "$candidate"
    return 0
  fi
  if [[ "${PRAGMA_SKIP_INTERNAL_BIN_PATH:-0}" != 1 ]]; then
    if pragma_is_core_tool "$tool"; then
      candidate="$(pragma_global_bin_dir)/$tool"
      if [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  fi
  if candidate="$(pragma_project_tool_path "$tool")"; then
    printf '%s\n' "$candidate"
    return 0
  else
    status=$?
    [[ $status != 2 ]] || return 2
  fi
  candidate="$(command -v "$tool")" || return 1
  # Ignore an obsolete shared CLI when a supported fallback is installed.
  if [[ "$tool" == golangci-lint && -x "$(pragma_dir)/bin/$tool" ]]; then
    local version
    version="$("$candidate" version --short 2>/dev/null)" || version=''
    if [[ "$version" != v2.* && "$version" != 2.* ]]; then
      candidate="$(pragma_dir)/bin/$tool"
    fi
  fi
  printf '%s\n' "$candidate"
}

# Resolve every invocation again after callers change module directories.
pragma_exec() {
  local tool="$1" package path
  shift
  if package="$(pragma_go_tool_package "$tool")"; then
    command go tool "$package" "$@"
    return $?
  fi
  case "$tool" in
    prek | kingfisher | prettier | oxlint | python | pytest | ruff | yamllint | golangci-lint | tsc-rs)
      path="$(pragma_tool_path "$tool")" || {
        printf 'Cannot resolve %s; install the project dependencies or Pragma fallback tools.\n' "$tool" >&2
        return 1
      }
      "$path" "$@"
      ;;
    *) "$tool" "$@" ;;
  esac
}
