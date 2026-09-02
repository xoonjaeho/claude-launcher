param([switch]$FromBat, [switch]$SelfTest)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$ESC = [char]27

# --- Theme detection (matches Claude Code logic) ---
$B   = "$ESC[1m"
$IN = "$ESC[2m"
$R   = "$ESC[0m"

function Get-ClaudeTheme {
    # 1. Check settings.json for explicit theme
    $settingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"
    if (Test-Path $settingsPath) {
        try {
            $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
            if ($settings.outputStyle) { return $settings.outputStyle }
        } catch {}
    }
    # 2. Check COLORFGBG (same logic as Claude Code)
    $cfg = $env:COLORFGBG
    if ($cfg) {
        $parts = $cfg -split ";"
        $bg = [int]$parts[-1]
        if ($bg -ge 0 -and $bg -le 15) {
            if ($bg -le 6 -or $bg -eq 8) { return "dark" } else { return "light" }
        }
    }
    # 3. Default to dark
    return "dark"
}

$theme = Get-ClaudeTheme

# --- Colors (Claude Code theme) ---
$themes = @{
    dark = @{
        claude     = "215;119;87";   text       = "255;255;255"
        inactive   = "153;153;153";  suggestion = "177;185;249"
        success    = "78;186;101";   error      = "255;107;128"
        warning    = "255;193;7";    autoAccept = "175;135;255"
        planMode   = "72;150;140";   permission = "177;185;249"
    }
    light = @{
        claude     = "215;119;87";   text       = "0;0;0"
        inactive   = "102;102;102";  suggestion = "87;105;247"
        success    = "44;122;57";    error      = "171;43;63"
        warning    = "150;108;30";   autoAccept = "135;0;255"
        planMode   = "0;102;102";    permission = "87;105;247"
    }
    "light-daltonized" = @{
        claude     = "255;153;51";   text       = "0;0;0"
        inactive   = "102;102;102";  suggestion = "51;102;255"
        success    = "0;102;153";    error      = "204;0;0"
        warning    = "255;153;0";    autoAccept = "135;0;255"
        planMode   = "51;102;102";   permission = "51;102;255"
    }
    "dark-daltonized" = @{
        claude     = "255;153;51";   text       = "255;255;255"
        inactive   = "153;153;153";  suggestion = "153;204;255"
        success    = "51;153;255";   error      = "255;102;102"
        warning    = "255;204;0";    autoAccept = "175;135;255"
        planMode   = "102;153;153";  permission = "153;204;255"
    }
}

$t = if ($themes.ContainsKey($theme)) { $themes[$theme] } else { $themes["dark"] }

$CL  = "$ESC[38;2;$($t.claude)m"       # claude brand
$WH  = "$ESC[38;2;$($t.text)m"         # text
$BL  = "$ESC[38;2;$($t.suggestion)m"   # suggestion / selection
$GN  = "$ESC[38;2;$($t.success)m"      # success
$OR  = "$ESC[38;2;$($t.warning)m"      # warning
$RD  = "$ESC[38;2;$($t.error)m"        # error
$PR  = "$ESC[38;2;$($t.autoAccept)m"   # autoAccept / merged
$IN  = "$ESC[38;2;$($t.inactive)m"     # inactive / secondary text

# --- Effort & Model colors (fixed, matches statusline.py) ---
# Kept independent of the theme map so the launcher and statusline agree visually.
$EffortColors = @{
    "auto"   = "$ESC[38;2;125;207;255m"   # adaptive cyan
    "low"    = "$ESC[38;2;255;193;7m"     # warning amber
    "medium" = "$ESC[38;2;78;186;101m"    # success green
    "high"   = "$ESC[38;2;177;185;249m"   # permission indigo
    "xhigh"  = "$ESC[38;2;175;135;255m"   # autoAccept purple
    "max"    = "$ESC[38;2;235;95;87m"     # rainbow_red (static approx)
    "ultracode" = "$ESC[38;2;236;72;153m" # magenta (top tier: xhigh + workflows)
}
$ModelColors = @{
    "fable"  = "$ESC[38;2;229;192;123m"   # gold (newest flagship)
    "opus"   = "$ESC[38;2;215;119;87m"    # Claude brand orange
    "sonnet" = "$ESC[38;2;122;162;247m"   # blue
    "haiku"  = "$ESC[38;2;125;207;255m"   # cyan
}
# Menu order, and the only families the launcher colors. Get-ModelCatalog resolves each one
# to the model that family's alias currently launches, as the installed Claude Code defines it.
$ModelTiers = @("fable", "opus", "sonnet", "haiku")

# A family alias resolves to a different model per backend, so the label has to follow the same
# table the CLI does. Each CLAUDE_CODE_USE_<X> maps to the catalog per_provider key <x>.
$ModelProviders = @("BEDROCK", "VERTEX", "FOUNDRY", "MANTLE", "GATEWAY", "ANTHROPIC_AWS", "ANTHROPIC_GOOGLE_CLOUD")

# The ids the Model menu offered before it switched to family aliases. Each one meant "newest of
# this family" when it was saved, so folding it onto the alias preserves the choice. Anything
# else an older launcher wrote -- a pinned older model, or a [1m] context variant -- means
# something this menu cannot express, and is left to miss and fall back to inherit rather than
# silently become the newest model of its family.
$LegacyModelIds = @{
    "claude-fable-5"            = "fable"
    "claude-opus-5"             = "opus"
    "claude-sonnet-5"           = "sonnet"
    "claude-haiku-4-5-20251001" = "haiku"
}

# --- Tab / background color (Extras > Color) ---
# Windows Terminal takes the tab color from color-table slot 264 (OSC 4); a plain console
# has no tab, so it gets a dark OSC 11 background tint instead. Both are in-band, so the
# sequence is emitted from this console and survives into the launched session.
$tabPalette = @(
    @{ name = "Red";    rgb = "230;108;129" }
    @{ name = "Orange"; rgb = "215;119;87"  }
    @{ name = "Amber";  rgb = "255;193;7"   }
    @{ name = "Green";  rgb = "78;186;101"  }
    @{ name = "Teal";   rgb = "72;150;140"  }
    @{ name = "Cyan";   rgb = "125;207;255" }
    @{ name = "Blue";   rgb = "122;162;247" }
    @{ name = "Indigo"; rgb = "177;185;249" }
    @{ name = "Purple"; rgb = "175;135;255" }
    @{ name = "Pink";   rgb = "236;72;153"  }
)

function Get-OscColor {
    param([string]$Rgb, [double]$Scale = 1.0)
    $p = $Rgb -split ';'
    return ("rgb:{0:x2}/{1:x2}/{2:x2}" -f [int]([int]$p[0]*$Scale), [int]([int]$p[1]*$Scale), [int]([int]$p[2]*$Scale))
}

# Colors handed out to still-running sessions, so a random pick never clashes with an open tab.
# Only tabs this launcher started are known — a hand-opened tab carries no custom color anyway.
$colorStatePath = Join-Path $env:USERPROFILE ".claude\claude-launcher-colors.json"

function ConvertTo-LiveTabColors {
    # PID *and* process start time: a reused PID must not keep holding someone else's color.
    # Takes text, not a path, so Reserve-TabColor can pass what it read through its own
    # exclusive handle instead of reopening the file underneath itself. Both callers read
    # through a BOM-detecting reader, so the UTF-8 BOM older state files carry is gone by here.
    param([string]$Raw)
    $live = @{}
    if (-not $Raw) { return $live }
    try {
        $obj = $Raw | ConvertFrom-Json
        $obj.PSObject.Properties | ForEach-Object {
            $prop = $_
            try {
                $proc = Get-Process -Id ([int]$prop.Name) -ErrorAction SilentlyContinue
                if ($proc -and "$($proc.StartTime.Ticks)" -eq "$($prop.Value.start)") { $live[$prop.Name] = $prop.Value }
            } catch {}
        }
    } catch {}
    return $live
}

function Get-LiveTabColors {
    # Retry briefly: Reserve-TabColor holds the file exclusively while it rewrites, and a
    # sharing violation here would otherwise read as "no colors in use".
    for ($i = 0; $i -lt 10; $i++) {
        if (-not (Test-Path $colorStatePath)) { return @{} }
        try { return ConvertTo-LiveTabColors ([System.IO.File]::ReadAllText($colorStatePath, [System.Text.Encoding]::UTF8)) }
        catch [System.IO.IOException] { Start-Sleep -Milliseconds 30 }
        catch { return @{} }
    }
    return @{}
}

function Get-UsedTabColors {
    $used = @()
    (Get-LiveTabColors).Values | ForEach-Object { $used += @($_.colors) }
    return @($used | Where-Object { $_ })
}

function Reserve-TabColor {
    param([int]$OwnerPid, [string[]]$Names)
    $proc = Get-Process -Id $OwnerPid -ErrorAction SilentlyContinue
    if (-not $proc) { return }
    try {
        $dir = Split-Path $colorStatePath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # One exclusive handle held across BOTH the read and the write. Reading and writing
        # separately lets two launchers that start together each read the old file, and the
        # second write then drops the first one's reservation.
        $fs = $null
        for ($i = 0; $i -lt 20 -and -not $fs; $i++) {
            try { $fs = [System.IO.File]::Open($colorStatePath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) }
            catch [System.IO.IOException] { Start-Sleep -Milliseconds 50 }
        }
        # ponytail: a lost reservation only costs a duplicate color, so give up rather than
        # stall the launch behind another launcher that is wedged.
        if (-not $fs) { return }
        try {
            $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            $live = ConvertTo-LiveTabColors $reader.ReadToEnd()
            $live["$OwnerPid"] = @{ colors = @($Names); start = "$($proc.StartTime.Ticks)" }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes(($live | ConvertTo-Json -Depth 4))
            # Truncate-then-write leaves the file empty if Write fails. Accepted: Set-Content
            # had the same window, an unreadable file reads as "nothing reserved", and the next
            # launch rewrites it -- a compensating write would fail for the same reason.
            $fs.SetLength(0)
            $fs.Position = 0
            $fs.Write($bytes, 0, $bytes.Length)
        } finally { $fs.Dispose() }
    } catch {}
}

function Select-TabColor {
    param([string[]]$Used)
    $free = @($tabPalette | Where-Object { $Used -notcontains $_.name })
    # ponytail: palette exhausted → reuse one; a duplicate beats no color at all.
    if ($free.Count -eq 0) { $free = $tabPalette }
    return $free[(Get-Random -Maximum $free.Count)]
}

# --- Console input: keyboard + mouse ---
# $Host.UI.RawUI.ReadKey() reads console input records and then DISCARDS every mouse event, so
# mouse support means reading the records directly. ENABLE_EXTENDED_FLAGS *without*
# ENABLE_QUICK_EDIT_MODE is what turns drag-to-select off; leave quick edit on and the terminal
# eats every drag before the script sees it. ENABLE_PROCESSED_INPUT stays set or Ctrl+C dies.
if (-not ('CL.Con' -as [type])) {
    Add-Type -Namespace CL -Name Con -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(IntPtr hHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(IntPtr hHandle, uint dwMode);
[DllImport("kernel32.dll", SetLastError = true, EntryPoint = "ReadConsoleInputW")]
public static extern bool ReadConsoleInput(IntPtr hHandle, byte[] lpBuffer, uint nLength, out uint lpNumberOfEventsRead);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool FlushConsoleInputBuffer(IntPtr hHandle);
'@
}

$STDIN_HANDLE = [CL.Con]::GetStdHandle(-10)
$MOUSE_MODE   = 0x0001 -bor 0x0010 -bor 0x0080   # PROCESSED_INPUT | MOUSE_INPUT | EXTENDED_FLAGS
$inputRecord  = New-Object byte[] 20             # sizeof(INPUT_RECORD) on x86 and x64 alike
$savedMode    = $null                            # $null, not 0: a real mode of 0 must still restore
$leftButtonDown = $false                         # see ConvertFrom-InputRecord: clicks are transitions

# Enable/Restore are called from each menu loop's own try/finally instead of once around the
# whole script: there are three top-level `exit 0` paths, and under -FromBat the SAME console is
# handed to cmd.exe. A mode left unrestored follows the user into the Claude session with
# drag-select still disabled.
function Enable-MouseInput {
    # Save the caller's mode ONCE. Re-saving on every entry means that if a restore ever fails, the
    # next entry captures the MOUSE mode as though it were the user's, and every later "restore"
    # then restores mouse mode -- the original is gone and the console never recovers.
    if ($null -eq $script:savedMode) {
        $mode = [uint32]0
        if (-not [CL.Con]::GetConsoleMode($STDIN_HANDLE, [ref]$mode)) { return $false }
        $script:savedMode = $mode
    }
    $script:leftButtonDown = $false
    # Anything queued was aimed at the screen that just closed. Without this, a press the user
    # made before the transition is read HERE and acts on this screen at stale coordinates --
    # measured: a queued press opened a directory on the browser that a menu click had just
    # opened. Keystrokes go too; type-ahead across a screen change is not a feature worth a
    # misfired launch.
    [void][CL.Con]::FlushConsoleInputBuffer($STDIN_HANDLE)
    return [CL.Con]::SetConsoleMode($STDIN_HANDLE, $MOUSE_MODE)
}

function Restore-ConsoleMode {
    if ($null -ne $script:savedMode) { [CL.Con]::SetConsoleMode($STDIN_HANDLE, $script:savedMode) | Out-Null }
}

# Decodes one INPUT_RECORD. $null means "nothing a menu acts on" -- a key-up, a button-up, or a
# plain pointer move. Those must be swallowed here: with ENABLE_MOUSE_INPUT every pixel of
# pointer travel is an event, and returning them would repaint the menu continuously.
function ConvertFrom-InputRecord {
    param([byte[]]$Rec)
    switch ([BitConverter]::ToUInt16($Rec, 0)) {
        1 {   # KEY_EVENT: bKeyDown is a 4-byte BOOL at 4, VK at 10, UnicodeChar at 14
            if ($Rec[4] -eq 0) { return $null }
            return @{ Kind = "key"
                      Vk   = [BitConverter]::ToUInt16($Rec, 10)
                      Char = [char][BitConverter]::ToUInt16($Rec, 14) }
        }
        2 {   # MOUSE_EVENT: COORD at 4 (X) / 6 (Y), dwButtonState at 8, dwEventFlags at 16
            $flags = [BitConverter]::ToUInt32($Rec, 16)
            # MOUSE_WHEELED carries a SIGNED delta in the button-state high word; read it as
            # Int32 and shift, or wheel-down comes back as a large positive number. Its button
            # field is not a plain mask, so leave the click state alone on this branch.
            if ($flags -eq 4) { return @{ Kind = "wheel"; Delta = [BitConverter]::ToInt32($Rec, 8) -shr 16 } }
            # dwButtonState is the CURRENT full button mask, not the button that just changed.
            # Holding left while clicking right reports 1, 3, 1, 0 -- three of those have the left
            # bit set, and testing the bit alone turned ONE gesture into THREE clicks (measured).
            # A click is the 0 -> 1 transition. Track it on every non-wheel record, moves included,
            # so a release that lands outside the window still clears the state.
            $down    = ([BitConverter]::ToUInt32($Rec, 8) -band 1) -ne 0
            $wasDown = $script:leftButtonDown
            $script:leftButtonDown = $down
            # Only flags 0 reports a click. MOUSE_MOVED (1) would fire on a drag that entered the
            # window already pressed; DOUBLE_CLICK (2) would fire a second time on whatever screen
            # the first click just opened -- one physical double-click stays one action.
            if ($down -and -not $wasDown -and $flags -eq 0) {
                # ponytail: dwMousePosition is documented as screen-BUFFER coordinates, the same
                # space as [Console]::CursorTop. Should a host ever report window-relative rows,
                # adding [Console]::WindowTop to Row right here is the entire fix.
                return @{ Kind = "click"
                          Row  = [BitConverter]::ToInt16($Rec, 6)
                          Col  = [BitConverter]::ToInt16($Rec, 4) }
            }
        }
    }
    return $null
}

function Read-Input {
    while ($true) {
        $read = [uint32]0
        if (-not [CL.Con]::ReadConsoleInput($STDIN_HANDLE, $inputRecord, 1, [ref]$read)) { throw "console input unavailable" }
        $ev = ConvertFrom-InputRecord $inputRecord
        if ($ev) { return $ev }
    }
}

# The tab bar's text and each tab's column range, from one place, so what gets drawn and what a
# click lands on cannot drift apart. Columns are 0-based and the bar is indented three spaces.
function Get-TabSegments {
    param([string[]]$Names, [int]$Active, [int]$StartX = 3)
    $x = $StartX
    $segs = @()
    for ($i = 0; $i -lt $Names.Count; $i++) {
        $text = if ($i -eq $Active) { "[ $($Names[$i]) ]" } else { "   $($Names[$i])   " }
        $segs += @{ Index = $i; Text = $text; Start = $x; End = $x + $text.Length - 1 }
        $x += $text.Length + 2
    }
    return $segs
}

# Smallest scroll offset that keeps $Cursor inside a $ViewH-row window over $Count items.
function Get-Scroll {
    param([int]$Cursor, [int]$Scroll, [int]$ViewH, [int]$Count)
    $max = [Math]::Max(0, $Count - $ViewH)
    if ($Scroll -gt $max)             { $Scroll = $max }
    if ($Cursor -lt $Scroll)          { $Scroll = $Cursor }
    if ($Cursor -ge $Scroll + $ViewH) { $Scroll = $Cursor - $ViewH + 1 }
    return $Scroll
}

# Claude Code carries its model catalog inside the binary: {id,family,display_name} records, plus
# an `aliases` table saying what each family alias resolves to on each backend. Reading it there
# is what keeps this launcher off a hand-maintained list that goes stale on every model release.
# `aliases` is the source and `latest_per_family` is not: on Bedrock, `--model sonnet` launches
# Sonnet 4.5 while latest_per_family still says Sonnet 5, so the menu would label the row wrong.
# Families resolve independently -- one family the binary describes oddly costs that row its
# version number, never the other three. $null means nothing parsed at all.
function Parse-ModelCatalog {
    param([string]$Text, [string]$Provider)
    $names = @{}
    $families = @{}
    foreach ($m in [regex]::Matches($Text, '\{id:"(?<id>claude-[a-z0-9-]+)",family:"(?<fam>[a-z]+)",display_name:"(?<name>[^"]+)"')) {
        $id = $m.Groups["id"].Value
        $names[$id]    = $m.Groups["name"].Value
        $families[$id] = $m.Groups["fam"].Value
    }
    # Bounded lazy match: the empty `aliases:{}` schema default cannot start with a family entry so
    # the engine walks past it, and the cap stops a missing terminator from dragging over 200 MB.
    $block = [regex]::Match($Text, 'aliases:\{(?<b>[a-z]+:\{default:"claude-.{0,4000}?)\},defaults:')
    $latest = @{}
    foreach ($m in [regex]::Matches($block.Groups["b"].Value, '(?<fam>[a-z]+):\{default:"(?<def>[^"]+)"(?:,per_provider:\{(?<pp>[^{}]*)\})?\}')) {
        $fam = $m.Groups["fam"].Value
        $id  = $m.Groups["def"].Value
        if ($Provider) {
            $hit = [regex]::Match($m.Groups["pp"].Value, '(?:^|,)' + [regex]::Escape($Provider) + ':"(?<v>[^"]+)"')
            if ($hit.Success) { $id = $hit.Groups["v"].Value }
        }
        # A record whose own family contradicts the alias key would put "Opus 5" on the Fable row.
        # An id with no record at all fails the same test, since both maps are filled together.
        if ($families[$id] -eq $fam) { $latest[$fam] = $id }
    }
    if ($latest.Count -eq 0) { return $null }
    return @{ latest = $latest; names = $names }
}

if ($SelfTest) {
    $colorStatePath = Join-Path $env:TEMP "claude_launcher_colors_selftest.json"
    Remove-Item $colorStatePath -ErrorAction SilentlyContinue
    $me = Get-Process -Id $PID
    # Set-Content -Encoding UTF8 writes a BOM on PS 5.1, so this seed also covers reading the
    # BOM-prefixed state files older versions left behind. Keep it that way.
    @{ "$PID"   = @{ colors = @("Teal", "Amber"); start = "$($me.StartTime.Ticks)" }
       "999999" = @{ colors = @("Red");           start = "0" } } | ConvertTo-Json -Depth 4 | Set-Content $colorStatePath -Encoding UTF8

    $live = Get-LiveTabColors
    if ($live.Count -ne 1) { throw "SelfTest: dead PID not pruned ($($live.Count) live)" }
    # Both colors of a live session are held; the dead session's Red is released.
    if ((Get-UsedTabColors) -join "," -ne "Teal,Amber") { throw "SelfTest: used-color list wrong ($((Get-UsedTabColors) -join ','))" }

    1..200 | ForEach-Object {
        if (@("Teal", "Amber") -contains (Select-TabColor -Used (Get-UsedTabColors)).name) { throw "SelfTest: picked a color already in use" }
    }
    if (-not (Select-TabColor -Used ($tabPalette | ForEach-Object { $_.name }))) { throw "SelfTest: exhausted palette returned nothing" }

    # Reserve now writes bytes through its own handle: prove the reader still reads them back.
    Reserve-TabColor -OwnerPid $PID -Names @("Green", "Pink")
    if ((Get-UsedTabColors) -join "," -ne "Green,Pink") { throw "SelfTest: reserve round-trip lost colors ($((Get-UsedTabColors) -join ','))" }

    # Releasing keeps the owner but empties its list; dropping the entry would be wrong too.
    Reserve-TabColor -OwnerPid $PID -Names @()
    $released = Get-LiveTabColors
    if (-not $released.ContainsKey("$PID")) { throw "SelfTest: release dropped the owner entry" }
    if (@($released["$PID"].colors).Count -ne 0) { throw "SelfTest: release left colors behind" }
    if ((Get-UsedTabColors).Count -ne 0) { throw "SelfTest: released colors still counted as used" }

    # The rewrite must happen under an EXCLUSIVE handle, or two launchers starting together
    # both read the old file and the second write drops the first one's reservation. Hold the
    # file open with sharing ALLOWED: an exclusive open then cannot be granted, so Reserve has
    # to decline and leave the file untouched.
    Reserve-TabColor -OwnerPid $PID -Names @("Blue")
    $sentinel = [System.IO.File]::ReadAllText($colorStatePath, [System.Text.Encoding]::UTF8)
    $held = [System.IO.File]::Open($colorStatePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
    try { Reserve-TabColor -OwnerPid $PID -Names @("Amber") } finally { $held.Dispose() }
    if ([System.IO.File]::ReadAllText($colorStatePath, [System.Text.Encoding]::UTF8) -ne $sentinel) {
        throw "SelfTest: reservation rewritten while another handle was open (not exclusive)"
    }

    Remove-Item $colorStatePath -ErrorAction SilentlyContinue

    # Input decoding and list windowing are pure, so they are checked from synthetic records
    # rather than by clicking around a live console.
    function New-Rec { param([uint16]$Type) $r = New-Object byte[] 20; [BitConverter]::GetBytes($Type).CopyTo($r, 0); return ,$r }

    $rec = New-Rec 2
    [BitConverter]::GetBytes([int16]17).CopyTo($rec, 6)
    [BitConverter]::GetBytes([uint32]1).CopyTo($rec, 8)
    [BitConverter]::GetBytes([int16]40).CopyTo($rec, 4)
    $ev = ConvertFrom-InputRecord $rec
    if ($ev.Kind -ne "click" -or $ev.Row -ne 17) { throw "SelfTest: left press did not decode as a click on row 17" }
    if ($ev.Col -ne 40) { throw "SelfTest: click column lost (the tab bar hit test needs it)" }

    # A click already acts as Enter, so honouring DOUBLE_CLICK too would fire Enter a second time
    # on whatever screen the first click just opened.
    [BitConverter]::GetBytes([uint32]2).CopyTo($rec, 16)
    if (ConvertFrom-InputRecord $rec) { throw "SelfTest: DOUBLE_CLICK must not act as a second click" }

    [BitConverter]::GetBytes([uint32]1).CopyTo($rec, 16)
    if (ConvertFrom-InputRecord $rec) { throw "SelfTest: a pointer move must not wake the menu loop" }

    # One left+right chord, as the console reports it: dwButtonState is the CURRENT mask, so the
    # left bit is set in three of these four records. Exactly one is a new click.
    $script:leftButtonDown = $false
    $chord = 0
    foreach ($state in 1, 3, 1, 0) {
        $rec = New-Rec 2
        [BitConverter]::GetBytes([uint32]$state).CopyTo($rec, 8)
        if (ConvertFrom-InputRecord $rec) { $chord++ }
    }
    if ($chord -ne 1) { throw "SelfTest: a left+right chord decoded as $chord clicks, not 1" }

    # And a plain click still is one, from a clean state.
    $script:leftButtonDown = $false
    $rec = New-Rec 2
    [BitConverter]::GetBytes([uint32]1).CopyTo($rec, 8)
    if (-not (ConvertFrom-InputRecord $rec)) { throw "SelfTest: a plain left press stopped registering" }
    [BitConverter]::GetBytes([uint32]0).CopyTo($rec, 8)
    if (ConvertFrom-InputRecord $rec) { throw "SelfTest: releasing the button registered as a click" }

    # A drag that enters the window already pressed must not count as a press here.
    $script:leftButtonDown = $false
    $rec = New-Rec 2
    [BitConverter]::GetBytes([uint32]1).CopyTo($rec, 8)
    [BitConverter]::GetBytes([uint32]1).CopyTo($rec, 16)              # MOUSE_MOVED, button held
    if (ConvertFrom-InputRecord $rec) { throw "SelfTest: a move with the button down decoded as a click" }

    $script:leftButtonDown = $false
    $rec = New-Rec 2
    [BitConverter]::GetBytes([int32](-120 -shl 16)).CopyTo($rec, 8)   # wheel down: -120 in the high word
    [BitConverter]::GetBytes([uint32]4).CopyTo($rec, 16)
    if ((ConvertFrom-InputRecord $rec).Delta -ne -120) { throw "SelfTest: wheel-down delta lost its sign" }

    $rec = New-Rec 1
    $rec[4] = 1
    [BitConverter]::GetBytes([uint16]40).CopyTo($rec, 10)
    if ((ConvertFrom-InputRecord $rec).Vk -ne 40) { throw "SelfTest: key-down virtual key code lost" }
    $rec[4] = 0
    if (ConvertFrom-InputRecord $rec) { throw "SelfTest: key-up must not repeat the keystroke" }

    if ((Get-Scroll -Cursor 0  -Scroll 0 -ViewH 10 -Count 60) -ne 0)  { throw "SelfTest: top of the list scrolled" }
    if ((Get-Scroll -Cursor 10 -Scroll 0 -ViewH 10 -Count 60) -ne 1)  { throw "SelfTest: cursor below the window did not pull it down" }
    if ((Get-Scroll -Cursor 3  -Scroll 9 -ViewH 10 -Count 60) -ne 3)  { throw "SelfTest: cursor above the window did not pull it up" }
    if ((Get-Scroll -Cursor 59 -Scroll 0 -ViewH 10 -Count 60) -ne 50) { throw "SelfTest: last item not flush with the window bottom" }
    if ((Get-Scroll -Cursor 0  -Scroll 0 -ViewH 10 -Count 4)  -ne 0)  { throw "SelfTest: a list shorter than the window scrolled" }
    if ((Get-Scroll -Cursor 57 -Scroll 55 -ViewH 10 -Count 60) -ne 50) { throw "SelfTest: a scroll past the last full window was not pulled back" }

    # Tab bar: "   Permission   " is 16 columns from 3, then two spaces; "[ Model ]" is 9 from 21.
    $segs = @(Get-TabSegments -Names @("Permission", "Model", "Effort", "Extras") -Active 1)
    if ($segs.Count -ne 4)                            { throw "SelfTest: tab bar lost a tab" }
    if ($segs[0].Start -ne 3 -or $segs[0].End -ne 18) { throw "SelfTest: inactive tab spans the wrong columns" }
    if ($segs[1].Start -ne 21 -or $segs[1].End -ne 29) { throw "SelfTest: the active tab's brackets are not counted" }
    if ($segs[1].Text -ne "[ Model ]") { throw "SelfTest: the active tab lost its brackets" }
    if ($segs[2].Start -ne 32)                        { throw "SelfTest: the two-space gap between tabs was dropped" }
    $gap = $segs | Where-Object { 19 -ge $_.Start -and 19 -le $_.End }
    if ($gap) { throw "SelfTest: a click in the gap between tabs hit tab $($gap.Index)" }
    $on = $segs | Where-Object { 25 -ge $_.Start -and 25 -le $_.End }
    if ($on.Index -ne 1) { throw "SelfTest: a click inside the active tab did not land on it" }
    # Pipe the FUNCTION, not a variable: `return ,$segs` used to emit the array as one item, and
    # only this shape saw it -- piping a variable unrolls one level and hid the bug.
    $piped = Get-TabSegments -Names @("Permission", "Model", "Effort", "Extras") -Active 1 |
             Where-Object { 25 -ge $_.Start -and 25 -le $_.End }
    if ($piped.Index -ne 1) { throw "SelfTest: piping Get-TabSegments straight into Where-Object does not yield segments" }

    if (($ModelTiers -join ",") -ne "fable,opus,sonnet,haiku") { throw "SelfTest: the tier list changed; menu order, colors and the parser all read it" }

    # Shaped like the real binary. Keeping a fixture here is the only way to test the catalog
    # regexes without reading 200 MB; it catches a regex regression, not the binary drifting.
    # Every assertion below is written `-not $cat -or ...`: on a $null catalog the indexing alone
    # raises a NullArray error that PS 5.1 does not treat as terminating, so the `if` would be
    # abandoned and the run would reach "SelfTest OK" having tested nothing.
    $catFixture = 'aliases:{opus:{default:"claude-opus-5",per_provider:{bedrock:"claude-opus-4-6"}},fable:{default:"claude-fable-5-1"},sonnet:{default:"claude-sonnet-5"},haiku:{default:"claude-haiku-4-5"},mythos:{default:"claude-mythos-5"}},defaults:{},{id:"claude-opus-5",family:"opus",display_name:"Opus 5",cost:1},{id:"claude-opus-4-6",family:"opus",display_name:"Opus 4.6"},{id:"claude-fable-5-1",family:"fable",display_name:"Fable 5.1"},{id:"claude-sonnet-5",family:"sonnet",display_name:"Sonnet 5"},{id:"claude-haiku-4-5",family:"haiku",display_name:"Haiku 4.5"},{id:"claude-mythos-5",family:"mythos",display_name:""}'
    $cat = Parse-ModelCatalog $catFixture ""
    if (-not $cat) { throw "SelfTest: the model catalog did not parse at all" }
    # mythos is in the fixture with an empty display name: an unlabelled family must not reach a row.
    if ((($cat.latest.Keys | Sort-Object) -join ",") -ne "fable,haiku,opus,sonnet") { throw "SelfTest: the catalog gained or lost a family" }
    if ($cat.names[$cat.latest["fable"]] -ne "Fable 5.1") { throw "SelfTest: the catalog did not resolve the newest Fable" }
    if ($cat.names[$cat.latest["haiku"]] -ne "Haiku 4.5") { throw "SelfTest: the catalog lost Haiku's label" }

    # The backend decides what an alias launches, so the label has to move with it.
    $catB = Parse-ModelCatalog $catFixture "bedrock"
    if (-not $catB -or $catB.names[$catB.latest["opus"]] -ne "Opus 4.6") { throw "SelfTest: a per-provider alias override was ignored" }
    if (-not $catB -or $catB.names[$catB.latest["sonnet"]] -ne "Sonnet 5") { throw "SelfTest: a family with no override for this provider lost its default" }

    $catX = Parse-ModelCatalog ($catFixture -replace '\{id:"claude-fable-5-1",family:"fable"', '{id:"claude-fable-5-1",family:"opus"') ""
    if (-not $catX -or $catX.latest["fable"]) { throw "SelfTest: a catalog entry whose family contradicts the alias key was accepted" }

    # One family the binary describes oddly must cost that row its version, not all four.
    $catP = Parse-ModelCatalog ($catFixture -replace ',\{id:"claude-haiku-4-5"[^}]*\}', '') ""
    if (-not $catP -or $catP.latest["haiku"]) { throw "SelfTest: a family with no display name was kept" }
    if (-not $catP -or $catP.names[$catP.latest["opus"]] -ne "Opus 5") { throw "SelfTest: one unusable family took the others down with it" }

    if (Parse-ModelCatalog ($catFixture -replace 'aliases:\{', 'aliases:{}x') "") { throw "SelfTest: a catalog with no alias table must return nothing" }

    Write-Host "SelfTest OK"
    exit 0
}

function Get-ModelTier {
    param([string]$id)
    $lower = "$id".ToLower()
    foreach ($tier in $ModelTiers) {
        if ($lower.Contains($tier)) { return $tier }
    }
    return ""
}

function Get-EffortKey {
    param([string]$effort)
    $lower = "$effort".ToLower()
    if ($EffortColors.ContainsKey($lower)) { return $lower }
    return ""
}

# Which backend the launched session will use. The launcher hands `claude` its own environment,
# so reading these here is reading what that session will see.
function Get-ModelProvider {
    foreach ($v in $ModelProviders) {
        $val = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_USE_$v")
        if ($val -and $val -ne "0" -and $val -ne "false") { return $v.ToLower() }
    }
    return ""
}

# Scanning 200 MB costs ~500 ms and a transient copy of the whole binary, so it happens once per
# Claude Code build. The key mixes the version the CLI reports with the file identity, because
# neither alone is enough: a version string does not name the file it was read from, and an
# upgrade delivered with its timestamp preserved can land on the same length and mtime. A failed
# parse is cached under the same key -- otherwise a binary this launcher cannot read would pay the
# full scan on every single launch, forever.
function Get-ModelCatalog {
    param([string]$Version)
    $exe = try { (Get-Command claude -ErrorAction Stop).Source } catch { $null }
    if (-not $exe) { return $null }
    # An npm install puts a shim on PATH; the catalog is in the JS bundle behind it.
    if ($exe -match "\.(cmd|bat|ps1)$") {
        $cli = Join-Path (Split-Path $exe -Parent) "node_modules\@anthropic-ai\claude-code\cli.js"
        if (Test-Path -LiteralPath $cli) { $exe = $cli }
    }
    $f = try { Get-Item -LiteralPath $exe -ErrorAction Stop } catch { $null }
    if (-not $f) { return $null }
    $provider = Get-ModelProvider
    $stamp = "$Version-$($f.Length)-$($f.LastWriteTimeUtc.Ticks)-$provider"
    $cachePath = Join-Path $env:USERPROFILE ".claude\claude-launcher-models.json"
    try {
        $c = Get-Content $cachePath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        if ($c.stamp -eq $stamp) {
            if ($c.failed) { return $null }
            $cached = @{ latest = @{}; names = @{} }
            $c.latest.PSObject.Properties | ForEach-Object { $cached.latest[$_.Name] = $_.Value }
            $c.names.PSObject.Properties  | ForEach-Object { $cached.names[$_.Name]  = $_.Value }
            # The same invariant Parse-ModelCatalog enforces, so a hand-edited cache gets no
            # further than a freshly parsed one.
            $ok = $cached.latest.Count -gt 0
            foreach ($fam in @($cached.latest.Keys)) { if (-not $cached.names[$cached.latest[$fam]]) { $ok = $false } }
            if ($ok) { return $cached }
        }
    } catch {}
    Write-Host "Reading the model catalog from $(Split-Path $exe -Leaf)..."
    # 28591 is Latin-1: [Text.Encoding]::Latin1 does not exist on the PS 5.1 the .bat starts.
    $cat = try { Parse-ModelCatalog ([Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($exe))) $provider } catch { $null }
    $entry = if ($cat) { @{ stamp = $stamp; latest = $cat.latest; names = $cat.names } } else { @{ stamp = $stamp; failed = $true } }
    # Publish by rename: two launchers cold-starting together must never read a half-written file.
    $tmpPath = "$cachePath.$PID.tmp"
    try {
        $entry | ConvertTo-Json -Depth 3 | Set-Content -Path $tmpPath -Encoding UTF8
        Move-Item -LiteralPath $tmpPath -Destination $cachePath -Force
    } catch { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue }
    return $cat
}

$basedir = (Get-Location).Path

# --- Project icons (edit here) ---
# $icons = @{ "my-project" = "🤖"; "another" = "🎮" }
$icons = @{}

# --- Claude info ---
$cver = ""
try { $cver = (claude --version 2>$null) -replace '\s*\(Claude Code\)', '' } catch {}
$cemail  = ""
$corg    = ""
$subname = "Claude API"
$modelLine = ""
try {
    $auth = claude auth status 2>$null | ConvertFrom-Json
    $cemail = $auth.email
    if ($auth.orgName) { $corg = $auth.orgName }
    $subMap = @{
        "max"        = @{ name="Claude Max";        color=$OR }
        "pro"        = @{ name="Claude Pro";        color="$ESC[38;2;$($t.permission)m" }
        "team"       = @{ name="Claude Team";       color=$GN }
        "enterprise" = @{ name="Claude Enterprise"; color=$PR }
    }
    $sub = $auth.subscriptionType
    if ($subMap.ContainsKey($sub)) {
        $subname  = $subMap[$sub].name
        $subcolor = $subMap[$sub].color
    }
} catch {}
if (-not $subcolor) { $subcolor = $IN }

# --- Model & effort from settings ---
$modelDisplay = ""
$effortDisplay = ""
$settingsModel = ""
$settingsEffort = ""
$settingsPermission = ""
try {
    $settingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"
    if (Test-Path $settingsPath) {
        $s = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($s.model)          { $modelDisplay = $s.model; $settingsModel = $s.model }
        if ($s.effortLevel)    { $effortDisplay = $s.effortLevel; $settingsEffort = $s.effortLevel }
        if ($s.permissionMode) { $settingsPermission = $s.permissionMode }
    }
} catch {}
# --- Model catalog (read from the installed Claude Code; single source of truth for header + tab menu) ---
# The menu key is the family alias, not the id: `claude --model fable` resolves to the newest Fable
# on its own, so a per-path choice saved today still means "newest Fable" after the next release.
# Only the label needs the version, which is why a failed scan degrades to "Fable" and still launches.
$claudeModels = Get-ModelCatalog $cver
$modelNames   = if ($claudeModels) { $claudeModels.names } else { @{} }
$modelCatalog = @(foreach ($tier in $ModelTiers) {
    $id = if ($claudeModels) { $claudeModels.latest[$tier] } else { $null }
    $name = if ($id -and $modelNames[$id]) { $modelNames[$id] } else { [char]::ToUpper($tier[0]) + $tier.Substring(1) }
    @{ id = $tier; name = $name; tier = $tier }
})

# settings.json can hold a full id, a family alias, or something this catalog has never heard of.
# Prefer the catalog name, then the menu row, then the bare family, so a failed scan shows "Opus"
# instead of a raw id. opusplan is handed back untouched: it contains "opus" but runs Sonnet.
function Format-ModelLabel {
    param([string]$Value)
    if (-not $Value -or $Value -like "opusplan*") { return $Value }
    if ($modelNames.ContainsKey($Value)) { return $modelNames[$Value] }
    $row = $modelCatalog | Where-Object { $_.id -eq $Value }
    if ($row) { return $row.name }
    $tier = Get-ModelTier $Value
    if ($tier) { return [char]::ToUpper($tier[0]) + $tier.Substring(1) }
    return $Value
}

if (-not $modelDisplay) {
    $defaultTiers = @{ "max"="opus"; "pro"="sonnet"; "team"="sonnet"; "enterprise"="sonnet" }
    if ($sub -and $defaultTiers.ContainsKey($sub)) {
        $modelDisplay = ($modelCatalog | Where-Object { $_.tier -eq $defaultTiers[$sub] }).name
    }
} else {
    $modelDisplay = Format-ModelLabel $modelDisplay
}

$permInheritDesc  = "Claude Code default"
$modelInheritVal  = Format-ModelLabel $settingsModel
$modelInheritDesc = if ($modelInheritVal)    { "$modelInheritVal (Use settings.json value)" }    else { "Use settings.json value" }
$effortInheritDesc = if ($settingsEffort)    { "$settingsEffort (Use settings.json value)" }      else { "Use settings.json value" }

# --- Org: skip personal pattern ---
if ($corg -and $cemail -and $corg -eq "$cemail's Organization") {
    $corg = ""
}

$headerModelId     = if ($settingsModel) { $settingsModel } else { $modelDisplay }
$headerModelTier   = Get-ModelTier $headerModelId
$headerEffortKey   = Get-EffortKey $settingsEffort
$headerModelColor  = if ($headerModelTier) { $ModelColors[$headerModelTier] }  else { $IN }
$headerEffortColor = if ($headerEffortKey) { $EffortColors[$headerEffortKey] } else { $IN }

$modelLine = if ($modelDisplay -or $effortDisplay) {
    $parts = @()
    if ($modelDisplay)  { $parts += "$headerModelColor$modelDisplay$R" }
    if ($effortDisplay) { $parts += "${IN}with$R $headerEffortColor$effortDisplay$R ${IN}effort$R" }
    ($parts -join " ") + " ${IN}·$R $subcolor$subname$R"
} else {
    "$subcolor$subname$R"
}

# --- Discover known projects from ~/.claude/projects/ ---
$projectsDir = Join-Path $env:USERPROFILE ".claude\projects"
$knownPaths = @()
if (Test-Path $projectsDir) {
    Get-ChildItem -Path $projectsDir -Directory | ForEach-Object {
        $encoded = $_.Name
        # Decode: X-- → X:\, -- → \., - → \
        $decoded = $encoded -replace '^([A-Za-z])--', '$1:\'
        $decoded = $decoded -replace '--', '\.'
        $decoded = $decoded -replace '-', '\'
        if (Test-Path $decoded -PathType Container) {
            $knownPaths += $decoded
        }
    }
    $knownPaths = $knownPaths | Sort-Object -Unique
}

# --- Determine mode: inside known project or external ---
$currentDir = (Get-Location).Path
$matchedProject = $knownPaths | Where-Object { $currentDir -eq $_ -or $currentDir.StartsWith($_ + "\") } |
    Sort-Object { $_.Length } -Descending | Select-Object -First 1

function Build-LocalMenu {
    param([string]$BaseDir)
    $menuItems = @()
    $menuPaths = @()

    $baseName = Split-Path $BaseDir -Leaf
    $menuItems += "📂 $baseName (current)"
    $menuPaths += $BaseDir

    Get-ChildItem -Path $BaseDir -Directory | Sort-Object Name | ForEach-Object {
        $emoji = if ($icons.ContainsKey($_.Name)) { $icons[$_.Name] } else { "📁" }
        $menuItems += "$emoji $($_.Name)"
        $menuPaths += $_.FullName
    }

    $menuItems += "🔍 Browse"
    $menuPaths += "__BROWSE__"

    return @{ items = $menuItems; paths = $menuPaths }
}

$isLocal = $null -ne $matchedProject

# --- Draw header ---
function Draw-Header {
    Clear-Host
    Write-Host ""
    Write-Host "   $CL▐▛███▜▌$R   ${B}Claude Code$R ${IN}v$cver$R"
    Write-Host "  $CL▝▜█████▛▘$R  $modelLine"
    $accountLine = if ($corg) { "$cemail  $corg" } else { $cemail }
    Write-Host "    $CL▘▘ ▝▝$R    ${IN}$accountLine$R"
    Write-Host ""
    Write-Host "   ${IN}Select a directory to start the session.$R"
    Write-Host ""
}

# --- Arrow key menu ---
function Show-Menu {
    param([string[]]$MenuItems, [int]$Start = 0, [string]$EscLabel = "quit")

    $cursor = $Start
    $hint = "   ${IN}[↑↓] move  [1-9] jump  [Enter/click] select  [Esc] $EscLabel$R$ESC[K"

    # Render draws $MenuItems.Count + 2 lines down from $top. Scroll that space in now: in a
    # short window the buffer would otherwise scroll on the last line of every frame, leaving
    # $top one row stale each time and stranding the previous frame's first item above the menu.
    $renderRows = $MenuItems.Count + 2
    for ($i = 0; $i -lt $renderRows; $i++) { Write-Host "" }
    $top = [Math]::Max(0, [Console]::CursorTop - $renderRows)

    Write-Host "$ESC[?25l" -NoNewline

    function Render {
        [Console]::SetCursorPosition(0, $top)
        for ($i = 0; $i -lt $MenuItems.Count; $i++) {
            $num = $i + 1
            $line = $MenuItems[$i]
            if ($i -eq $cursor) {
                Write-Host "   $BL$B❯ $num. $line$R$ESC[K"
            } else {
                Write-Host "     ${IN}$num.$R $line$R$ESC[K"
            }
        }
        Write-Host ""
        Write-Host $hint
    }

    try {
        Enable-MouseInput | Out-Null
        Render

        while ($true) {
            $ev = Read-Input
            if ($ev.Kind -eq "click") {
                $idx = $ev.Row - $top
                if ($idx -ge 0 -and $idx -lt $MenuItems.Count) { return $idx }
                continue
            }
            if ($ev.Kind -eq "wheel") {
                if ($ev.Delta -gt 0) { if ($cursor -gt 0) { $cursor-- } }
                else                 { if ($cursor -lt $MenuItems.Count - 1) { $cursor++ } }
                Render
                continue
            }
            $char = $ev.Char
            if ($char -ge '1' -and $char -le '9') {
                $idx = [int]::Parse($char) - 1
                if ($idx -lt $MenuItems.Count) { return $idx }
            }
            switch ($ev.Vk) {
                38 { if ($cursor -gt 0) { $cursor-- }; Render }
                40 { if ($cursor -lt $MenuItems.Count - 1) { $cursor++ }; Render }
                13 { return $cursor }
                27 { return -1 }
            }
        }
    } finally {
        Restore-ConsoleMode
        Write-Host "$ESC[?25h" -NoNewline
    }
}

# --- Directory tree browser ---
function Browse-Directory {
    param([string]$StartPath)

    $current = $StartPath

    while ($true) {
        $dirs = @()
        $dirNames = @()

        $dirs += ".."
        $dirNames += "$IN..  (up)$R"

        Get-ChildItem -Path $current -Directory -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
            $dirs += $_.FullName
            $emoji = if ($icons.ContainsKey($_.Name)) { $icons[$_.Name] } else { "📁" }
            $dirNames += "$emoji $($_.Name)"
        }

        Clear-Host
        Write-Host ""
        Write-Host "   $CL🔍$R ${B}Browse$R  ${IN}$current$R"
        Write-Host ""
        Write-Host "   ${IN}[↑↓] move  [Enter/click] open  [Space] select here  [Esc] back$R"
        Write-Host ""

        # The list is windowed. One row per child overflows the console on any sizeable
        # directory: the buffer scrolls mid-render, $top goes stale, and the first entries --
        # the ❯ cursor among them -- end up above the visible area. Height comes from where the
        # header actually left the cursor, not from a constant, so a long path or hint that wraps
        # to a second line shrinks the list instead of pushing its top off screen.
        $viewH = [Math]::Max(3, [Console]::WindowHeight - ([Console]::CursorTop - [Console]::WindowTop) - 2)
        $rows  = [Math]::Min($dirNames.Count, $viewH)
        $renderRows = $rows + 1                     # +1: the position line under the list
        for ($i = 0; $i -lt $renderRows; $i++) { Write-Host "" }
        $top = [Math]::Max(0, [Console]::CursorTop - $renderRows)
        $cursor = 0
        $scroll = 0
        $winH   = [Console]::WindowHeight

        Write-Host "$ESC[?25l" -NoNewline

        function Render-Tree {
            [Console]::SetCursorPosition(0, $top)
            # Iterate $i directly. A $r loop counter would silently overwrite $R, the ANSI reset --
            # PowerShell variable names are case-insensitive.
            for ($i = $scroll; $i -lt $scroll + $rows; $i++) {
                if ($i -eq $cursor) {
                    Write-Host "   $BL$B❯ $($dirNames[$i])$R$ESC[K"
                } else {
                    Write-Host "     $($dirNames[$i])$R$ESC[K"
                }
            }
            # Without this the windowing is invisible and a long directory just looks truncated.
            if ($dirNames.Count -gt $rows) {
                Write-Host "   ${IN}$($scroll + 1)-$($scroll + $rows) / $($dirNames.Count)$R$ESC[K"
            } else {
                Write-Host "$ESC[K"
            }
        }

        try {
            Enable-MouseInput | Out-Null

            $selected = $null
            while ($null -eq $selected) {
                # A resize invalidates $viewH, $rows and $top, all measured once above. Bail to the
                # outer loop, which re-lists this same directory against the new size. Noticed on
                # the next input event, since Read-Input is where this loop spends its time.
                if ([Console]::WindowHeight -ne $winH) { $selected = "REDRAW"; continue }
                # Clamp then draw at the top of every pass, so no branch below can leave the
                # cursor out of view or forget to repaint.
                $scroll = Get-Scroll -Cursor $cursor -Scroll $scroll -ViewH $rows -Count $dirNames.Count
                Render-Tree

                $open = $false
                $ev = Read-Input
                switch ($ev.Kind) {
                    "click" {
                        $i = $ev.Row - $top + $scroll
                        if ($i -ge $scroll -and $i -lt $scroll + $rows) { $cursor = $i; $open = $true }
                    }
                    "wheel" {
                        $step = if ($ev.Delta -gt 0) { -3 } else { 3 }
                        $scroll = [Math]::Max(0, [Math]::Min($dirNames.Count - $rows, $scroll + $step))
                        if ($cursor -lt $scroll)         { $cursor = $scroll }
                        if ($cursor -ge $scroll + $rows) { $cursor = $scroll + $rows - 1 }
                    }
                    "key" {
                        switch ($ev.Vk) {
                            38 { if ($cursor -gt 0) { $cursor-- } }
                            40 { if ($cursor -lt $dirNames.Count - 1) { $cursor++ } }
                            13 { $open = $true }
                            32 { return $current }
                            27 { return $null }
                        }
                    }
                }
                if ($open) {
                    if ($dirs[$cursor] -eq "..") {
                        $parent = Split-Path $current -Parent
                        if ($parent) { $current = $parent }
                    } else {
                        $current = $dirs[$cursor]
                    }
                    $selected = "NAVIGATE"
                }
            }
        } finally {
            Restore-ConsoleMode
            Write-Host "$ESC[?25h" -NoNewline
        }
    }
}

# --- Option lists for tabbed config ---
$permModes = @(
    @{ key=$null;               label="inherit";           desc=$permInheritDesc;                                          color=$WH }
    @{ key="default";           label="default";           desc="Requires manual approval for unmatched tools";            color=$WH }
    @{ key="plan";              label="plan";              desc="Planning only — no tool execution";                        color="$ESC[38;2;$($t.planMode)m" }
    @{ key="acceptEdits";       label="acceptEdits";       desc="Auto-approve file edits and filesystem commands";         color="$ESC[38;2;$($t.autoAccept)m" }
    @{ key="dontAsk";           label="dontAsk";           desc="Deny any tool not explicitly pre-approved";               color=$IN }
    @{ key="auto";              label="auto";              desc="Model classifier auto-approves safe actions";             color=$OR }
    @{ key="bypassPermissions"; label="bypassPermissions"; desc="Bypass all permission checks (trusted environments only)"; color="$ESC[38;2;$($t.error)m" }
)

$models = @(
    @{ key = $null; label = "inherit"; desc = $modelInheritDesc; color = $WH }
)
foreach ($m in $modelCatalog) {
    $color = if ($ModelColors.ContainsKey($m.tier)) { $ModelColors[$m.tier] } else { $WH }
    $desc  = if ($m.desc) { $m.desc } else {
        switch ($m.tier) { "fable" { "Newest flagship — most capable" } "opus" { "Complex architectural reasoning" } "sonnet" { "General coding tasks" } "haiku" { "Simple tasks, most economical" } default { "" } }
    }
    $models += @{ key = $m.id; label = $m.name; desc = $desc; color = $color }
}

$efforts = @(
    @{ key=$null;    label="inherit"; desc=$effortInheritDesc;                                   color=$WH }
    @{ key="auto";   label="auto";    desc="Adaptive — Claude picks effort per turn";            color=$EffortColors["auto"]   }
    @{ key="low";    label="low";     desc="Short, scoped, latency-sensitive tasks";             color=$EffortColors["low"]    }
    @{ key="medium"; label="medium";  desc="Reduced token usage for cost-sensitive work";        color=$EffortColors["medium"] }
    @{ key="high";   label="high";    desc="Default for Opus — balanced intelligence";           color=$EffortColors["high"]   }
    @{ key="xhigh";  label="xhigh";   desc="For the hardest tasks (Opus recommended)";           color=$EffortColors["xhigh"]  }
    @{ key="max";    label="max";     desc="Maximum reasoning; may lead to diminishing returns"; color=$EffortColors["max"]    }
    @{ key="ultracode"; label="ultracode"; desc="xhigh + standing dynamic workflows (needs an xhigh-capable Opus model)"; color=$EffortColors["ultracode"] }
)

$permItems   = @(); foreach ($m in $permModes) { $permItems   += "$($m.color)$($m.label)$R  ${IN}— $($m.desc)$R" }
$modelItems  = @(); foreach ($m in $models)    { $modelItems  += "$($m.color)$($m.label)$R  ${IN}— $($m.desc)$R" }
$effortItems = @(); foreach ($m in $efforts)   { $effortItems += "$($m.color)$($m.label)$R  ${IN}— $($m.desc)$R" }

$extrasCatalog = @(
    # Integrations
    @{ key = "ide";      label = "IDE";      desc = "Auto-connect to IDE on startup";                       flag = "--ide" }
    @{ key = "chrome";   label = "Chrome";   desc = "Enable Chrome integration (beta)";                     flag = "--chrome" }
    @{ key = "telegram"; label = "Telegram"; desc = "Load Telegram channel plugin";                         flag = "--channels plugin:telegram@claude-plugins-official" }
    @{ key = "remote";   label = "Remote";   desc = "Enable Remote Control (drive session from another device)"; flag = "--remote-control" }
    # Diagnostics
    @{ key = "verbose";  label = "Verbose";  desc = "Enable verbose logging";                               flag = "--verbose" }
    @{ key = "bare";     label = "Bare";     desc = "Skip hooks, LSP, plugins, and CLAUDE.md discovery";    flag = "--bare" }
    @{ key = "safe";     label = "Safe";     desc = "Disable ALL customizations for troubleshooting (broader than Bare)"; flag = "--safe-mode" }
    # Perf / UX
    @{ key = "cache";    label = "Cache";    desc = "Move per-machine context to first message for cache reuse"; flag = "--exclude-dynamic-system-prompt-sections" }
    @{ key = "brief";    label = "Brief";    desc = "Enable SendUserMessage tool (agent-to-user messages mid-task)"; flag = "--brief" }
    @{ key = "prompts";  label = "Prompts";  desc = "Suggest a predicted next prompt each turn";              flag = "--prompt-suggestions" }
    # Appearance — applied to the terminal itself, not passed to claude (hence no flag)
    @{ key = "tabcolor"; label = "Tab color"; desc = "Tab color (Windows Terminal only)";                    type = "color"; kind = "tab" }
    @{ key = "bgcolor";  label = "Background"; desc = "Background tint";                                     type = "color"; kind = "bg"  }
)

$permDefaultIndex = 0
for ($i = 0; $i -lt $permModes.Count; $i++) {
    if ($permModes[$i].key -eq "bypassPermissions") { $permDefaultIndex = $i; break }
}
$modelDefaultIndex  = 0
$effortDefaultIndex = 0

# --- Launcher state (remembers last choices per path) ---
$launcherStatePath = Join-Path $env:USERPROFILE ".claude\claude-launcher.json"

function Get-LauncherState {
    $state = @{ perPath = @{} }
    if (Test-Path $launcherStatePath) {
        try {
            $obj = Get-Content $launcherStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($obj.perPath) {
                $obj.perPath.PSObject.Properties | ForEach-Object {
                    $state.perPath[$_.Name] = $_.Value
                }
            }
        } catch {}
    }
    return $state
}

function Find-OptionIndex {
    param($Arr, $Key, [int]$Default = 0)
    for ($i = 0; $i -lt $Arr.Count; $i++) {
        $k = $Arr[$i].key
        if (($null -eq $k -and $null -eq $Key) -or ($null -ne $k -and $k -eq $Key)) { return $i }
    }
    return $Default
}

function Get-PathChoices {
    param([string]$Path)
    $state = Get-LauncherState
    if (-not $state.perPath.ContainsKey($Path)) { return $null }
    $entry = $state.perPath[$Path]
    $choices = @{ permission = $null; model = $null; effort = $null; extras = @(); tabColor = $null; bgColor = $null }
    if ($entry -is [string]) {
        $choices.permission = $entry
    } elseif ($entry) {
        $choices.permission = $entry.permission
        $choices.model      = $entry.model
        $choices.effort     = $entry.effort
        $choices.tabColor   = $entry.tabColor
        $choices.bgColor    = $entry.bgColor
        if ($entry.extras) { $choices.extras = @($entry.extras) }
    }
    # Menu keys used to be model ids and are family aliases now, so an id that meant "newest of
    # this family" is folded onto that alias and the choice survives. Anything else an older
    # launcher saved -- a pinned older model, a [1m] context variant -- has no row that can
    # express it: it reaches the menu unmatched, opens on "inherit", and the next save
    # overwrites it. That pin is lost either way, and losing it to "inherit" beats folding it,
    # which would silently launch the newest model of its family instead of the pinned one.
    if ($choices.model -and $LegacyModelIds.ContainsKey($choices.model)) { $choices.model = $LegacyModelIds[$choices.model] }
    return $choices
}

function Save-PathChoices {
    param([string]$Path, $Permission, $Model, $Effort, $Extras, $TabColor, $BgColor)
    $state = Get-LauncherState
    # Colors are stored as the *choice* ("random" or a palette name), not the resolved color,
    # so a saved "random" rolls a fresh non-clashing color on every launch.
    $state.perPath[$Path] = @{ permission = $Permission; model = $Model; effort = $Effort
                               extras = @($Extras); tabColor = $TabColor; bgColor = $BgColor }
    $dir = Split-Path $launcherStatePath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $state | ConvertTo-Json -Depth 5 | Set-Content -Path $launcherStatePath -Encoding UTF8
}

# --- Tabbed config (Permission / Model / Effort) ---
function Show-TabbedConfig {
    param([string]$Path)

    Clear-Host
    Write-Host ""
    Write-Host "   $CL▐▛███▜▌$R   ${B}Claude Code$R ${IN}v$cver$R"
    Write-Host "  $CL▝▜█████▛▘$R  $modelLine"
    $accountLine = if ($corg) { "$cemail  $corg" } else { $cemail }
    Write-Host "    $CL▘▘ ▝▝$R    ${IN}$accountLine$R"
    Write-Host ""
    Write-Host "   $BL$Path$R"
    Write-Host ""
    Write-Host "   ${IN}Configure this session.$R"
    Write-Host ""

    $choices = Get-PathChoices -Path $Path
    if ($null -ne $choices) {
        $permStart   = Find-OptionIndex -Arr $permModes -Key $choices.permission -Default $permDefaultIndex
        $modelStart  = Find-OptionIndex -Arr $models    -Key $choices.model      -Default $modelDefaultIndex
        $effortStart = Find-OptionIndex -Arr $efforts   -Key $choices.effort     -Default $effortDefaultIndex
    } else {
        $permStart   = $permDefaultIndex
        $modelStart  = $modelDefaultIndex
        $effortStart = $effortDefaultIndex
    }

    # Colors are terminal settings, not CLI flags, so they stay out of $extrasSelected — the launch
    # loop looks up a flag per selected extra and would find none. -1 off, 0 random, 1..N palette.
    $extrasSelected = @{}
    $colorIdx  = @{ tab = -1;    bg = -1    }
    $colorPick = @{ tab = $null; bg = $null }

    if ($null -ne $choices) {
        foreach ($k in $choices.extras) {
            if ($k -and ($extrasCatalog | Where-Object { $_.key -eq $k -and -not $_.type })) { $extrasSelected[$k] = $true }
        }
        foreach ($kind in @("tab", "bg")) {
            $saved = if ($kind -eq "tab") { $choices.tabColor } else { $choices.bgColor }
            if ($saved -eq "random") {
                $colorIdx[$kind]  = 0
                $colorPick[$kind] = Select-TabColor -Used (Get-UsedTabColors)
            } elseif ($saved) {
                for ($i = 0; $i -lt $tabPalette.Count; $i++) {
                    if ($tabPalette[$i].name -eq $saved) { $colorIdx[$kind] = $i + 1; $colorPick[$kind] = $tabPalette[$i] }
                }
            }
        }
    }

    $tabs = @(
        @{ name = "Permission"; items = $permItems;   modes = $permModes;    cursor = $permStart;   isMulti = $false }
        @{ name = "Model";      items = $modelItems;  modes = $models;       cursor = $modelStart;  isMulti = $false }
        @{ name = "Effort";     items = $effortItems; modes = $efforts;      cursor = $effortStart; isMulti = $false }
        @{ name = "Extras";     items = @();          modes = $extrasCatalog; cursor = 0;           isMulti = $true  }
    )

    $activeTab = 0
    $tabNames  = @($tabs | ForEach-Object { $_.name })
    $maxItems = ($tabs | ForEach-Object { if ($_.isMulti) { $extrasCatalog.Count } else { $_.items.Count } } | Measure-Object -Maximum).Maximum
    # Render draws $maxItems + 5 lines down from $tabBarTop. Scroll that space in now: in a
    # short window the buffer would otherwise scroll mid-render and every later frame would
    # draw from a stale $tabBarTop, stranding rows of the previous tab on screen.
    $renderRows = $maxItems + 5
    for ($i = 0; $i -lt $renderRows; $i++) { Write-Host "" }
    $tabBarTop = [Math]::Max(0, [Console]::CursorTop - $renderRows)

    # Shared by [Space] and by a click on the Extras tab, so the two can never drift apart.
    function Toggle-Extra {
        param($E)
        if ($E.type -eq "color")           { Step-Color $E.kind }
        elseif ($extrasSelected[$E.key])   { $extrasSelected.Remove($E.key) }
        else                               { $extrasSelected[$E.key] = $true }
    }

    # Enter and a click both leave through here, so the two can never return different things.
    function Get-Result {
        return @{
            permission = $tabs[0].modes[$tabs[0].cursor].key
            model      = $tabs[1].modes[$tabs[1].cursor].key
            effort     = $tabs[2].modes[$tabs[2].cursor].key
            extras     = @($extrasSelected.Keys | Where-Object { $extrasSelected[$_] })
            tabColor   = $colorPick["tab"]
            bgColor    = $colorPick["bg"]
            tabChoice  = Get-ColorChoice "tab"
            bgChoice   = Get-ColorChoice "bg"
        }
    }

    function Get-VisibleLength {
        param([string]$Text)
        return ($Text -replace "$ESC\[[0-9;]*m", '').Length
    }

    function Format-ColorValue {
        param([string]$Kind)
        if ($colorIdx[$Kind] -lt 0) { return "${IN}off$R" }
        $sw = "$ESC[38;2;$($colorPick[$Kind].rgb)m"
        if ($colorIdx[$Kind] -eq 0) { return "$sw random ($($colorPick[$Kind].name))$R" }
        return "$sw$($colorPick[$Kind].name)$R"
    }

    # off → random → each palette color → off
    function Step-Color {
        param([string]$Kind)
        $colorIdx[$Kind]++
        if ($colorIdx[$Kind] -gt $tabPalette.Count) { $colorIdx[$Kind] = -1 }
        if ($colorIdx[$Kind] -eq 0)     { $colorPick[$Kind] = Select-TabColor -Used (Get-UsedTabColors) }
        elseif ($colorIdx[$Kind] -gt 0) { $colorPick[$Kind] = $tabPalette[$colorIdx[$Kind] - 1] }
        else                            { $colorPick[$Kind] = $null }
    }

    # What gets saved: the choice, not the rolled color.
    function Get-ColorChoice {
        param([string]$Kind)
        if ($colorIdx[$Kind] -lt 0) { return $null }
        if ($colorIdx[$Kind] -eq 0) { return "random" }
        return $colorPick[$Kind].name
    }

    # Bottom line: what every tab currently holds, so a launch never depends on tabbing back.
    function Format-Selection {
        $vals = @()
        foreach ($i in 0..2) {
            $m = $tabs[$i].modes[$tabs[$i].cursor]
            $vals += "$($m.color)$($m.label)$R"
        }
        $on = @($extrasCatalog | Where-Object { $extrasSelected[$_.key] })
        if     ($on.Count -eq 0) { $vals += "${IN}none$R" }
        elseif ($on.Count -le 2) { $vals += "$GN$(($on | ForEach-Object { $_.label }) -join ', ')$R" }
        else                     { $vals += "$GN$($on.Count) selected$R" }
        foreach ($kind in @("tab", "bg")) {
            if ($colorIdx[$kind] -lt 0) { $vals += "${IN}off$R" }
            else                        { $vals += "$ESC[38;2;$($colorPick[$kind].rgb)m●$R $($colorPick[$kind].name)" }
        }

        $names = @("Permission", "Model", "Effort", "Extras", "Tab", "Background")
        $long  = (0..5 | ForEach-Object { "${IN}$($names[$_])$R $($vals[$_])" }) -join " ${IN}·$R "
        if ((Get-VisibleLength $long) -le [Console]::WindowWidth - 4) { return $long }
        # Too narrow for labels — the tab bar above already gives the order.
        return ($vals -join " ${IN}·$R ")
    }

    function Render {
        [Console]::SetCursorPosition(0, $tabBarTop)
        $bar = "   "
        foreach ($seg in (Get-TabSegments -Names $tabNames -Active $activeTab)) {
            if ($seg.Index -eq $activeTab) { $bar += "$BL$B$($seg.Text)$R  " }
            else                           { $bar += "$IN$($seg.Text)$R  " }
        }
        Write-Host "$bar$ESC[K"
        Write-Host "   ${IN}───────────────────────────────────────────$R$ESC[K"

        $tab = $tabs[$activeTab]
        if ($tab.isMulti) {
            for ($i = 0; $i -lt $maxItems; $i++) {
                if ($i -lt $extrasCatalog.Count) {
                    $e = $extrasCatalog[$i]
                    if ($e.type -eq "color") {
                        $pick = $colorPick[$e.kind]
                        $chk  = if ($pick) { "$ESC[38;2;$($pick.rgb)m[●]$R" } else { "${IN}[ ]$R" }
                        $line = "$chk $WH$($e.label)$R  ${IN}— $($e.desc):$R $(Format-ColorValue $e.kind)"
                    } else {
                        $chk  = if ($extrasSelected[$e.key]) { "$GN[x]$R" } else { "${IN}[ ]$R" }
                        $line = "$chk $WH$($e.label)$R  ${IN}— $($e.desc)$R"
                    }
                    $num = $i + 1
                    if ($i -eq $tab.cursor) {
                        Write-Host "   $BL$B❯$R $num. $line$ESC[K"
                    } else {
                        Write-Host "     ${IN}$num.$R $line$ESC[K"
                    }
                } else {
                    Write-Host "$ESC[K"
                }
            }
        } else {
            for ($i = 0; $i -lt $maxItems; $i++) {
                if ($i -lt $tab.items.Count) {
                    $num = $i + 1
                    if ($i -eq $tab.cursor) {
                        Write-Host "   $BL$B❯ $num. $($tab.items[$i])$R$ESC[K"
                    } else {
                        Write-Host "     ${IN}$num.$R $($tab.items[$i])$R$ESC[K"
                    }
                } else {
                    Write-Host "$ESC[K"
                }
            }
        }
        Write-Host "$ESC[K"
        Write-Host "   $(Format-Selection)$ESC[K"
        $pick = if ($tab.isMulti) { "[Space/click] toggle" } else { "[1-9] jump" }
        # Click launches only on a single-select tab; an Extras row is a checkbox and its click
        # toggles. Advertising both on the same footer is how a user ends up changing a setting
        # while expecting a launch.
        $go   = if ($tab.isMulti) { "[Enter] launch" } else { "[Enter/click] launch" }
        Write-Host "   ${IN}[←→] tab  [↑↓] move  $pick  $go  [Esc] back$R$ESC[K"
    }

    Write-Host "$ESC[?25l" -NoNewline
    try {
        Enable-MouseInput | Out-Null
        Render
        while ($true) {
            $ev = Read-Input
            $tab = $tabs[$activeTab]
            $count = if ($tab.isMulti) { $extrasCatalog.Count } else { $tab.items.Count }
            if ($ev.Kind -eq "click") {
                if ($ev.Row -eq $tabBarTop) {
                    $hit = Get-TabSegments -Names $tabNames -Active $activeTab |
                           Where-Object { $ev.Col -ge $_.Start -and $ev.Col -le $_.End }
                    if ($hit) { $activeTab = $hit.Index; Render }
                    continue
                }
                # Item rows start two below the tab bar (bar + divider). A click is Enter, so on a
                # single-select tab it picks and launches; on Extras the row is a checkbox and its
                # Enter-equivalent is the toggle, or the boxes would be unreachable by mouse.
                $idx = $ev.Row - $tabBarTop - 2
                if ($idx -ge 0 -and $idx -lt $count) {
                    $tab.cursor = $idx
                    if (-not $tab.isMulti) { return Get-Result }
                    Toggle-Extra $extrasCatalog[$idx]
                    Render
                }
                continue
            }
            if ($ev.Kind -eq "wheel") {
                if ($ev.Delta -gt 0) { if ($tab.cursor -gt 0)          { $tab.cursor-- } }
                else                 { if ($tab.cursor -lt $count - 1) { $tab.cursor++ } }
                Render
                continue
            }
            $char = $ev.Char
            if ($char -ge '1' -and $char -le '9') {
                $idx = [int]::Parse($char) - 1
                if ($idx -lt $count) { $tab.cursor = $idx; Render }
                continue
            }
            switch ($ev.Vk) {
                37 { if ($activeTab -gt 0)               { $activeTab-- }; Render }
                39 { if ($activeTab -lt $tabs.Count - 1) { $activeTab++ }; Render }
                38 { if ($tab.cursor -gt 0)              { $tab.cursor-- }; Render }
                40 { if ($tab.cursor -lt $count - 1) { $tab.cursor++ }; Render }
                32 { if ($tab.isMulti) { Toggle-Extra $extrasCatalog[$tab.cursor]; Render } }
                13 { return Get-Result }
                27 { return $null }
            }
        }
    } finally {
        Restore-ConsoleMode
        Write-Host "$ESC[?25h" -NoNewline
    }
}

# --- Main loop ---
$selectedPermission = $null
$selectedModel = $null
$selectedEffort = $null
$selectedExtras = @()
$selectedTabColor = $null
$selectedBgColor  = $null
$selectedTabChoice = $null
$selectedBgChoice  = $null

if ($isLocal) {
    $menu = Build-LocalMenu -BaseDir $currentDir

    :outer while ($true) {
        Draw-Header
        $choice = Show-Menu -MenuItems $menu.items

        if ($choice -eq -1) { exit 0 }

        $target = $menu.paths[$choice]
        if ($target -eq "__BROWSE__") {
            $browsed = Browse-Directory -StartPath $currentDir
            if ($null -ne $browsed) { $target = $browsed } else { continue }
        }

        $cfg = Show-TabbedConfig -Path $target
        if ($null -eq $cfg) { continue }

        $selectedPath       = $target
        $selectedPermission = $cfg.permission
        $selectedModel      = $cfg.model
        $selectedEffort     = $cfg.effort
        $selectedExtras     = $cfg.extras
        $selectedTabColor   = $cfg.tabColor
        $selectedBgColor    = $cfg.bgColor
        $selectedTabChoice  = $cfg.tabChoice
        $selectedBgChoice   = $cfg.bgChoice
        break
    }
} else {
    $projItems = @()
    $projPaths = @()
    foreach ($p in $knownPaths) {
        $projItems += "📁 $p"
        $projPaths += $p
    }
    $projItems += "🔍 Browse"
    $projPaths += "__BROWSE__"

    :outer while ($true) {
        Draw-Header
        $choice = Show-Menu -MenuItems $projItems

        if ($choice -eq -1) { exit 0 }

        $target = $projPaths[$choice]
        if ($target -eq "__BROWSE__") {
            $browsed = Browse-Directory -StartPath $basedir
            if ($null -ne $browsed) { $target = $browsed } else { continue }
        }

        # Step 2: pick subdirectory within selected project
        $pickedPath = $null
        while ($null -eq $pickedPath) {
            $subMenu = Build-LocalMenu -BaseDir $target

            Clear-Host
            Write-Host ""
            Write-Host "   $CL▐▛███▜▌$R   ${B}Claude Code$R ${IN}v$cver$R"
            Write-Host "  $CL▝▜█████▛▘$R  $modelLine"
            $accountLine = if ($corg) { "$cemail  $corg" } else { $cemail }
            Write-Host "    $CL▘▘ ▝▝$R    ${IN}$accountLine$R"
            Write-Host ""
            Write-Host "   ${IN}Select a subdirectory or press Esc to go back.$R"
            Write-Host ""

            $subChoice = Show-Menu -MenuItems $subMenu.items -EscLabel "back"
            if ($subChoice -eq -1) { break }

            $subTarget = $subMenu.paths[$subChoice]
            if ($subTarget -eq "__BROWSE__") {
                $browsed = Browse-Directory -StartPath $target
                if ($null -ne $browsed) { $subTarget = $browsed } else { continue }
            }

            $cfg = Show-TabbedConfig -Path $subTarget
            if ($null -eq $cfg) { continue }

            $pickedPath         = $subTarget
            $selectedPath       = $pickedPath
            $selectedPermission = $cfg.permission
            $selectedModel      = $cfg.model
            $selectedEffort     = $cfg.effort
            $selectedExtras     = $cfg.extras
            $selectedTabColor   = $cfg.tabColor
            $selectedBgColor    = $cfg.bgColor
            $selectedTabChoice  = $cfg.tabChoice
            $selectedBgChoice   = $cfg.bgChoice
        }

        if ($null -ne $selectedPath) { break }
    }
}

Save-PathChoices -Path $selectedPath -Permission $selectedPermission -Model $selectedModel -Effort $selectedEffort `
                 -Extras $selectedExtras -TabColor $selectedTabChoice -BgColor $selectedBgChoice

# ultracode needs an xhigh-capable (Opus or Fable) model. Resolve the effective model and force Opus if needed.
# Runs after Save-PathChoices so the user's real model choice is preserved in per-path state.
# Capture the overridden model so the launch step can show a notice (this point gets cleared by Clear-Host).
$ultraForcedFrom = $null
if ($selectedEffort -eq "ultracode") {
    $effModel = if ($selectedModel) { $selectedModel } else { $settingsModel }
    # opusplan runs Sonnet outside plan mode, so it is NOT xhigh-capable despite the "opus" substring.
    # Fable 5 supports xhigh (same effort range as Opus 5), so it counts as capable too.
    $effTier = Get-ModelTier $effModel
    $isXhighCapable = ($effModel -notlike "opusplan*") -and ($effTier -eq "opus" -or $effTier -eq "fable")
    if (-not $isXhighCapable) {
        if ($selectedModel) { $ultraForcedFrom = $selectedModel }
        $selectedModel = "opus"
    }
}

$flags = @()
if ($selectedPermission) { $flags += @("--permission-mode", $selectedPermission) }
if ($selectedModel)      { $flags += @("--model", $selectedModel) }
if ($selectedEffort -eq "auto") {
    # --effort CLI accepts only low/medium/high/xhigh/max.
    # Inject effortLevel=auto via --settings overlay so it resolves at session start.
    $effortSettingsFile = Join-Path $env:TEMP "claude_launch_effort.json"
    [System.IO.File]::WriteAllText($effortSettingsFile, '{"effortLevel":"auto"}', [System.Text.UTF8Encoding]::new($false))
    $flags += @("--settings", $effortSettingsFile)
} elseif ($selectedEffort -eq "ultracode") {
    # ultracode = xhigh + standing dynamic workflows. --effort rejects it, so inject via --settings overlay
    # (verified to activate ultracode on an Opus model). Separate file from the auto branch so a delayed
    # .bat launch can't read the wrong payload.
    $ultraSettingsFile = Join-Path $env:TEMP "claude_launch_effort_ultracode.json"
    [System.IO.File]::WriteAllText($ultraSettingsFile, '{"effortLevel":"xhigh","ultracode":true,"enableWorkflows":true}', [System.Text.UTF8Encoding]::new($false))
    $flags += @("--settings", $ultraSettingsFile)
} elseif ($selectedEffort) {
    $flags += @("--effort", $selectedEffort)
}
foreach ($ekey in $selectedExtras) {
    $e = $extrasCatalog | Where-Object { $_.key -eq $ekey } | Select-Object -First 1
    if ($e -and $e.flag) { $flags += ($e.flag -split ' ') }
}

# statusline reads EFFORT_LEVEL; pass the selected level through verbatim so an ultracode
# launch renders as "ultracode" (statusline handles it as a known key now).
$effortEnv = $selectedEffort

# --- Terminal colors (Extras > Tab color / Background) ---
# Emitted from this console, so they are already in effect when claude takes over the same tab.
# Tab color is Windows Terminal only (color-table slot 264); the background tint is kept dark,
# or the text stops being readable.
# Unconditional: with both colors off this records an empty list, which RELEASES the colors
# this owner held. Skipping the call instead would leave a live PID reserving a color it no
# longer shows, blocking it for every other session.
$ownerPid = $PID
if ($FromBat) {
    # The launch .bat runs in the parent cmd.exe, which is what outlives this script. Falling
    # back to $PID would reserve under a process that exits the moment this script does, so the
    # next launcher prunes the entry and hands the color out again mid-session. Try WMI when
    # CIM is unavailable before settling for that.
    $parent = $null
    try { $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId } catch {}
    if (-not $parent) {
        try { $parent = (Get-WmiObject Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId } catch {}
    }
    # If BOTH queries fail we knowingly keep $PID. That is no worse than skipping the
    # reservation: either way the color ends up unreserved and can be handed out twice.
    if ($parent) { $ownerPid = [int]$parent }
}
Reserve-TabColor -OwnerPid $ownerPid -Names @($selectedTabColor.name, $selectedBgColor.name | Where-Object { $_ })
# No $env:WT_SESSION guard: it is set only when Windows Terminal starts the shell from a
# profile. Launched from the .lnk, the console is still hosted by Windows Terminal (default
# terminal app) and has a tab, but the variable is empty -- the guard silently dropped every
# shortcut launch. Measured in a legacy conhost: the sequence prints nothing, it just recolors
# that console's cursor. Harmless, so emit unconditionally rather than guess at the host.
# "off" resets rather than skipping, or relaunching in the same tab keeps the previous color.
if ($selectedTabColor) { [Console]::Write("$ESC]4;264;$(Get-OscColor $selectedTabColor.rgb)$ESC\") }
else                   { [Console]::Write("$ESC]104;264$ESC\") }
if ($selectedBgColor)  { [Console]::Write("$ESC]11;$(Get-OscColor $selectedBgColor.rgb 0.35)$ESC\") }
else                   { [Console]::Write("$ESC]111$ESC\") }

if ($FromBat) {
    $safePath = $selectedPath -replace '%','%%'
    $flagStr = if ($flags.Count -gt 0) { " " + ($flags -join " ") } else { "" }
    $envLine = if ($effortEnv) { "set `"EFFORT_LEVEL=$effortEnv`"`r`n" } else { "" }
    $noticeLine = if ($ultraForcedFrom) { "echo ultracode needs an xhigh-capable model - switched $ultraForcedFrom to opus.`r`ntimeout /t 2 /nobreak >NUL`r`n" } else { "" }
    $launchBat = "@echo off`r`nchcp 65001 >NUL`r`ncls`r`n${noticeLine}${envLine}cd /d `"$safePath`"`r`nclaude$flagStr"
    $tmpFile = Join-Path $env:TEMP "claude_launch.bat"
    [System.IO.File]::WriteAllText($tmpFile, $launchBat, [System.Text.UTF8Encoding]::new($false))
} else {
    Set-Location $selectedPath
    Clear-Host
    if ($ultraForcedFrom) { Write-Host "   ${OR}ultracode needs an xhigh-capable model — switched $ultraForcedFrom → opus.$R"; Write-Host ""; Start-Sleep -Seconds 2 }
    if ($effortEnv) { $env:EFFORT_LEVEL = $effortEnv }
    if ($flags.Count -gt 0) { & claude @flags } else { & claude }
}
