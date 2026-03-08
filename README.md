# obsidian-safe-cli

Lightweight policy wrapper around [Obsidian CLI](https://help.obsidian.md/cli) for agent-safe note access.

Built to work reliably with very weak agents too, including local LLMs. The command surface is intentionally small and outputs are structured for predictable parsing.

## policy

- Search is always gated by `[cli-allowed:true]`.
- Reads are blocked unless the note property `cli-allowed` is `true`.
- Writes are only allowed under `agent-inbox/`.
- All actions are appended to `obsidian-safe-cli-audit.log`.

## setup

```bash
chmod +x ./skills/obsidian-safe-cli/scripts/obsidian-safe-cli.sh
export PATH="./skills/obsidian-safe-cli/scripts:$PATH"
```

Required env vars:

- `OBSIDIAN_SAFE_CLI_VAULT`: vault name to target (no default).

Optional env vars:

- `OBSIDIAN_SAFE_CLI_OBS_BIN`: CLI binary path, defaults to `obsidian`.
- `OBSIDIAN_SAFE_CLI_DEFAULT_VAULT_PATH`: fallback vault path when CLI probe is empty.
- `OBSIDIAN_SAFE_CLI_INBOX_PREFIX`: writable prefix, defaults to `agent-inbox/`.
- `OBSIDIAN_SAFE_CLI_AUDIT_LOG`: audit log path, defaults to `./obsidian-safe-cli-audit.log`.
- `OBSIDIAN_SAFE_CLI_ALLOWED_PROP`: read/search access property, defaults to `cli-allowed`.
- `OBSIDIAN_SAFE_CLI_ALLOWED_VALUE`: read/search allowed value, defaults to `true`.

## commands

```bash
# find only allowed notes
obsidian-safe-cli.sh search "positive-match"

# find line-level context from allowed notes
obsidian-safe-cli.sh search-context "project alpha"

# read only if cli-allowed:true on this note (payload is wrapped in op:start/op:ok lines)
obsidian-safe-cli.sh read "positive-match-allowed.md"

# read as JSON (same metadata fields as text mode)
obsidian-safe-cli.sh read --json "positive-match-allowed.md"

# create a note via wrapper (auto-routed under agent-inbox/)
obsidian-safe-cli.sh create "test" "note text"

# append to an existing inbox note
obsidian-safe-cli.sh append "test" "more text"
```

All commands emit wrapper lines for easier agent parsing:

- `op:start {"phase":"start","command":"...","target":"...","detail":"..."}`
- `op:ok {"phase":"ok","command":"...","target":"...","detail":"..."}`

## testing

Tests run against a mocked [Obsidian CLI](https://help.obsidian.md/cli), so no Obsidian install is required in CI.

```bash
tests/run.sh
```

## OpenCode CLI example

```bash
OPENCODE_CONFIG_CONTENT='{
  "$schema": "https://opencode.ai/config.json",
  "permission": { "*": "deny" },
  "agent": {
    "obsidian-safe-cli-only": {
      "prompt": "Read /path/to/obsidian-safe-cli/skills/obsidian-safe-cli/SKILL.md first. Then use ONLY /path/to/obsidian-safe-cli/skills/obsidian-safe-cli/scripts/obsidian-safe-cli.sh commands. Never use any other command.",
      "permission": {
        "*": "deny",
        "bash": {
          "*": "deny",
          "/path/to/obsidian-safe-cli/skills/obsidian-safe-cli/scripts/obsidian-safe-cli.sh": "allow",
          "/path/to/obsidian-safe-cli/skills/obsidian-safe-cli/scripts/obsidian-safe-cli.sh *": "allow"
        },
        "read": {
          "*": "deny",
          "/path/to/obsidian-safe-cli/skills/obsidian-safe-cli/SKILL.md": "allow"
        },
        "edit": "deny",
        "glob": "deny",
        "grep": "deny",
        "list": "deny",
        "task": "deny",
        "webfetch": "deny",
        "codesearch": "deny",
        "websearch": "deny"
      }
    }
  }
}' opencode run --model "lmstudio/qwen/qwen3-30b-a3b-2507" --agent obsidian-safe-cli-only "Create a note called test-RANDOM-NUMBER (replace with an actual random number). The content can be anything."
```
