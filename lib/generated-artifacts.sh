#!/usr/bin/env bash
# Reject recognized generated artifacts in the complete proposed commit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
pragma_enforce_thread_owner || exit 1
PRAGMA_OUTPUT_FORMAT="${PRAGMA_OUTPUT_FORMAT:-gpt}"
pragma_set_context "pre-commit" "generated-artifacts"

reject_path() {
  local quoted
  printf -v quoted '%q' "$1"
  local message="$quoted: $2. Remove it from the index or review a narrow .gitattributes exception."
  if pragma_human_output_enabled; then
    printf '%s\n' "$message" >&2
  fi
  pragma_add_failure "generated-artifacts" "generated" 0 "" ".pragma-hooks/generated-artifacts.sh" "$message"
}

# Output directories can appear inside any package in a monorepo. Avoid broad
# names such as bin, vendor, media, or generated that also contain authored files.
artifact_reason() {
  case "/$1" in
    /output/* | /outputs/* | */node_modules/* | */target/* | */dist/* | */build/* | */out/* | */coverage/* | */htmlcov/* | \
      */__pycache__/* | */.pytest_cache/* | */.mypy_cache/* | */.ruff_cache/* | */.cache/* | \
      */.next/* | */.nuxt/* | */.output/* | */.svelte-kit/* | */.angular/* | */.turbo/* | */.parcel-cache/* | \
      */.gradle/* | */.dart_tool/* | */.venv/* | */venv/* | */.tox/* | */.nox/* | */.terraform/* | \
      */Pods/* | */DerivedData/* | */.zig-cache/* | */zig-cache/* | */zig-out/*)
      printf 'recognized build, dependency, or cache directory'
      return 0
      ;;
  esac
  case "$1" in
    *.pyc | *.pyo | *.o | *.obj | *.class | *.jar | *.war | *.ear | *.so | *.so.* | *.dylib | *.dll | *.exe | *.a | *.lib | *.wasm | \
      *.map | *.tsbuildinfo | *.min.js | *.min.css | *.bundle.js | *.bundle.css | \
      *.pb.go | *.pb.cc | *.pb.h | *.g.dart | \
      *.bin | *.gguf | *.ggml | *.safetensors | *.onnx | *.tflite | *.pt | *.pth | *.ckpt)
      printf 'recognized compiled, generated-source, or model artifact extension'
      return 0
      ;;
  esac
  return 1
}

is_lockfile() {
  case "${1##*/}" in
    package-lock.json | npm-shrinkwrap.json | yarn.lock | pnpm-lock.yaml | bun.lock | bun.lockb | \
      Cargo.lock | go.sum | go.work.sum | uv.lock | poetry.lock | Pipfile.lock | pdm.lock | \
      Gemfile.lock | composer.lock | flake.lock | mix.lock | packages.lock.json | Package.resolved | \
      pubspec.lock | gradle.lockfile | .terraform.lock.hcl) return 0 ;;
  esac
  return 1
}

is_source() {
  case "$1" in
    *.go | *.rs | *.js | *.jsx | *.ts | *.tsx | *.py | *.sh | *.c | *.cc | *.cpp | *.h | *.hpp | \
      *.cs | *.java | *.kt | *.kts | *.scala | *.swift | *.rb | *.php | *.dart | *.m | *.mm | \
      *.vb | *.fs | *.sql | *.css | *.scss | *.html | *.xml | *.yaml | *.yml | *.toml) return 0 ;;
  esac
  return 1
}

# Use an isolated Git directory to evaluate only versioned, staged attributes.
# --cached alone still reads .git/info/attributes and global attributes. Rebuild
# a temporary index from entries so split indexes and alternate indexes work too.
staged_git() {
  GIT_DIR="$scratch/repo.git" GIT_COMMON_DIR="$scratch/repo.git" GIT_WORK_TREE="$scratch" GIT_INDEX_FILE="$scratch/index" \
    GIT_OBJECT_DIRECTORY="$object_dir" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_ATTR_NOSYSTEM=1 git -c core.attributesFile=/dev/null "$@"
}

main() {
  local root object_dir object_format
  root="$(git rev-parse --show-toplevel)"
  cd "$root"
  object_dir="$(git rev-parse --path-format=absolute --git-path objects)"
  object_format="$(git rev-parse --show-object-format)"
  scratch="$(mktemp -d)"
  # Keep scratch global so cleanup also works after errexit unwinds main.
  trap 'rm -rf -- "$scratch"' EXIT

  git ls-files --stage -z >"$scratch/entries"
  git ls-files --cached -z >"$scratch/paths"
  mkdir -p "$scratch/repo.git/objects" "$scratch/repo.git/refs"
  printf 'ref: refs/heads/pragma-index\n' >"$scratch/repo.git/HEAD"
  printf '[core]\nrepositoryformatversion = 1\n[extensions]\nobjectFormat = %s\n' "$object_format" >"$scratch/repo.git/config"
  staged_git update-index -z --index-info <"$scratch/entries"
  staged_git check-attr --cached -z --stdin pragma-generated linguist-generated generated \
    <"$scratch/paths" >"$scratch/attributes"

  local entry path mode rest oid stage attr_path attr value explicit linguistic generated reason
  exec 3<"$scratch/attributes"
  while IFS= read -r -d '' entry; do
    path="${entry#*$'\t'}"
    mode="${entry%% *}"
    rest="${entry#* }"
    oid="${rest%% *}"
    rest="${rest#* }"
    stage="${rest%%$'\t'*}"
    explicit='' linguistic='' generated=''
    for attr in pragma-generated linguist-generated generated; do
      IFS= read -r -d '' attr_path <&3
      IFS= read -r -d '' value <&3 # Attribute name, checked below.
      [[ "$attr_path" == "$path" && "$value" == "$attr" ]] || {
        printf 'Generated-artifact check: inconsistent index attribute results.\n' >&2
        exit 1
      }
      IFS= read -r -d '' value <&3
      case "$attr" in
        pragma-generated) explicit="$value" ;;
        linguist-generated) linguistic="$value" ;;
        generated) generated="$value" ;;
      esac
    done
    if [[ "$stage" != 0 ]]; then
      reject_path "$path" 'unmerged index entry'
      continue
    fi
    # Only this Pragma-specific attribute grants an exception to the policy.
    [[ "$explicit" != unset && "$explicit" != false ]] || continue
    if [[ "$explicit" == set || "$explicit" == true || "$linguistic" == set || "$linguistic" == true || "$generated" == set || "$generated" == true ]]; then
      reject_path "$path" 'marked generated in staged .gitattributes'
    elif reason="$(artifact_reason "$path")"; then
      reject_path "$path" "$reason"
    elif [[ "$mode" == 100644 || "$mode" == 100755 ]] && ! is_lockfile "$path" && is_source "$path"; then
      # Limit source inspection to the first 40 lines. A closed reader can give
      # cat-file SIGPIPE on a large blob; other Git failures must still fail.
      { git cat-file blob "$oid" || [[ $? -eq 141 ]]; } | head -n 40 >"$scratch/header"
      if LC_ALL=C grep -Eiq '^[[:space:]]*(//|#|/\*+|\*|<!--|--|;)[[:space:]]*(Code generated .*DO NOT EDIT|.*<auto-generated([[:space:]>]|$)|@generated([[:space:]]|$)|.*(automatically generated|auto-generated|autogenerated|generated (file|code)).*do not edit|do not edit.*generated)' "$scratch/header"; then
        reject_path "$path" 'generated-source header in staged content'
      fi
    fi
  done <"$scratch/entries"
  exec 3<&-
  exit_with_status
}

main "$@"
