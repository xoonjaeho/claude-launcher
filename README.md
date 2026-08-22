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
▝▜█████▛▘  Opus 4.8 (1M) with ultracode effort · Claude Max
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

Sets `--model`. Offers `inherit` plus the model catalog: `opusplan`, Fable 5, Opus 4.8 /
4.7 (including 1M-context variants), Sonnet 5 and Sonnet 4.6 (each including a 1M
variant), Haiku 4.5, and the `fable` / `opus` / `sonnet` / `haiku` latest aliases.

### Effort tab

Sets the session effort level.

| Level | Behavior |
|-------|----------|
| **inherit** | Use the settings.json value |
| **auto** | Adaptive — Claude picks the effort per turn |
| **low** | Short, scoped, latency-sensitive tasks |
| **medium** | Reduced token use for cost-sensitive work |
| **high** | Balanced (default for Opus 4.8) |
| **xhigh** | The hardest tasks |
| **max** | Maximum reasoning; can hit diminishing returns |
| **ultracode** | `xhigh` plus standing dynamic workflow orchestration |

Most levels are passed with `--effort`. `auto` and `ultracode` are not accepted by
`--effort`, so the launcher injects them through a temporary `--settings` overlay
instead.

**ultracode** requires an xhigh-capable Opus or Fable model. If a non-capable model is
selected — Sonnet, Haiku, or `opusplan` (which runs Sonnet outside plan mode) — the
launcher overrides the model to Opus and prints a notice before launching; otherwise
ultracode would silently fall back to plain `xhigh`.

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
