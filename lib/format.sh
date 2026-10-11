#!/usr/bin/env bash
# format.sh — Run formatters on staged files, grouped by detected language
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/detect.sh"
pragma_enforce_thread_owner || exit 1

PRAGMA_OUTPUT_FORMAT="${PRAGMA_OUTPUT_FORMAT:-gpt}"
FORMAT_RERUN="./lib/format.sh <staged-files>"

path_in_list() {
  local needle="$1"
  shift

  local candidate
  for candidate in "$@"; do
    if [[ "$candidate" == "$needle" ]]; then
      return 0
    fi
  done

  return 1
}

indexed_map_name_is_valid() {
  [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
}

indexed_map_set() {
  local keys_var="$1"
  local values_var="$2"
  local key="$3"
  local value="$4"

  indexed_map_name_is_valid "$keys_var" || return 1
  indexed_map_name_is_valid "$values_var" || return 1

  eval "$keys_var+=(\"\$key\")"
  eval "$values_var+=(\"\$value\")"
}

indexed_map_get() {
  local keys_var="$1"
  local values_var="$2"
  local key="$3"
  local output_var="$4"
  local -a keys=()
  local -a values=()
  local keys_decl
  local values_decl
  local i

  indexed_map_name_is_valid "$keys_var" || return 1
  indexed_map_name_is_valid "$values_var" || return 1
  indexed_map_name_is_valid "$output_var" || return 1

  keys_decl="$(declare -p "$keys_var" 2>/dev/null)" || return 1
  values_decl="$(declare -p "$values_var" 2>/dev/null)" || return 1

  keys_decl="${keys_decl/#declare -a ${keys_var}=/declare -a keys=}"
  values_decl="${values_decl/#declare -a ${values_var}=/declare -a values=}"

  eval "$keys_decl"
  eval "$values_decl"

  for ((i = 0; i < ${#keys[@]}; i++)); do
    if [[ "${keys[i]}" == "$key" ]]; then
      printf -v "$output_var" '%s' "${values[i]}"
      return 0
    fi
  done

  return 1
}

# ─── Per-language formatters ──────────────────────────────────────────────────

run_go_formatter_in_dir() {
  local dir="$1"
  shift
  (cd "$dir" && pragma_exec "$@")
}

format_go() {
  local -a files=("$@")
  local -a go_files=()
  filter_by_ext go_files go -- "${files[@]}"
  [[ ${#go_files[@]} -eq 0 ]] && return 0

  local file module_root existing_root seen_root
  local -a module_roots=()
  local -a module_files=()
  for file in "${go_files[@]}"; do
    module_root="$(go_module_root_for_file "$file")"
    seen_root=false
    if [[ ${#module_roots[@]} -gt 0 ]]; then
      for existing_root in "${module_roots[@]}"; do
        [[ "$existing_root" != "$module_root" ]] || seen_root=true
      done
    fi
    $seen_root || module_roots+=("$module_root")
  done
  for module_root in "${module_roots[@]}"; do
    module_files=()
    for file in "${go_files[@]}"; do
      if [[ "$(go_module_root_for_file "$file")" == "$module_root" ]]; then
        module_files+=("$(repo_relative_path_from_dir "$module_root" "$file")")
      fi
    done
    if (cd "$module_root" && { pragma_go_tool_package goimports >/dev/null || has_tool goimports; }); then
      pragma_run "goimports" "fmt" 0 "" "$FORMAT_RERUN" "go formatting failed" run_go_formatter_in_dir "$module_root" goimports -w "${module_files[@]}" || return 1
    elif has_tool gofmt; then
      pragma_run "gofmt" "fmt" 0 "" "$FORMAT_RERUN" "go formatting failed" run_go_formatter_in_dir "$module_root" gofmt -w "${module_files[@]}" || return 1
    else
      pragma_add_failure "goimports" "tool" 0 "" "$FORMAT_RERUN" "missing tool: goimports or gofmt" "" 1
      return 1
    fi
  done
}

# Read only edition-related manifest keys; no language-tool runtime is needed.
rust_manifest_setting() {
  local manifest="$1" setting="$2"
  awk -v setting="$setting" '
    /^[[:space:]]*\[/ {
      section = $0
      sub(/[[:space:]]*#.*/, "", section)
      gsub(/[[:space:]\[\]]/, "", section)
      next
    }
    {
      line = $0
      equals = index(line, "=")
      if (!equals) next
      key = substr(line, 1, equals - 1)
      gsub(/[[:space:]]/, "", key)
      full = section == "" ? key : section "." key
      value = substr(line, equals + 1)
      sub(/^[[:space:]]*/, "", value)
      if (full == setting ".workspace" && value ~ /^true([[:space:]#]|$)/) {
        print "workspace"
        exit
      }
      if (full != setting) next
      compact = value
      gsub(/[[:space:]]/, "", compact)
      if (compact ~ /^\{workspace=true\}/) {
        print "workspace"
        exit
      }
      quote = substr(value, 1, 1)
      if (quote == "\"" || quote == "\047") {
        value = substr(value, 2)
        end = index(value, quote)
        if (end) print substr(value, 1, end - 1)
      }
      exit
    }
  ' "$manifest"
}

rust_edition_for_file() {
  local dir root manifest edition workspace
  dir="$(cd "$(dirname "$1")" && pwd)"
  root="$(pragma_project_root)"
  while [[ ! -f "$dir/Cargo.toml" ]]; do
    if [[ "$dir" == "$root" || "$dir" == / ]]; then
      # Preserve the existing choice for files outside a Cargo package.
      printf '2021\n'
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  manifest="$dir/Cargo.toml"
  if [[ -z "$(rust_manifest_setting "$manifest" package.name)" ]]; then
    printf '2021\n'
    return 0
  fi
  edition="$(rust_manifest_setting "$manifest" package.edition)"
  if [[ "$edition" != workspace ]]; then
    # Cargo packages without an explicit edition use Rust 2015.
    printf '%s\n' "${edition:-2015}"
    return 0
  fi
  workspace="$(rust_manifest_setting "$manifest" package.workspace)"
  if [[ -n "$workspace" ]]; then
    [[ "$workspace" == /* ]] || workspace="$dir/$workspace"
    dir="$(cd "$workspace" && pwd)" || return 1
  fi
  while :; do
    if [[ -f "$dir/Cargo.toml" ]]; then
      edition="$(rust_manifest_setting "$dir/Cargo.toml" workspace.package.edition)"
      if [[ -n "$edition" ]]; then
        printf '%s\n' "$edition"
        return 0
      fi
    fi
    [[ "$dir" != / ]] || return 1
    dir="$(dirname "$dir")"
  done
}

format_rust() {
  local -a files=("$@")
  local -a rs_files=()
  local -a cargo_extra_files=()
  local -a rust_file_paths_before=()
  # shellcheck disable=SC2034 # used indirectly via indexed_map_* helpers
  local -a rust_file_hashes_before=()
  local -a rust_file_paths_after=()
  # shellcheck disable=SC2034 # used indirectly via indexed_map_* helpers
  local -a rust_file_hashes_after=()
  local dirty_file
  local before_hash
  local after_hash
  local file_hash
  local rustfmt_output=""
  local rustfmt_status=0
  local file edition output status
  local -a editions=()
  local -a edition_files=()
  filter_by_ext rs_files rs -- "${files[@]}"
  [[ ${#rs_files[@]} -eq 0 ]] && return 0

  if has_tool rustfmt; then
    log_info "Formatting Rust files..."
    # Resolve every file before formatting, then keep different package editions
    # in separate invocations so workspace and nested crates use their own syntax.
    for file in "${rs_files[@]}"; do
      if ! edition="$(rust_edition_for_file "$file")" ||
        [[ ! "$edition" =~ ^(2015|2018|2021|2024)$ ]]; then
        pragma_add_failure "rustfmt" "config" 0 "" "$FORMAT_RERUN" "cannot resolve Rust edition" "$file" 1
        return 1
      fi
      editions+=("$edition")
    done
    for edition in 2015 2018 2021 2024; do
      edition_files=()
      for ((status = 0; status < ${#rs_files[@]}; status++)); do
        [[ "${editions[status]}" != "$edition" ]] || edition_files+=("${rs_files[status]}")
      done
      [[ ${#edition_files[@]} -gt 0 ]] || continue
      set +e
      output="$(rustfmt --edition "$edition" "${edition_files[@]}" 2>&1)"
      status=$?
      set -e
      if [[ $status -ne 0 ]]; then
        rustfmt_output="$output"
        rustfmt_status=$status
        break
      fi
    done

    if [[ $rustfmt_status -ne 0 ]]; then
      if has_tool cargo; then
        while IFS= read -r -d '' dirty_file; do
          if path_in_list "$dirty_file" "${rs_files[@]}"; then
            continue
          fi

          [[ -f "$dirty_file" ]] || continue
          file_hash="$(git hash-object --no-filters "$dirty_file")"
          indexed_map_set rust_file_paths_before rust_file_hashes_before "$dirty_file" "$file_hash"
        done < <(git ls-files -z --cached --others --exclude-standard -- '*.rs')

        pragma_run "cargo" "fmt" 0 "" "$FORMAT_RERUN" "rust formatting failed" cargo fmt || return 1

        while IFS= read -r -d '' dirty_file; do
          if path_in_list "$dirty_file" "${rs_files[@]}"; then
            continue
          fi

          [[ -f "$dirty_file" ]] || continue
          file_hash="$(git hash-object --no-filters "$dirty_file")"
          indexed_map_set rust_file_paths_after rust_file_hashes_after "$dirty_file" "$file_hash"
        done < <(git ls-files -z --cached --others --exclude-standard -- '*.rs')

        if [[ ${#rust_file_paths_after[@]} -gt 0 ]]; then
          for dirty_file in "${rust_file_paths_after[@]}"; do
            if ! indexed_map_get rust_file_paths_before rust_file_hashes_before "$dirty_file" before_hash; then
              cargo_extra_files+=("$dirty_file")
              continue
            fi

            indexed_map_get rust_file_paths_after rust_file_hashes_after "$dirty_file" after_hash || continue

            if [[ "$before_hash" != "$after_hash" ]]; then
              cargo_extra_files+=("$dirty_file")
            fi
          done
        fi

        if [[ ${#rust_file_paths_before[@]} -gt 0 ]]; then
          for dirty_file in "${rust_file_paths_before[@]}"; do
            if ! indexed_map_get rust_file_paths_after rust_file_hashes_after "$dirty_file" after_hash; then
              cargo_extra_files+=("$dirty_file")
            fi
          done
        fi

        if [[ ${#cargo_extra_files[@]} -gt 0 ]]; then
          pragma_add_failure "cargo" "fmt" 0 "" "$FORMAT_RERUN" "cargo fmt touched additional files" "$(printf '%s\n' "${cargo_extra_files[@]}")" 1
          return 1
        fi
      else
        if pragma_human_output_enabled && [[ -n "$rustfmt_output" ]]; then
          printf '%s\n' "$rustfmt_output" >&2
        fi
        pragma_add_failure "rustfmt" "fmt" 0 "" "$FORMAT_RERUN" "rust formatting failed" "$rustfmt_output" "$rustfmt_status"
        return 1
      fi
    fi
  else
    log_warn "Missing tool: ${BOLD}rustfmt${RESET} (rust formatter)"
    pragma_add_failure "rustfmt" "tool" 0 "" "$FORMAT_RERUN" "missing tool: rustfmt" "" 1
    return 1
  fi
}

format_typescript() {
  local -a files=("$@")
  local -a ts_files=()
  filter_by_ext ts_files ts tsx js jsx -- "${files[@]}"
  [[ ${#ts_files[@]} -eq 0 ]] && return 0

  if has_tool prettier; then
    log_info "Formatting TypeScript/JS files..."
    pragma_run "prettier" "fmt" 0 "" "$FORMAT_RERUN" "typescript formatting failed" prettier --write "${ts_files[@]}" || return 1
  else
    log_warn "Missing tool: ${BOLD}prettier${RESET} (typescript/js formatter)"
    pragma_add_failure "prettier" "tool" 0 "" "$FORMAT_RERUN" "missing tool: prettier" "" 1
    return 1
  fi
}

format_html() {
  local -a files=("$@")
  local -a html_files=()
  local -a plain_html_files=()
  local -a template_html_files=()
  local file
  filter_by_ext html_files html htm -- "${files[@]}"
  [[ ${#html_files[@]} -eq 0 ]] && return 0

  for file in "${html_files[@]}"; do
    if html_file_contains_template_syntax "$file"; then
      template_html_files+=("$file")
    else
      plain_html_files+=("$file")
    fi
  done

  if [[ ${#template_html_files[@]} -gt 0 ]]; then
    log_skip "Skipping templated HTML files; generic HTML formatting is disabled for template syntax"
  fi

  [[ ${#plain_html_files[@]} -eq 0 ]] && return 0

  if has_tool prettier; then
    log_info "Formatting HTML files..."
    pragma_run "prettier" "fmt" 0 "" "$FORMAT_RERUN" "html formatting failed" prettier --write "${plain_html_files[@]}" || return 1
  else
    log_warn "Missing tool: ${BOLD}prettier${RESET} (html formatter)"
    pragma_add_failure "prettier" "tool" 0 "" "$FORMAT_RERUN" "missing tool: prettier" "" 1
    return 1
  fi
}

format_yaml() {
  local -a files=("$@")
  local -a yaml_files=()
  filter_by_ext yaml_files yml yaml -- "${files[@]}"
  [[ ${#yaml_files[@]} -eq 0 ]] && return 0

  if has_tool prettier; then
    log_info "Formatting YAML files..."
    pragma_run "prettier" "fmt" 0 "" "$FORMAT_RERUN" "yaml formatting failed" prettier --write "${yaml_files[@]}" || return 1
  else
    log_warn "Missing tool: ${BOLD}prettier${RESET} (yaml formatter)"
    pragma_add_failure "prettier" "tool" 0 "" "$FORMAT_RERUN" "missing tool: prettier" "" 1
    return 1
  fi
}

format_shell() {
  local -a files=("$@")
  local -a sh_files=()
  filter_by_ext sh_files sh -- "${files[@]}"
  [[ ${#sh_files[@]} -eq 0 ]] && return 0

  if has_tool shfmt; then
    log_info "Formatting Shell files..."
    pragma_run "shfmt" "fmt" 0 "" "$FORMAT_RERUN" "shell formatting failed" shfmt -w -i 2 -ci "${sh_files[@]}" || return 1
  else
    log_warn "Missing tool: ${BOLD}shfmt${RESET} (shell formatter)"
    pragma_add_failure "shfmt" "tool" 0 "" "$FORMAT_RERUN" "missing tool: shfmt" "" 1
    return 1
  fi
}

format_markdown() {
  local -a files=("$@")
  local -a md_files=()
  filter_by_ext md_files md -- "${files[@]}"
  [[ ${#md_files[@]} -eq 0 ]] && return 0

  if has_tool prettier; then
    log_info "Formatting Markdown files..."
    pragma_run "prettier" "fmt" 0 "" "$FORMAT_RERUN" "markdown formatting failed" prettier --write --prose-wrap always "${md_files[@]}" || return 1
  else
    log_warn "Missing tool: ${BOLD}prettier${RESET} (markdown formatter)"
    pragma_add_failure "prettier" "tool" 0 "" "$FORMAT_RERUN" "missing tool: prettier" "" 1
    return 1
  fi
}

format_toml() {
  local -a files=("$@")
  local -a toml_files=()
  filter_by_ext toml_files toml -- "${files[@]}"
  [[ ${#toml_files[@]} -eq 0 ]] && return 0

  if has_tool taplo; then
    log_info "Formatting TOML files..."
    pragma_run "taplo" "fmt" 0 "" "$FORMAT_RERUN" "toml formatting failed" taplo fmt "${toml_files[@]}" || return 1
  else
    log_warn "Missing tool: ${BOLD}taplo${RESET} (toml formatter)"
    pragma_add_failure "taplo" "tool" 0 "" "$FORMAT_RERUN" "missing tool: taplo" "" 1
    return 1
  fi
}

format_json() {
  local -a files=("$@")
  local -a json_files=()
  filter_by_ext json_files json -- "${files[@]}"
  [[ ${#json_files[@]} -eq 0 ]] && return 0

  if has_tool prettier; then
    log_info "Formatting JSON files..."
    pragma_run "prettier" "fmt" 0 "" "$FORMAT_RERUN" "json formatting failed" prettier --write "${json_files[@]}" || return 1
  else
    log_warn "Missing tool: ${BOLD}prettier${RESET} (json formatter)"
    pragma_add_failure "prettier" "tool" 0 "" "$FORMAT_RERUN" "missing tool: prettier" "" 1
    return 1
  fi
}

format_python() {
  local -a files=("$@")
  local -a py_files=()
  filter_by_ext py_files py -- "${files[@]}"
  [[ ${#py_files[@]} -eq 0 ]] && return 0

  if has_tool ruff; then
    log_info "Formatting Python files..."
    pragma_run "ruff" "fmt" 0 "" "$FORMAT_RERUN" "python formatting failed" ruff format "${py_files[@]}" || return 1
  else
    log_warn "Missing tool: ${BOLD}ruff${RESET} (python formatter)"
    pragma_add_failure "ruff" "tool" 0 "" "$FORMAT_RERUN" "missing tool: ruff" "" 1
    return 1
  fi
}

# ─── Dispatcher ───────────────────────────────────────────────────────────────

# Docker and kingfisher have no formatting step — intentionally omitted.

FORMATTERS=(
  "go:format_go"
  "rust:format_rust"
  "typescript:format_typescript"
  "html:format_html"
  "yaml:format_yaml"
  "shell:format_shell"
  "markdown:format_markdown"
  "toml:format_toml"
  "json:format_json"
  "python:format_python"
)

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  pragma_set_context "pre-commit" "format"

  local -a files=("$@")
  if [[ ${#files[@]} -eq 0 ]]; then
    log_skip "No files to format"
    exit 0
  fi

  log_header "Formatting"

  local langs
  langs=$(detect_from_files "${files[@]}")

  if [[ -z "$langs" ]]; then
    log_skip "No recognized languages in staged files"
    exit 0
  fi

  for entry in "${FORMATTERS[@]}"; do
    local lang="${entry%%:*}"
    local func="${entry##*:}"
    if echo "$langs" | grep -qx "$lang"; then
      "$func" "${files[@]}" || record_failure
    fi
  done

  exit_with_status
}

main "$@"
