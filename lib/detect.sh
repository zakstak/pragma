#!/usr/bin/env bash
# detect.sh — Language detection for pragma
#
# Two modes:
#   detect_from_files <file-list>   — detect languages from a list of files (pre-commit)
#   detect_from_repo                — detect languages from repo markers (pre-push)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ─── Detection from file list (staged files) ─────────────────────────────────

detect_from_files() {
  local files="$1"
  local langs=()

  # Normalize: convert spaces to newlines for grep matching
  local file_lines
  file_lines=$(echo "$files" | tr ' ' '\n')

  # Go
  if echo "$file_lines" | grep -qE '\.go$'; then
    langs+=("go")
  fi

  # Rust
  if echo "$file_lines" | grep -qE '\.rs$'; then
    langs+=("rust")
  fi

  # TypeScript / JavaScript
  if echo "$file_lines" | grep -qE '\.(ts|tsx|js|jsx)$'; then
    langs+=("typescript")
  fi

  # HTML
  if echo "$file_lines" | grep -qE '\.html?$'; then
    langs+=("html")
  fi

  # YAML
  if echo "$file_lines" | grep -qE '\.(yml|yaml)$'; then
    langs+=("yaml")
  fi

  # Docker
  if echo "$file_lines" | grep -qiE '(Dockerfile|\.dockerfile)$'; then
    langs+=("docker")
  fi

  # Shell
  if echo "$file_lines" | grep -qE '\.sh$'; then
    langs+=("shell")
  fi

  # Markdown
  if echo "$file_lines" | grep -qE '\.md$'; then
    langs+=("markdown")
  fi

  # TOML
  if echo "$file_lines" | grep -qE '\.toml$'; then
    langs+=("toml")
  fi

  # JSON
  if echo "$file_lines" | grep -qE '\.json$'; then
    langs+=("json")
  fi

  # Python
  if echo "$file_lines" | grep -qE '\.py$'; then
    langs+=("python")
  fi

  # Deduplicate and print
  printf '%s\n' "${langs[@]}" | sort -u
}

# ─── Detection from repo markers (full repo scan) ────────────────────────────

detect_from_repo() {
  local langs=()

  # Go
  if [[ -f "go.mod" ]] || find . -maxdepth 3 -name '*.go' -print -quit 2>/dev/null | grep -q .; then
    langs+=("go")
  fi

  # Rust
  if [[ -f "Cargo.toml" ]] || find . -maxdepth 3 -name '*.rs' -print -quit 2>/dev/null | grep -q .; then
    langs+=("rust")
  fi

  # TypeScript
  if [[ -f "tsconfig.json" ]] || (
    [[ -f "package.json" ]] && grep -qE '"typescript"' package.json 2>/dev/null
  ); then
    langs+=("typescript")
  fi

  # HTML
  if find . -maxdepth 3 -name '*.html' -print -quit 2>/dev/null | grep -q .; then
    langs+=("html")
  fi

  # YAML
  if find . -maxdepth 3 \( -name '*.yml' -o -name '*.yaml' \) -not -path './.git/*' -print -quit 2>/dev/null | grep -q .; then
    langs+=("yaml")
  fi

  # Docker
  if find . -maxdepth 3 \( -name 'Dockerfile' -o -name 'Dockerfile.*' -o -name '*.dockerfile' \) -print -quit 2>/dev/null | grep -q .; then
    langs+=("docker")
  fi

  # Shell
  if find . -maxdepth 3 -name '*.sh' -print -quit 2>/dev/null | grep -q .; then
    langs+=("shell")
  fi

  # Markdown
  if find . -maxdepth 3 -name '*.md' -print -quit 2>/dev/null | grep -q .; then
    langs+=("markdown")
  fi

  # TOML
  if find . -maxdepth 3 -name '*.toml' -not -name 'Cargo.toml' -print -quit 2>/dev/null | grep -q .; then
    langs+=("toml")
  fi

  # JSON
  if find . -maxdepth 3 -name '*.json' -not -path '*/node_modules/*' -print -quit 2>/dev/null | grep -q .; then
    langs+=("json")
  fi

  # Python
  if [[ -f "pyproject.toml" ]] || [[ -f "requirements.txt" ]] || find . -maxdepth 3 -name '*.py' -print -quit 2>/dev/null | grep -q .; then
    langs+=("python")
  fi

  printf '%s\n' "${langs[@]}" | sort -u
}

# ─── CLI entrypoint ──────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --files)
      shift
      detect_from_files "$*"
      ;;
    --repo)
      detect_from_repo
      ;;
    *)
      echo "Usage: detect.sh --files <file-list> | --repo"
      exit 1
      ;;
  esac
fi
