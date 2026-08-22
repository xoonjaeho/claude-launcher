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

function Get-LiveTabColors {
    # PID *and* process start time: a reused PID must not keep holding someone else's color.
    $live = @{}
    if (Test-Path $colorStatePath) {
        try {
            $obj = Get-Content $colorStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $obj.PSObject.Properties | ForEach-Object {
                $prop = $_
                try {
                    $proc = Get-Process -Id ([int]$prop.Name) -ErrorAction SilentlyContinue
                    if ($proc -and "$($proc.StartTime.Ticks)" -eq "$($prop.Value.start)") { $live[$prop.Name] = $prop.Value }
                } catch {}
            }
        } catch {}
    }
    return $live
}

function Get-UsedTabColors {
    $used = @()
    (Get-LiveTabColors).Values | ForEach-Object { $used += @($_.colors) }
    return @($used | Where-Object { $_ })
}

function Reserve-TabColor {
    param([int]$OwnerPid, [string[]]$Names)
    $live = Get-LiveTabColors
    try {
        $proc = Get-Process -Id $OwnerPid -ErrorAction SilentlyContinue
        if ($proc) { $live["$OwnerPid"] = @{ colors = @($Names); start = "$($proc.StartTime.Ticks)" } }
        $live | ConvertTo-Json -Depth 4 | Set-Content -Path $colorStatePath -Encoding UTF8
    } catch {}
}

function Select-TabColor {
    param([string[]]$Used)
    $free = @($tabPalette | Where-Object { $Used -notcontains $_.name })
    # ponytail: palette exhausted → reuse one; a duplicate beats no color at all.
    if ($free.Count -eq 0) { $free = $tabPalette }
    return $free[(Get-Random -Maximum $free.Count)]
}

if ($SelfTest) {
    $colorStatePath = Join-Path $env:TEMP "claude_launcher_colors_selftest.json"
    Remove-Item $colorStatePath -ErrorAction SilentlyContinue
    $me = Get-Process -Id $PID
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

    Remove-Item $colorStatePath -ErrorAction SilentlyContinue
    Write-Host "SelfTest OK"
    exit 0
}

function Get-ModelTier {
    param([string]$id)
    $lower = "$id".ToLower()
    foreach ($tier in @("fable","opus","sonnet","haiku")) {
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
if (-not $modelDisplay) {
    $defaultModels = @{ "max"="claude-opus-5"; "pro"="claude-sonnet-5"; "team"="claude-sonnet-5"; "enterprise"="claude-sonnet-5" }
    if ($sub -and $defaultModels.ContainsKey($sub)) { $modelDisplay = $defaultModels[$sub] }
}

# --- Model catalog (single source of truth for header + tab menu) ---
$modelCatalog = @(
    @{ id = "claude-fable-5";            name = "Fable 5";   tier = "fable" }
    @{ id = "claude-opus-5";             name = "Opus 5";    tier = "opus" }
    @{ id = "claude-sonnet-5";           name = "Sonnet 5";  tier = "sonnet" }
    @{ id = "claude-haiku-4-5-20251001"; name = "Haiku 4.5"; tier = "haiku" }
)
$modelNames = @{}
foreach ($m in $modelCatalog) { $modelNames[$m.id] = $m.name }
if ($modelDisplay -and $modelNames.ContainsKey($modelDisplay)) {
    $modelDisplay = $modelNames[$modelDisplay]
}

$permInheritDesc  = "Claude Code default"
$modelInheritVal  = if ($settingsModel -and $modelNames.ContainsKey($settingsModel)) { $modelNames[$settingsModel] } elseif ($settingsModel) { $settingsModel } else { "" }
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
    $top = [Console]::CursorTop
    $hint = "   ${IN}[↑↓] move  [1-9] jump  [Enter] select  [Esc] $EscLabel$R$ESC[K"

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
        Render

        while ($true) {
            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            $char = $key.Character
            if ($char -ge '1' -and $char -le '9') {
                $idx = [int]::Parse($char) - 1
                if ($idx -lt $MenuItems.Count) { return $idx }
            }
            switch ($key.VirtualKeyCode) {
                38 { if ($cursor -gt 0) { $cursor-- }; Render }
                40 { if ($cursor -lt $MenuItems.Count - 1) { $cursor++ }; Render }
                13 { return $cursor }
                27 { return -1 }
            }
        }
    } finally {
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
        Write-Host "   ${IN}[↑↓] move  [Enter] open  [Space] select here  [Esc] back$R"
        Write-Host ""

        $top = [Console]::CursorTop
        $cursor = 0

        Write-Host "$ESC[?25l" -NoNewline

        function Render-Tree {
            [Console]::SetCursorPosition(0, $top)
            for ($i = 0; $i -lt $dirNames.Count; $i++) {
                if ($i -eq $cursor) {
                    Write-Host "   $BL$B❯ $($dirNames[$i])$R$ESC[K"
                } else {
                    Write-Host "     $($dirNames[$i])$R$ESC[K"
                }
            }
        }

        try {
            Render-Tree

            $selected = $null
            while ($null -eq $selected) {
                $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                switch ($key.VirtualKeyCode) {
                    38 { if ($cursor -gt 0) { $cursor-- }; Render-Tree }
                    40 { if ($cursor -lt $dirNames.Count - 1) { $cursor++ }; Render-Tree }
                    13 {
                        if ($dirs[$cursor] -eq "..") {
                            $parent = Split-Path $current -Parent
                            if ($parent) { $current = $parent }
                        } else {
                            $current = $dirs[$cursor]
                        }
                        $selected = "NAVIGATE"
                    }
                    32 { return $current }
                    27 { return $null }
                }
            }
        } finally {
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
    @{ key="high";   label="high";    desc="Default for Opus 5 — balanced intelligence";         color=$EffortColors["high"]   }
    @{ key="xhigh";  label="xhigh";   desc="For the hardest tasks (Opus 5 recommended)";         color=$EffortColors["xhigh"]  }
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
    $maxItems = ($tabs | ForEach-Object { if ($_.isMulti) { $extrasCatalog.Count } else { $_.items.Count } } | Measure-Object -Maximum).Maximum
    # Render draws $maxItems + 5 lines down from $tabBarTop. Scroll that space in now: in a
    # short window the buffer would otherwise scroll mid-render and every later frame would
    # draw from a stale $tabBarTop, stranding rows of the previous tab on screen.
    $renderRows = $maxItems + 5
    for ($i = 0; $i -lt $renderRows; $i++) { Write-Host "" }
    $tabBarTop = [Math]::Max(0, [Console]::CursorTop - $renderRows)

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
        for ($i = 0; $i -lt $tabs.Count; $i++) {
            if ($i -eq $activeTab) { $bar += "$BL$B[ $($tabs[$i].name) ]$R  " }
            else                   { $bar += "$IN   $($tabs[$i].name)   $R  " }
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
        $pick = if ($tab.isMulti) { "[Space] toggle" } else { "[1-9] jump" }
        Write-Host "   ${IN}[←→] tab  [↑↓] move  $pick  [Enter] launch  [Esc] back$R$ESC[K"
    }

    Write-Host "$ESC[?25l" -NoNewline
    try {
        Render
        while ($true) {
            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            $char = $key.Character
            $tab = $tabs[$activeTab]
            if ($char -ge '1' -and $char -le '9') {
                $idx   = [int]::Parse($char) - 1
                $count = if ($tab.isMulti) { $extrasCatalog.Count } else { $tab.items.Count }
                if ($idx -lt $count) { $tab.cursor = $idx; Render }
                continue
            }
            switch ($key.VirtualKeyCode) {
                37 { if ($activeTab -gt 0)               { $activeTab-- }; Render }
                39 { if ($activeTab -lt $tabs.Count - 1) { $activeTab++ }; Render }
                38 { if ($tab.cursor -gt 0)              { $tab.cursor-- }; Render }
                40 {
                    $count = if ($tab.isMulti) { $extrasCatalog.Count } else { $tab.items.Count }
                    if ($tab.cursor -lt $count - 1) { $tab.cursor++ }
                    Render
                }
                32 {
                    if ($tab.isMulti) {
                        $e = $extrasCatalog[$tab.cursor]
                        if ($e.type -eq "color") {
                            Step-Color $e.kind
                        } else {
                            if ($extrasSelected[$e.key]) { $extrasSelected.Remove($e.key) } else { $extrasSelected[$e.key] = $true }
                        }
                        Render
                    }
                }
                13 {
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
                27 { return $null }
            }
        }
    } finally {
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
    # The launch .bat runs in the parent cmd.exe, which is what outlives this script.
    $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue).ParentProcessId
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
