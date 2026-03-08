#!/usr/bin/env bash
set -euo pipefail

arg_value() {
  local key="$1"
  shift || true
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "$key="* ]]; then
      printf '%s' "${arg#"$key="}"
      return 0
    fi
  done
  return 1
}

frontmatter_value() {
  local file="$1"
  local prop="$2"
  awk -v prop="$prop" '
    NR==1 && $0!="---" { exit 1 }
    NR==1 { in_fm=1; next }
    in_fm && $0=="---" { exit(found ? 0 : 1) }
    in_fm {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line ~ "^" prop ":[[:space:]]*") {
        sub("^" prop ":[[:space:]]*", "", line)
        gsub(/^"/, "", line)
        gsub(/"$/, "", line)
        print line
        found=1
        exit 0
      }
    }
    END {
      if (!found) exit 1
    }
  ' "$file"
}

is_allowed_file() {
  local file="$1"
  local prop="$2"
  local val="$3"
  local actual
  if ! actual="$(frontmatter_value "$file" "$prop" 2>/dev/null)"; then
    return 1
  fi
  [[ "$actual" == "$val" ]]
}

emit_json_array_from_lines() {
  if [[ $# -eq 0 ]]; then
    echo "[]"
    return 0
  fi
  printf '%s\n' "$@" | jq -R . | jq -cs .
}

emit_json_context_array() {
  if [[ $# -eq 0 ]]; then
    echo "[]"
    return 0
  fi
  printf '%s\n' "$@" | jq -R '{path: ., context: "mock-context"}' | jq -cs .
}

extract_query_parts() {
  local query="$1"
  local prop="cli-allowed"
  local val="true"
  local term="$query"
  if [[ "$query" =~ ^\[([^:]+):([^]]+)\][[:space:]]+\((.*)\)$ ]]; then
    prop="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    term="${BASH_REMATCH[3]}"
  fi
  printf '%s\n%s\n%s\n' "$prop" "$val" "$term"
}

main() {
  local n last vault_name vault_path cmd
  n=$#
  if [[ $n -lt 1 ]]; then
    echo "mock obsidian: missing command" >&2
    exit 1
  fi

  last="${!n}"
  if [[ "$last" != vault=* ]]; then
    echo "mock obsidian: missing vault= argument" >&2
    exit 1
  fi
  vault_name="${last#vault=}"
  vault_path="${MOCK_VAULT_PATH:-}"
  if [[ -z "$vault_path" ]]; then
    echo "mock obsidian: MOCK_VAULT_PATH is required" >&2
    exit 1
  fi
  if [[ ! -d "$vault_path" ]]; then
    echo "mock obsidian: vault path not found: $vault_path" >&2
    exit 1
  fi
  if [[ -z "$vault_name" ]]; then
    echo "mock obsidian: vault name is empty" >&2
    exit 1
  fi

  cmd="$1"
  shift || true
  set -- "${@:1:$(( $# - 1 ))}"

  case "$cmd" in
    vault)
      if [[ "${1:-}" == "info=path" ]]; then
        printf '%s\n' "$vault_path"
        exit 0
      fi
      echo "mock obsidian: unsupported vault subcommand" >&2
      exit 1
      ;;
    property:read)
      local name path file val
      name="$(arg_value "name" "$@")"
      path="$(arg_value "path" "$@")"
      file="${vault_path%/}/$path"
      if [[ ! -f "$file" ]]; then
        exit 1
      fi
      if ! val="$(frontmatter_value "$file" "$name" 2>/dev/null)"; then
        exit 1
      fi
      printf '%s\n' "$val"
      ;;
    read)
      local path file
      path="$(arg_value "path" "$@")"
      file="${vault_path%/}/$path"
      if [[ ! -f "$file" ]]; then
        echo "mock obsidian: file not found: $path" >&2
        exit 1
      fi
      cat "$file"
      ;;
    search|search:context)
      local query prop val term file rel parts_output
      local -a matches
      query="$(arg_value "query" "$@")"
      parts_output="$(extract_query_parts "$query")"
      prop="$(printf '%s\n' "$parts_output" | sed -n '1p')"
      val="$(printf '%s\n' "$parts_output" | sed -n '2p')"
      term="$(printf '%s\n' "$parts_output" | sed -n '3p')"
      matches=()
      while IFS= read -r -d '' file; do
        if ! is_allowed_file "$file" "$prop" "$val"; then
          continue
        fi
        if [[ -n "${term//[[:space:]]/}" ]] && ! grep -qi -- "$term" "$file"; then
          continue
        fi
        rel="${file#"$vault_path"/}"
        matches+=("$rel")
      done < <(find "$vault_path" -type f -name '*.md' -print0)
      if [[ "$cmd" == "search:context" ]]; then
        emit_json_context_array "${matches[@]}"
      else
        emit_json_array_from_lines "${matches[@]}"
      fi
      ;;
    reload)
      exit 0
      ;;
    *)
      echo "mock obsidian: unsupported command: $cmd" >&2
      exit 1
      ;;
  esac
}

main "$@"
