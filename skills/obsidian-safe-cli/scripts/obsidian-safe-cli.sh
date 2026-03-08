#!/usr/bin/env bash
set -euo pipefail

# Lightweight policy wrapper for Obsidian CLI (https://help.obsidian.md/cli).
#
# This API is intentionally tiny because the caller models are weak (sub GPT-3.5):
# - Fewer commands and fewer argument shapes reduce tool misuse.
# - No generic edit command exists, because broad mutation is risky and ambiguous.
# - No allow/deny command exists for models, because access control is human-admin only.
#
# Security model:
# - Discovery is always gated by [cli-allowed:true].
# - Reads require cli-allowed=true on the target note.
# - Writes are only create/append, and are always routed under agent-inbox/.

# Prefer OBSIDIAN_SAFE_CLI_* env vars; keep old unprefixed names as fallback for compatibility.
# OBSIDIAN_SAFE_CLI_VAULT is intentionally required (no default) to force explicit targeting.
OBS_BIN="${OBSIDIAN_SAFE_CLI_OBS_BIN:-${OBS_BIN:-obsidian}}"
VAULT_ARG="${OBSIDIAN_SAFE_CLI_VAULT:-}"
# Optional explicit fallback only; no machine-specific default path is assumed.
DEFAULT_VAULT_PATH="${OBSIDIAN_SAFE_CLI_DEFAULT_VAULT_PATH:-${DEFAULT_VAULT_PATH:-}}"
INBOX_PREFIX="${OBSIDIAN_SAFE_CLI_INBOX_PREFIX:-${INBOX_PREFIX:-agent-inbox/}}"
AUDIT_LOG="${OBSIDIAN_SAFE_CLI_AUDIT_LOG:-${AUDIT_LOG:-./obsidian-safe-cli-audit.log}}"
ALLOWED_PROP="${OBSIDIAN_SAFE_CLI_ALLOWED_PROP:-${ALLOWED_PROP:-cli-allowed}}"
ALLOWED_VALUE="${OBSIDIAN_SAFE_CLI_ALLOWED_VALUE:-${ALLOWED_VALUE:-true}}"

usage() {
  cat <<'EOF'
Usage:
  obsidian-safe-cli.sh search "<query>"
  obsidian-safe-cli.sh search-context "<query>"
  obsidian-safe-cli.sh read [--json] "<path>"
  obsidian-safe-cli.sh create "<note-name-or-relative-path>" "<content>"
  obsidian-safe-cli.sh append "<note-name-or-relative-path>" "<content>"

Environment:
  OBSIDIAN_SAFE_CLI_OBS_BIN      Obsidian CLI binary (https://help.obsidian.md/cli) (default: obsidian)
  OBSIDIAN_SAFE_CLI_VAULT        Vault name (required)
  OBSIDIAN_SAFE_CLI_DEFAULT_VAULT_PATH Fallback vault path if CLI path probe is empty
  OBSIDIAN_SAFE_CLI_INBOX_PREFIX Auto-target folder for create/append (default: agent-inbox/)
  OBSIDIAN_SAFE_CLI_AUDIT_LOG    Audit log path (default: ./obsidian-safe-cli-audit.log)
  OBSIDIAN_SAFE_CLI_ALLOWED_PROP Access property for read/search gating (default: cli-allowed)
  OBSIDIAN_SAFE_CLI_ALLOWED_VALUE Allowed property value (default: true)
EOF
}

log_action() {
  local action="$1"
  local target="${2:-}"
  local detail="${3:-}"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf '%s\taction=%s\ttarget=%s\tdetail=%s\n' "$ts" "$action" "$target" "$detail" >>"$AUDIT_LOG"
}

obs() {
  "$OBS_BIN" "$@" "vault=$VAULT_ARG"
}

emit_json_or_empty_array() {
  local raw="$1"
  if [[ -z "${raw//[[:space:]]/}" ]]; then
    echo "[]"
    return 0
  fi
  if printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    printf '%s\n' "$raw"
    return 0
  fi
  # Preserve output but still guarantee a visible payload.
  printf '{"error":"non-json-output","raw":%s}\n' "$(jq -Rn --arg s "$raw" '$s')"
}

emit_op_event() {
  local phase="$1"
  local command="$2"
  local target="${3:-}"
  local detail="${4:-}"
  printf 'op:%s %s\n' \
    "$phase" \
    "$(jq -cn \
      --arg phase "$phase" \
      --arg command "$command" \
      --arg target "$target" \
      --arg detail "$detail" \
      '{phase:$phase, command:$command, target:$target, detail:$detail}')"
}

json_array_count_or_zero() {
  local payload="$1"
  printf '%s' "$payload" | jq -r 'if type == "array" then length else 0 end' 2>/dev/null || echo "0"
}

print_cli_allowed_frontmatter() {
  printf '%s\n' '---' 'cli-allowed: true' '---'
}

has_cli_allowed_frontmatter() {
  local file="$1"
  awk '
    NR==1 && $0!="---" { exit 1 }
    NR==1 { in_fm=1; next }
    in_fm && $0=="---" { exit(found ? 0 : 1) }
    in_fm && $0 ~ /^cli-allowed:[[:space:]]*true[[:space:]]*$/ { found=1 }
    END {
      if (NR==0) exit 1
      if (in_fm) exit(found ? 0 : 1)
      exit 1
    }
  ' "$file"
}

ensure_cli_allowed_frontmatter() {
  local file="$1"
  local tmp
  if has_cli_allowed_frontmatter "$file"; then
    return 0
  fi
  tmp="$(mktemp)"
  {
    print_cli_allowed_frontmatter
    cat "$file"
  } >"$tmp"
  mv "$tmp" "$file"
}

resolve_inbox_note_path() {
  local input="$1"
  local prefix path
  input="$(normalize_path "$input")"
  prefix="$(normalize_path "$INBOX_PREFIX")"
  prefix="${prefix%/}/"

  # Caller can pass either "note-name" or "agent-inbox/note-name"; both normalize to inbox.
  if [[ "$input" == "$prefix"* ]]; then
    path="$input"
  else
    path="${prefix}${input}"
  fi

  # Force markdown extension for predictable Obsidian note behavior.
  if [[ "$path" != *.md ]]; then
    path="${path}.md"
  fi
  printf '%s' "$path"
}

resolve_vault_abs_path() {
  local rel="$1"
  local vault_path attempt
  vault_path=""
  for attempt in 1 2 3; do
    vault_path="$(obs vault info=path 2>/dev/null || true)"
    if [[ -n "${vault_path//[[:space:]]/}" ]]; then
      break
    fi
    sleep 0.2
  done
  if [[ -z "${vault_path//[[:space:]]/}" ]]; then
    # CLI path probe can be intermittently empty in some automation contexts.
    # Use explicit fallback only when configured.
    vault_path="$DEFAULT_VAULT_PATH"
  fi
  if [[ -z "${vault_path//[[:space:]]/}" ]]; then
    echo "write failed: vault path probe returned empty; set OBSIDIAN_SAFE_CLI_DEFAULT_VAULT_PATH if needed" >&2
    exit 3
  fi
  if [[ ! -d "$vault_path" ]]; then
    echo "write failed: vault path unavailable for $VAULT_ARG (tried $vault_path)" >&2
    exit 3
  fi
  printf '%s/%s' "${vault_path%/}" "$rel"
}

run_obs_search_json() {
  local mode="$1"
  local gated_query="$2"
  local out err rc attempt
  local err_file
  err_file="$(mktemp)"

  out=""
  rc=0
  for attempt in 1 2 3; do
    if [[ "$mode" == "context" ]]; then
      out="$(obs search:context "query=$gated_query" format=json 2>"$err_file")"
      rc=$?
    else
      out="$(obs search "query=$gated_query" format=json 2>"$err_file")"
      rc=$?
    fi
    if [[ "$rc" -ne 0 ]]; then
      break
    fi
    if [[ -n "${out//[[:space:]]/}" ]]; then
      break
    fi
    sleep 0.2
  done
  err="$(cat "$err_file" || true)"
  rm -f "$err_file"

  if [[ "$rc" -ne 0 ]]; then
    printf '{"error":"obsidian-search-failed","mode":%s,"code":%s,"vault":%s,"query":%s,"stderr":%s}\n' \
      "$(jq -Rn --arg s "$mode" '$s')" \
      "$rc" \
      "$(jq -Rn --arg s "$VAULT_ARG" '$s')" \
      "$(jq -Rn --arg s "$gated_query" '$s')" \
      "$(jq -Rn --arg s "$err" '$s')"
    exit "$rc"
  fi

  emit_json_or_empty_array "$out"
}

require_cmds() {
  local missing=0
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      echo "missing required command: $c" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    exit 1
  fi
}

normalize_path() {
  local p="$1"
  # deny obvious traversal / absolute paths
  if [[ "$p" == /* ]] || [[ "$p" == *".."* ]]; then
    echo "invalid path: absolute paths and .. are not allowed" >&2
    exit 1
  fi
  printf '%s' "$p"
}

resolve_allowed_note_path() {
  local path c value
  path="$(normalize_path "$1")"

  for c in "$path" "${path}.md"; do
    # Skip duplicate candidate when input already ends with .md
    if [[ "$c" == "${path}.md" && "$path" == *.md ]]; then
      continue
    fi
    value="$(obs property:read "name=$ALLOWED_PROP" "path=$c" 2>/dev/null || true)"
    # Be tolerant to raw "true", quoted values, and whitespace.
    value="$(printf '%s' "$value" | tr -d '[:space:]\"')"
    if [[ "$value" == "$ALLOWED_VALUE" ]]; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

cmd_search() {
  local user_query="$1" gated_query output count
  gated_query="[$ALLOWED_PROP:$ALLOWED_VALUE] ($user_query)"
  emit_op_event "start" "search" "" "$gated_query"
  log_action "search" "" "$gated_query"
  output="$(run_obs_search_json "search" "$gated_query")"
  printf '%s\n' "$output"
  count="$(json_array_count_or_zero "$output")"
  emit_op_event "ok" "search" "" "results=$count"
}

cmd_search_context() {
  local user_query="$1" gated_query output count
  gated_query="[$ALLOWED_PROP:$ALLOWED_VALUE] ($user_query)"
  emit_op_event "start" "search-context" "" "$gated_query"
  log_action "search-context" "" "$gated_query"
  output="$(run_obs_search_json "context" "$gated_query")"
  printf '%s\n' "$output"
  count="$(json_array_count_or_zero "$output")"
  emit_op_event "ok" "search-context" "" "results=$count"
}

emit_read_json() {
  local path="$1"
  local content="$2"
  local bytes="$3"
  local lines="$4"

  jq -cn \
    --arg status "ok" \
    --arg path "$path" \
    --arg content "$content" \
    --argjson bytes "$bytes" \
    --argjson lines "$lines" \
    '{status:$status, command:"read", path:$path, bytes:$bytes, lines:$lines, content:$content}'
}

cmd_read() {
  local output_mode="$1" input_path="$2" resolved_path inbox_path content bytes lines
  input_path="$(normalize_path "$input_path")"
  if ! resolved_path="$(resolve_allowed_note_path "$input_path")"; then
    inbox_path="$(resolve_inbox_note_path "$input_path")"
    if ! resolved_path="$(resolve_allowed_note_path "$inbox_path")"; then
      echo "access denied: $input_path is not $ALLOWED_PROP:$ALLOWED_VALUE. Hint: if this note was just created, try reading $inbox_path" >&2
      exit 2
    fi
  fi
  emit_op_event "start" "read" "$resolved_path" "mode=$output_mode"
  log_action "read" "$resolved_path" "$output_mode"
  content="$(obs read "path=$resolved_path")"
  bytes="$(printf '%s' "$content" | wc -c | tr -d '[:space:]')"
  lines="$(printf '%s' "$content" | awk 'END { print NR }')"
  if [[ "$output_mode" == "json" ]]; then
    emit_read_json "$resolved_path" "$content" "$bytes" "$lines"
  else
    printf '%s' "$content"
    if [[ "${content: -1}" != $'\n' ]]; then
      printf '\n'
    fi
  fi
  emit_op_event "ok" "read" "$resolved_path" "mode=$output_mode bytes=$bytes lines=$lines"
}

cmd_create() {
  local path content abs_path abs_dir
  path="$(resolve_inbox_note_path "$1")"
  content="$2"
  abs_path="$(resolve_vault_abs_path "$path")"
  abs_dir="$(dirname "$abs_path")"
  mkdir -p "$abs_dir"
  emit_op_event "start" "create" "$path" ""

  if [[ -f "$abs_path" ]]; then
    echo "create failed: note already exists at $path. Hint: choose a new note name and retry create. Use append only if you intend to modify this existing note." >&2
    exit 4
  fi

  log_action "create" "$path" ""
  {
    print_cli_allowed_frontmatter
    printf '%s\n' "$content"
  } >"$abs_path"

  # Best effort refresh so Obsidian picks up direct file writes quickly.
  obs reload >/dev/null 2>&1 || true
  printf 'created: %s\n' "$path"
  emit_op_event "ok" "create" "$path" "status=created"
}

cmd_append() {
  local path content abs_path
  path="$(resolve_inbox_note_path "$1")"
  content="$2"
  abs_path="$(resolve_vault_abs_path "$path")"
  emit_op_event "start" "append" "$path" ""

  if [[ ! -f "$abs_path" ]]; then
    echo "append failed: note does not exist at $path. Hint: use create to make it first." >&2
    exit 5
  fi

  ensure_cli_allowed_frontmatter "$abs_path"
  log_action "append" "$path" ""
  if [[ -s "$abs_path" ]] && [[ "$(tail -c 1 "$abs_path" 2>/dev/null || true)" != $'\n' ]]; then
    printf '\n' >>"$abs_path"
  fi
  printf '%s\n' "$content" >>"$abs_path"

  # Best effort refresh so Obsidian picks up direct file writes quickly.
  obs reload >/dev/null 2>&1 || true
  printf 'appended: %s\n' "$path"
  emit_op_event "ok" "append" "$path" "status=appended"
}

main() {
  if [[ -z "${VAULT_ARG//[[:space:]]/}" ]]; then
    echo "missing required env var: OBSIDIAN_SAFE_CLI_VAULT" >&2
    usage
    exit 1
  fi

  require_cmds "$OBS_BIN" jq

  if [[ "${1:-}" == "" ]]; then
    usage
    exit 1
  fi

  local cmd="$1"
  shift || true

  case "$cmd" in
  search)
    [[ $# -eq 1 ]] || { usage; exit 1; }
    cmd_search "$1"
    ;;
  search-context)
    [[ $# -eq 1 ]] || { usage; exit 1; }
    cmd_search_context "$1"
    ;;
  read)
    if [[ $# -eq 1 ]]; then
      cmd_read "text" "$1"
    elif [[ $# -eq 2 && "$1" == "--json" ]]; then
      cmd_read "json" "$2"
    else
      usage
      exit 1
    fi
    ;;
  create)
    [[ $# -eq 2 ]] || { usage; exit 1; }
    cmd_create "$1" "$2"
    ;;
  append)
    [[ $# -eq 2 ]] || { usage; exit 1; }
    cmd_append "$1" "$2"
    ;;
  *)
    echo "unknown command: $cmd" >&2
    usage
    exit 1
    ;;
  esac
}

main "$@"
