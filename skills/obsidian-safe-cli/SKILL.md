---
name: obsidian-safe-cli
description: Enforce least-privilege Obsidian note operations through obsidian-safe-cli.sh with per-note cli-allowed property gating and a minimal command API for weaker models. Use when working in an Obsidian vault that contains private notes and the user wants agent access only to explicitly authorized notes.
allowed-tools: Bash(obsidian-safe-cli.sh:*) Read
---

# Obsidian safe cli

Use this skill to operate on Obsidian notes only through `obsidian-safe-cli.sh` on PATH.

## required rules

- Never use raw `obsidian` commands when `obsidian-safe-cli.sh` can do the operation.
- Never read a note unless `obsidian-safe-cli.sh read <path>` allows it.
- Never use direct filesystem writes; always use `obsidian-safe-cli.sh create` or `obsidian-safe-cli.sh append`.
- Never use delete, move, rename, plugin install, or restore operations.
- Treat `cli-allowed` as the source of truth for read authorization.
- Keep an auditable trail by preserving `obsidian-safe-cli-audit.log`.
- Keep command usage simple; this API is intentionally small for weaker models.

## command map

- Discover allowed notes: `obsidian-safe-cli.sh search "<query>"`
- Retrieve context snippets from allowed notes: `obsidian-safe-cli.sh search-context "<query>"`
- List all 'agent inbox' notes: `obsidian-safe-cli.sh agent-inbox-list`
- Read one allowed note: `obsidian-safe-cli.sh read [--json] "<path>"`
- Create a new inbox note: `obsidian-safe-cli.sh create "<note-name>" "<content>"`
- Append to an existing inbox note: `obsidian-safe-cli.sh append "<note-name>" "<content>"`

## execution flow

1. Start with `obsidian-safe-cli.sh agent-inbox-list`, `obsidian-safe-cli.sh search`, or `obsidian-safe-cli.sh search-context`.
2. Read only files returned by allowed search using `obsidian-safe-cli.sh read`.
   Command output is wrapped with `op:start` and `op:ok` lines; use `--json` when structured output is easier.
3. Use `obsidian-safe-cli.sh create` for first-write and `obsidian-safe-cli.sh append` for follow-up writes.
4. Let the script route note writes into the configured inbox automatically.
5. If read is denied, stop and ask the user for explicit human authorization.

## failure handling

- If `obsidian-safe-cli.sh read` returns access denied, do not attempt alternate read paths.
- If `obsidian-safe-cli.sh` command is missing, ask the user to ensure `obsidian-safe-cli.sh` is available on PATH and continue with the same guardrails.
- If [Obsidian CLI](https://help.obsidian.md/cli) is unavailable, report the blocker and do not fall back to direct filesystem reads for protected notes.
- If `create` fails because note exists, choose a new note name and retry `create`.
- If `append` fails because note is missing, switch to `create`.

## examples

- User asks: "Find notes about project alpha I have approved."
- Action: `obsidian-safe-cli.sh search "project alpha"`

- User asks: "Summarize this note I approved."
- Action: `obsidian-safe-cli.sh read "<approved-path>"`, then summarize, then optionally `create "summary"`.
