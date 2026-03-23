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
  local langs=()
  local file

  for file in "$@"; do
    case "$file" in
      *.go) langs+=("go") ;;
    esac

    case "$file" in
      *.rs) langs+=("rust") ;;
    esac

    case "$file" in
      *.ts | *.tsx | *.js | *.jsx) langs+=("typescript") ;;
    esac

    case "$file" in
      *.html | *.htm) langs+=("html") ;;
    esac

    case "$file" in
      *.yml | *.yaml) langs+=("yaml") ;;
    esac

    if is_dockerfile_path "$file"; then
      langs+=("docker")
    fi

    case "$file" in
      *.sh) langs+=("shell") ;;
    esac

    case "$file" in
      *.md) langs+=("markdown") ;;
    esac

    case "$file" in
      *.toml) langs+=("toml") ;;
    esac

    case "$file" in
      *.json) langs+=("json") ;;
    esac

    case "$file" in
      *.py) langs+=("python") ;;
    esac
  done

  if [[ ${#langs[@]} -gt 0 ]]; then
    printf '%s\n' "${langs[@]}" | sort -u
  fi
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
      detect_from_files "$@"
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
