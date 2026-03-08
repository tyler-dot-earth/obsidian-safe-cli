#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT_DIR/skills/obsidian-safe-cli/scripts/obsidian-safe-cli.sh"
MOCK_OBS="$ROOT_DIR/tests/mock-obsidian.sh"

fail() {
  echo "test failed: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "expected output to contain: $needle"
  fi
}

assert_exit_code() {
  local actual="$1"
  local expected="$2"
  if [[ "$actual" != "$expected" ]]; then
    fail "expected exit code $expected, got $actual"
  fi
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

vault_dir="$tmp_dir/vault"
mkdir -p "$vault_dir"

export MOCK_VAULT_PATH="$vault_dir"
export OBSIDIAN_SAFE_CLI_OBS_BIN="$MOCK_OBS"
export OBSIDIAN_SAFE_CLI_VAULT="test-vault"
export OBSIDIAN_SAFE_CLI_DEFAULT_VAULT_PATH="$vault_dir"
export OBSIDIAN_SAFE_CLI_AUDIT_LOG="$tmp_dir/audit.log"

chmod +x "$MOCK_OBS" "$CLI"

echo "running: create succeeds and emits wrappers"
create_out="$("$CLI" create "ci-note-1" "hello world")"
assert_contains "$create_out" 'op:start {"phase":"start","command":"create","target":"agent-inbox/ci-note-1.md"'
assert_contains "$create_out" 'created: agent-inbox/ci-note-1.md'
assert_contains "$create_out" 'op:ok {"phase":"ok","command":"create","target":"agent-inbox/ci-note-1.md","detail":"status=created"}'

note_file="$vault_dir/agent-inbox/ci-note-1.md"
[[ -f "$note_file" ]] || fail "expected created note file"
grep -q '^cli-allowed: true$' "$note_file" || fail "expected cli-allowed frontmatter"

echo "running: create collision returns code 4 with hint"
set +e
collision_out="$("$CLI" create "ci-note-1" "duplicate content" 2>&1)"
collision_rc=$?
set -e
assert_exit_code "$collision_rc" "4"
assert_contains "$collision_out" "create failed: note already exists at agent-inbox/ci-note-1.md"
assert_contains "$collision_out" "choose a new note name and retry create"

echo "running: append missing returns code 5"
set +e
append_missing_out="$("$CLI" append "missing-note" "text" 2>&1)"
append_missing_rc=$?
set -e
assert_exit_code "$append_missing_rc" "5"
assert_contains "$append_missing_out" "append failed: note does not exist at agent-inbox/missing-note.md"

echo "running: append succeeds and emits wrappers"
append_out="$("$CLI" append "ci-note-1" "second line")"
assert_contains "$append_out" 'op:start {"phase":"start","command":"append","target":"agent-inbox/ci-note-1.md","detail":""}'
assert_contains "$append_out" 'appended: agent-inbox/ci-note-1.md'
assert_contains "$append_out" 'op:ok {"phase":"ok","command":"append","target":"agent-inbox/ci-note-1.md","detail":"status=appended"}'
grep -q "second line" "$note_file" || fail "expected appended content"

echo "running: read fallback resolves inbox path and emits wrappers"
read_out="$("$CLI" read "ci-note-1")"
assert_contains "$read_out" 'op:start {"phase":"start","command":"read","target":"agent-inbox/ci-note-1.md","detail":"mode=text"}'
assert_contains "$read_out" "hello world"
assert_contains "$read_out" "second line"
assert_contains "$read_out" 'op:ok {"phase":"ok","command":"read","target":"agent-inbox/ci-note-1.md","detail":"mode=text'

echo "running: read --json returns structured payload and wrappers"
read_json_out="$("$CLI" read --json "ci-note-1")"
read_json_payload="$(printf '%s\n' "$read_json_out" | sed -n '2p')"
assert_contains "$read_json_out" 'op:start {"phase":"start","command":"read","target":"agent-inbox/ci-note-1.md","detail":"mode=json"}'
printf '%s' "$read_json_payload" | jq -e '.status=="ok" and .command=="read" and .path=="agent-inbox/ci-note-1.md" and (.content | contains("hello world"))' >/dev/null || fail "invalid read --json payload"
assert_contains "$read_json_out" 'op:ok {"phase":"ok","command":"read","target":"agent-inbox/ci-note-1.md","detail":"mode=json'

echo "running: search emits wrappers and json payload"
search_out="$("$CLI" search "hello world")"
search_payload="$(printf '%s\n' "$search_out" | sed -n '2p')"
assert_contains "$search_out" 'op:start {"phase":"start","command":"search","target":"","detail":"[cli-allowed:true] (hello world)"}'
printf '%s' "$search_payload" | jq -e 'type=="array" and length >= 1' >/dev/null || fail "invalid search payload"
assert_contains "$search_out" 'op:ok {"phase":"ok","command":"search","target":"","detail":"results='

echo "running: search-context emits wrappers and json payload"
search_ctx_out="$("$CLI" search-context "hello world")"
search_ctx_payload="$(printf '%s\n' "$search_ctx_out" | sed -n '2p')"
assert_contains "$search_ctx_out" 'op:start {"phase":"start","command":"search-context","target":"","detail":"[cli-allowed:true] (hello world)"}'
printf '%s' "$search_ctx_payload" | jq -e 'type=="array"' >/dev/null || fail "invalid search-context payload"
assert_contains "$search_ctx_out" 'op:ok {"phase":"ok","command":"search-context","target":"","detail":"results='

echo "running: read denied returns code 2 with hint"
printf '%s\n' "plain content" >"$vault_dir/private.md"
set +e
denied_out="$("$CLI" read "private" 2>&1)"
denied_rc=$?
set -e
assert_exit_code "$denied_rc" "2"
assert_contains "$denied_out" "access denied: private is not cli-allowed:true"
assert_contains "$denied_out" "try reading agent-inbox/private.md"

echo "all tests passed"
