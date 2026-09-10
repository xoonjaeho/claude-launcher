# Claude Launcher

A TUI launcher for the Claude Code CLI. Pick a project directory and configure the
session — permission mode, model, effort, and extras — from interactive menus.

## Files

| File | Role |
|------|------|
| `claude-launcher.bat` | Entry point. Runs the PowerShell script, then launches Claude Code in the chosen directory. |
| `claude-launcher.ps1` | TUI menus, theme detection, and the launch logic. |

`claude-launcher.bat` runs the script with `-FromBat`: the script writes the final
command to `%TEMP%\claude_launch.bat`, and the wrapper calls it. Running
`claude-launcher.ps1` directly launches Claude Code in-process instead.

## Running

### Direct

```
claude-launcher.bat
```

### From a shortcut

1. Create a shortcut to `claude-launcher.bat` wherever you like (e.g. the desktop).
2. Open the shortcut's properties and clear the **"Start in"** field.
3. While empty, the shortcut's own directory is used as the current path.

> **Note:** if "Start in" is not cleared, the launcher always starts from the .bat's
> original location.

## Screen

### Header

```
▐▛███▜▌   Claude Code v2.1.101
▝▜█████▛▘  Opus 5 with ultracode effort · Claude Max
  ▘▘ ▝▝    you@example.com
```

- Line 1: version (`claude --version`)
- Line 2: model, effort level, subscription type (`~/.claude/settings.json` + `claude auth status`)
- Line 3: email, organization (organization is omitted for personal accounts)

### Menu controls

| Key | Action |
|-----|--------|
| `↑` `↓` | Move between items |
| `1`-`9` | Jump to that item |
| `Enter` | Select the current item |
| `Esc` | Go back one step (quit at the top level) |
| Click | Select the item under the pointer — same as `Enter` |
| Wheel | Move between items |

## Tests

| Command | Covers |
|---------|--------|
| `claude-launcher.ps1 -SelfTest` | The pure parts: INPUT_RECORD decoding, viewport clamping, tab-bar column ranges. Fast, no console needed. |
| `claude-launcher.tests.ps1` | The rest: it starts a real launcher, writes console records into its input buffer, and reads the rendered screen back to assert. Runs `-SelfTest` first. |

The second one exists because the first cannot see a screen. Several defects found during the
mouse work were invisible to `-SelfTest`: a `return ,$segs` that made
`Get-TabSegments | Where-Object` receive one array instead of four segments, a `$r` loop counter
silently overwriting `$R`, the ANSI reset (PowerShell variable names are case-insensitive), and a
press queued before a screen change acting on the screen that replaced it.

Wheel scrolling needs a directory listing longer than the console, so the suite creates 60 empty
directories next to the launcher and removes them afterwards.

## Mouse

Every screen takes the mouse as well as the keyboard. `ReadKey` discards mouse events, so the
launcher reads console input records directly and turns on `ENABLE_MOUSE_INPUT`.

A single click is `Enter`. A click is the button's **0 → 1 transition**, not "the left bit is set":
`dwButtonState` reports the whole current mask, so holding left while clicking right reports
`1, 3, 1, 0` and testing the bit alone turned one gesture into three clicks. Double-click and
drag-move records update that state but never fire, so one physical gesture is one action.

Input queued **before** a screen change is discarded — the buffer is flushed as each screen takes
over. Without it, a press made before the transition was read by the *next* screen at stale
coordinates, and with click = Enter that cascaded. Type-ahead across a screen change goes too;
that is the intended trade.

The click that gives the console focus is still delivered, so on the configuration screen it can
launch a session.

Turning mouse input on also means drag-to-select is off **while a menu is up** — the terminal would otherwise swallow
every drag before the script saw it. The previous console mode is restored the moment a menu
exits, including on the `-FromBat` handoff, so copy/paste in the Claude session is untouched.

## Flow

The launcher runs in one of two modes, depending on where it starts.

### Inside a known project

Started in a directory (or subdirectory) that has session history under
`~/.claude/projects/`.

```
directory ──→ configure ──→ launch
    ↑             │
    └──── Esc ────┘
```

- Lists the current directory and its subdirectories.
- `🔍 Browse` walks the file system.

### Outside a known project

Started somewhere not covered by a known project.

```
project ──→ subdirectory ──→ configure ──→ launch
   ↑             │                │
   └──── Esc ────┘                │
                 ↑                │
                 └──── Esc ───────┘
```

- The project list is auto-discovered from `~/.claude/projects/`.
- Pick a project, then a subdirectory.
- `Esc` steps back at each stage.

### Browse mode

Selecting `🔍 Browse` opens a file-system tree browser.

| Key | Action |
|-----|--------|
| `↑` `↓` | Move |
| `Enter` | Open directory |
| `Space` | Select the current directory |
| `Esc` | Back |
| Click | Open the entry under the pointer — same as `Enter` |
| Wheel | Scroll the list |

Long directories are windowed to the console height, with a `12-33 / 88` position line under
the list. `Space` selects the *current* directory and has no mouse equivalent.

## Tabbed configuration

Once a directory is chosen, a tabbed screen configures the session. Each tab maps to a
Claude Code option.

| Key | Action |
|-----|--------|
| `←` `→` | Switch tab |
| `↑` `↓` | Move within a tab |
| `1`-`9` | Jump to an item |
| `Space` | Toggle an extra — or cycle the Color option (Extras tab only) |
| `Enter` | Launch with the current selection |
| `Esc` | Back |
| Click on the tab bar | Switch to that tab |
| Click on an item | Launch with that item selected — or, on the Extras tab, toggle it |
| | (the footer says `[Enter] launch` on Extras and `[Enter/click] launch` elsewhere, to match) |
| Wheel | Move within a tab |

A click is `Enter`, so on a single-select tab it picks the item **and launches**. Extras rows are
checkboxes; a click there toggles instead, or the boxes would have no mouse equivalent at all.

Every single-select tab has an **inherit** option that leaves the corresponding
`~/.claude/settings.json` value untouched (no flag is passed).

The bottom line always shows what **every** tab currently holds, so launching never
depends on tabbing back to check:

```
Permission bypassPermissions · Model Opus 5 · Effort ultracode · Extras IDE · Tab ● Blue · Background ● Green
```

Extras collapse to a count past two items, and if the window is too narrow for the field
labels only the values are shown.

### Permission tab

Sets `--permission-mode`.

| Mode | Behavior |
|------|----------|
| **inherit** | Use the Claude Code / settings.json default |
| **default** | Ask for approval on unmatched tools |
| **plan** | Planning only — no tool execution |
| **acceptEdits** | Auto-approve file edits and filesystem commands |
| **dontAsk** | Deny any tool not pre-approved |
| **auto** | A model classifier auto-approves safe actions |
| **bypassPermissions** | Bypass all permission checks (trusted environments only) |

### Model tab

Sets `--model`. Offers `inherit` plus Fable, Opus, Sonnet and Haiku, read out of the installed
`claude` binary's own model catalog and cached per build, so a model release shows up without
editing this launcher. Each row passes the bare family alias and is labelled with whatever that
alias currently launches — which depends on the backend, so the same Sonnet row reads "Sonnet 5"
on Anthropic's API and "Sonnet 4.5" with `CLAUDE_CODE_USE_BEDROCK` set. A saved choice therefore
keeps meaning "the newest one" across releases.

If the catalog cannot be read — an unreadable binary, or an npm install whose bundle is not where
this expects — the rows lose their version numbers and everything else still works. A choice saved
by a launcher older than this one is folded onto its family alias when that is what it meant; a
pinned older model or a `[1m]` context variant is not, because no row can express it, so those
reopen on `inherit` — and the next save drops them — rather than silently becoming the newest
model of the family.

### Effort tab

Sets the session effort level. The rows are per-model: the same scan that reads the model
catalog also reads which levels each model accepts, which one it starts at, and what each
costs relative to `high`. Moving the cursor on the Model tab rebuilds this one, and a level
the model does not accept is left out rather than shown greyed. Haiku 4.5 has no effort
control at all, so it offers only `inherit` and `auto`.

| Level | Behavior |
|-------|----------|
| **inherit** | Use the settings.json value |
| **auto** | Adaptive — Claude picks the effort per turn |
| **low** | Short, scoped, latency-sensitive tasks |
| **medium** | Reduced token use for cost-sensitive work |
| **high** | Balanced intelligence for everyday work |
| **xhigh** | Deeper reasoning for the hardest tasks |
| **max** | Maximum reasoning; can hit diminishing returns |
| **ultracode** | `xhigh` plus standing dynamic workflow orchestration |

`(default)` marks the level Claude Code itself would pick for that model, and the percentage
is that model's own cost index for the level, with `high` as 100%:

```
   1. inherit
   2. auto             — Adaptive — Claude picks effort per turn
   3. low              — 67% Short, scoped, latency-sensitive tasks
   4. medium           — 76% Reduced token usage for cost-sensitive work
   5. high (default)   — 100% Balanced intelligence for everyday work
   6. xhigh            — 160% Deeper reasoning for the hardest tasks
   7. max              — 170% Maximum reasoning; may lead to diminishing returns
   8. ultracode        — xhigh + standing dynamic workflows
```

The percentages differ per model — Sonnet 5 prices `xhigh` at 241% and `max` at 559%, Opus 5
at 160% and 170% — which is the reason they are shown at all. A Claude Code the launcher cannot
read costs the menu its percentages and its `(default)` marker, not its rows: the full ladder is
offered, as it was before any of this was read. The ultracode guard below falls back with it, to
its old Opus-or-Fable rule — so in that state a Sonnet 5 session that picks ultracode is still
switched to Opus even though the menu offered it.

Most levels are passed with `--effort`. `auto` and `ultracode` are not accepted by
`--effort`, so the launcher injects them through a temporary `--settings` overlay
instead.

**ultracode** requires an xhigh-capable model, which the catalog names — Fable, Opus and
Sonnet 5 all qualify. If a non-capable model is in effect — Haiku, or an `opusplan` inherited
from `settings.json`, which runs Sonnet outside plan mode — the launcher overrides the model
to Opus and prints a notice before launching; otherwise ultracode would silently fall back to
plain `xhigh`.

### Extras tab

Multi-select (toggle with `Space`). Each enabled item appends its CLI flag. The selection
is remembered per directory, so the tab comes back the way it was left.

| Extra | Flag | Purpose |
|-------|------|---------|
| **IDE** | `--ide` | Auto-connect to the IDE on startup |
| **Chrome** | `--chrome` | Enable Chrome integration (beta) |
| **Telegram** | `--channels plugin:telegram@claude-plugins-official` | Load the Telegram channel plugin |
| **Remote** | `--remote-control` | Enable Remote Control (drive the session from another device) |
| **Verbose** | `--verbose` | Verbose logging |
| **Bare** | `--bare` | Skip hooks, LSP, plugins, and CLAUDE.md discovery |
| **Safe** | `--safe-mode` | Disable all customizations for troubleshooting (broader than Bare) |
| **Cache** | `--exclude-dynamic-system-prompt-sections` | Move per-machine context to the first message for cache reuse |
| **Brief** | `--brief` | Enable the SendUserMessage tool (agent-to-user messages mid-task) |
| **Prompts** | `--prompt-suggestions` | Suggest a predicted next prompt each turn |
| **Tab color** | — | Tab color, Windows Terminal only |
| **Background** | — | Background tint |

#### Tab color and Background

Neither passes a flag — they color the terminal itself, independently, and `Space` cycles
each one: `off → random → each palette color → off`.

| Option | Sequence | Applies to |
|--------|----------|------------|
| **Tab color** | `OSC 4` on color-table slot 264 | Windows Terminal. Emitted unconditionally — a legacy console prints nothing for it, it just recolors that console's cursor |
| **Background** | `OSC 11`, at 35% of the palette color | Any VT-capable console; kept dark or the text stops being readable |

Both are emitted before Claude Code starts and stay in effect for the whole session.
Setting either back to `off` emits a reset (`OSC 104;264` / `OSC 111`), so relaunching in a
tab that already carries a color clears it instead of leaving the old one behind.

> Do not gate the tab sequence on `WT_SESSION`. That variable is set only when Windows
> Terminal starts the shell from one of its profiles. Started from a shortcut, the console
> is still hosted by Windows Terminal and still has a tab, but the variable is empty.

> In Windows Terminal the default theme derives the tab color from the terminal
> background, so setting **Background** alone also tints the tab. Set **Tab color** to
> override it.

**A random pick never reuses a color a live session already holds.** Handed-out colors are
recorded in `~/.claude/claude-launcher-colors.json` against the owning process (PID *and*
start time, so a recycled PID cannot keep holding a color); entries whose process is gone
are pruned on the next pick. Only sessions this launcher started are tracked — a tab opened
by hand carries no custom color to clash with. If the whole palette is taken, one is reused.

### Saved choices

Every tab's selection is stored per directory in `~/.claude/claude-launcher.json` and
pre-selected the next time that directory is launched.

Colors are saved as the *choice*, not the resolved color: a directory left on `random`
rolls a fresh non-clashing color on every launch, while a directory pinned to `Teal` comes
back Teal.

## Themes

Uses the same theme detection as Claude Code:

1. `outputStyle` in `~/.claude/settings.json`
2. `dark` / `light` from the `COLORFGBG` environment variable
3. Default: `dark`

Supported themes: `dark`, `light`, `light-daltonized`, `dark-daltonized`.

## Customization

### Project icons

Map directory names to emojis in the `$icons` hashtable in `claude-launcher.ps1`:

```powershell
$icons = @{ "my-game" = "🎮"; "my-api" = "🌐" }
```
