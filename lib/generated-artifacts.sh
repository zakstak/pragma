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
# --cached alone still reads .git/info/attributes and global attributes.
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

  mkdir -p "$scratch/repo.git/objects" "$scratch/repo.git/refs"
  printf 'ref: refs/heads/pragma-index\n' >"$scratch/repo.git/HEAD"
  printf '[core]\nrepositoryformatversion = 1\n[extensions]\nobjectFormat = %s\n' "$object_format" >"$scratch/repo.git/config"

  # Diff against an empty tree to list the complete proposed commit. Unlike
  # ls-files, this excludes intent-to-add entries, including missing files.
  local empty_tree entry path _old_mode mode _old_oid oid status
  empty_tree="$(staged_git hash-object -w -t tree --stdin </dev/null)"
  git --no-optional-locks diff --cached --raw --no-abbrev --no-renames --no-ext-diff --no-textconv --ignore-submodules=none --ita-invisible-in-index -z "$empty_tree" >"$scratch/diff"
  : >"$scratch/entries"
  : >"$scratch/paths"
  while IFS= read -r -d '' entry && IFS= read -r -d '' path; do
    IFS=' ' read -r _old_mode mode _old_oid oid status <<<"${entry#:}"
    if [[ "$status" == U ]]; then
      reject_path "$path" 'unmerged index entry'
      continue
    fi
    printf '%s %s 0\t%s\0' "$mode" "$oid" "$path" >>"$scratch/entries"
    printf '%s\0' "$path" >>"$scratch/paths"
  done <"$scratch/diff"
  staged_git update-index -z --index-info <"$scratch/entries"
  staged_git check-attr --cached -z --stdin pragma-generated linguist-generated generated \
    <"$scratch/paths" >"$scratch/attributes"

  local rest attr_path attr value explicit linguistic generated reason
  : >"$scratch/source-oids"
  : >"$scratch/source-paths"
  exec 3<"$scratch/attributes"
  while IFS= read -r -d '' entry; do
    path="${entry#*$'\t'}"
    mode="${entry%% *}"
    rest="${entry#* }"
    oid="${rest%% *}"
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
    # Only this Pragma-specific attribute grants an exception to the policy.
    [[ "$explicit" != unset && "$explicit" != false ]] || continue
    if [[ "$explicit" == set || "$explicit" == true || "$linguistic" == set || "$linguistic" == true || "$generated" == set || "$generated" == true ]]; then
      reject_path "$path" 'marked generated in staged .gitattributes'
    elif reason="$(artifact_reason "$path")"; then
      reject_path "$path" "$reason"
    elif [[ "$mode" == 100644 || "$mode" == 100755 ]] && ! is_lockfile "$path" && is_source "$path"; then
      printf '%s\n' "$oid" >>"$scratch/source-oids"
      printf '%s\0%s\0' "$oid" "$path" >>"$scratch/source-paths"
    fi
  done <"$scratch/entries"
  exec 3<&-

  # Scan each distinct source blob once in one Git process. Synthetic paths
  # cache results by object ID while the path list retains per-file diagnostics.
  sort -u "$scratch/source-oids" >"$scratch/unique-oids"
  : >"$scratch/source-entries"
  while IFS= read -r oid; do
    printf '100644 %s\t%s\n' "$oid" "$oid" >>"$scratch/source-entries"
  done <"$scratch/unique-oids"
  staged_git read-tree --empty
  staged_git update-index --index-info <"$scratch/source-entries"
  local pattern line _matched grep_status
  pattern='^[[:space:]]*(//|#|/\*+|\*|<!--|--|;)[[:space:]]*(Code generated .*DO NOT EDIT|.*<auto-generated([[:space:]>]|$)|@generated([[:space:]]|$)|.*(automatically generated|auto-generated|autogenerated|generated (by|file|code)).*do not edit|do not edit.*generated)'
  if LC_ALL=C staged_git grep --cached --no-color -a -n -z -i -E "$pattern" -- >"$scratch/headers"; then
    :
  else
    grep_status=$?
    [[ "$grep_status" == 1 ]] || return "$grep_status"
  fi
  mkdir "$scratch/generated"
  while IFS= read -r -d '' oid && IFS= read -r -d '' line && IFS= read -r _matched; do
    if [[ "$line" -le 40 ]]; then
      : >"$scratch/generated/$oid"
    fi
  done <"$scratch/headers"
  while IFS= read -r -d '' oid && IFS= read -r -d '' path; do
    if [[ -f "$scratch/generated/$oid" ]]; then
      reject_path "$path" 'generated-source header in staged content'
    fi
  done <"$scratch/source-paths"
  exit_with_status
}

main "$@"
