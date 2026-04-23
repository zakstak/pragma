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

repo_has_match_within_depth() {
  find . \
    \( -path './.git' -o -path './node_modules' -o -path './.venv' -o -path './*/*/*/*' \) -prune -o \
    "$@" -print -quit 2>/dev/null | grep -q .
}

detect_from_repo() {
  local langs=()

  # Go
  if [[ -f "go.mod" ]] || repo_has_match_within_depth -name '*.go'; then
    langs+=("go")
  fi

  # Rust
  if [[ -f "Cargo.toml" ]] || repo_has_match_within_depth -name '*.rs'; then
    langs+=("rust")
  fi

  # TypeScript
  if [[ -f "tsconfig.json" ]] || (
    [[ -f "package.json" ]] && grep -qE '"typescript"' package.json 2>/dev/null
  ); then
    langs+=("typescript")
  fi

  # HTML
  if repo_has_match_within_depth -name '*.html'; then
    langs+=("html")
  fi

  # YAML
  if repo_has_match_within_depth \( -name '*.yml' -o -name '*.yaml' \); then
    langs+=("yaml")
  fi

  # Docker
  if repo_has_match_within_depth \( -name 'Dockerfile' -o -name 'Dockerfile.*' -o -name '*.dockerfile' \); then
    langs+=("docker")
  fi

  # Shell
  if repo_has_match_within_depth -name '*.sh'; then
    langs+=("shell")
  fi

  # Markdown
  if repo_has_match_within_depth -name '*.md'; then
    langs+=("markdown")
  fi

  # TOML
  if repo_has_match_within_depth -name '*.toml' -not -name 'Cargo.toml'; then
    langs+=("toml")
  fi

  # JSON
  if repo_has_match_within_depth -name '*.json' -not -path '*/node_modules/*'; then
    langs+=("json")
  fi

  # Python
  if [[ -f "pyproject.toml" ]] || [[ -f "requirements.txt" ]] || repo_has_match_within_depth -name '*.py'; then
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
