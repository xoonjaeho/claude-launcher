---
name: claude-launcher
description: Open a new interactive Claude Code session in its own Windows Terminal tab — a chosen project directory, model, permission mode, effort and opening prompt — through claude-launcher's non-interactive mode. Use when the user asks to start, open or launch a Claude session for a project. Not for delegating work: headless runs are `claude -p` from Bash or the Agent tool. Windows only.
---

# /claude-launcher — launch an interactive Claude Code session

Runs `claude-launcher.ps1 -NoMenu` in a new Windows Terminal tab. The launcher validates the
choices, strips this session's `CLAUDE*` variables, and starts `claude` in the target directory.
The user follows the new session in the Claude iOS app (Remote Control is on by default) or in
the tab itself. The session belongs to the user: never type into it or read from it.

## Arguments

| Launcher arg | Value | Omitted |
|---|---|---|
| `-Path` | project directory, absolute, must exist | required |
| `-Model` | family alias from the launcher's catalog (`opus`, `sonnet`, …) | settings.json model |
| `-Mode` | `default` `plan` `acceptEdits` `dontAsk` `auto` `bypassPermissions` | settings.json `permissions.defaultMode` |
| `-Effort` | a level the model accepts, `auto`, or `ultracode` (switches to opus when the model lacks xhigh) | settings.json effort |
| `-PromptHex` | opening prompt as lowercase hex of its UTF-8 bytes | no opening prompt |

Pass only what the user asked for. Never fill an option the user did not state.

## Steps

1. **Encode the prompt** (skip when there is none). Hex survives Git Bash, `wt.exe` (which splits
   on `;`) and PowerShell unchanged, so the prompt needs no escaping and may span lines:

   ```bash
   P=$(cat <<'EOF'
   <opening prompt, verbatim>
   EOF
   )
   HEX=$(printf %s "$P" | od -An -v -tx1 | tr -d ' \n')
   ```

2. **Dry run** from Bash with the same arguments plus `-DryRun`. Single-quote every Windows path:

   ```bash
   powershell -NoProfile -File '<launcher-dir>\claude-launcher.ps1' \
     -NoMenu -DryRun -Path '<dir>' [-Model <alias>] [-Mode <mode>] [-Effort <level>] [-PromptHex "$HEX"]
   ```

   Exit 1 → show the stderr line to the user and stop. Exit 0 → parse the **last** stdout line as
   JSON (`cwd`, `argv`, `env`, `envRemoved`, `inheritedMode`); earlier lines may be catalog notices.

3. **Permission check.** The effective mode is the value after `--permission-mode` in `argv`, else
   `inheritedMode`. If it is `bypassPermissions` and the user did not name that mode for this launch,
   ask before step 4.

4. **Launch** — same arguments, without `-DryRun`:

   ```bash
   MSYS_NO_PATHCONV=1 wt.exe -w 0 new-tab -d '<dir>' --title '<project>' \
     powershell -NoProfile -ExecutionPolicy Bypass -File '<launcher-dir>\claude-launcher.ps1' \
     -NoMenu -Path '<dir>' [-Model <alias>] [-Mode <mode>] [-Effort <level>] [-PromptHex "$HEX"]
   ```

   `MSYS_NO_PATHCONV=1` keeps Git Bash from rewriting `/`-leading arguments. A path containing `;`
   cannot pass through `wt.exe`; tell the user instead of launching.

## Report

One line: directory, model, effective mode, whether an opening prompt was sent. Then emit
`app: claude session (WT tab, <dir>, pid unknown)` — `wt.exe` returns at once and reports no PID.
The session is the deliverable: leave it running, and do not count it as a process to stop.
