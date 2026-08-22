param([switch]$FromBat)

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
    $choices = @{ permission = $null; model = $null; effort = $null }
    if ($entry -is [string]) {
        $choices.permission = $entry
    } elseif ($entry) {
        $choices.permission = $entry.permission
        $choices.model      = $entry.model
        $choices.effort     = $entry.effort
    }
    return $choices
}

function Save-PathChoices {
    param([string]$Path, $Permission, $Model, $Effort)
    $state = Get-LauncherState
    # ponytail: extras intentionally not persisted (session-only) — always store empty.
    $state.perPath[$Path] = @{ permission = $Permission; model = $Model; effort = $Effort; extras = @() }
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

    # ponytail: extras are session-only — never seeded from saved state, so the tab starts fresh each launch.
    $extrasSelected = @{}

    $tabs = @(
        @{ name = "Permission"; items = $permItems;   modes = $permModes;    cursor = $permStart;   isMulti = $false }
        @{ name = "Model";      items = $modelItems;  modes = $models;       cursor = $modelStart;  isMulti = $false }
        @{ name = "Effort";     items = $effortItems; modes = $efforts;      cursor = $effortStart; isMulti = $false }
        @{ name = "Extras";     items = @();          modes = $extrasCatalog; cursor = 0;           isMulti = $true  }
    )

    $activeTab = 0
    $maxItems = ($tabs | ForEach-Object { if ($_.isMulti) { $extrasCatalog.Count } else { $_.items.Count } } | Measure-Object -Maximum).Maximum
    $tabBarTop = [Console]::CursorTop

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
                    $e   = $extrasCatalog[$i]
                    $chk = if ($extrasSelected[$e.key]) { "$GN[x]$R" } else { "${IN}[ ]$R" }
                    $line = "$chk $WH$($e.label)$R  ${IN}— $($e.desc)$R"
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
            Write-Host "$ESC[K"
            Write-Host "   ${IN}[←→] tab  [↑↓] move  [Space] toggle  [Enter] launch  [Esc] back$R$ESC[K"
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
            Write-Host "$ESC[K"
            Write-Host "   ${IN}[←→] tab  [↑↓] move  [1-9] jump  [Enter] launch  [Esc] back$R$ESC[K"
        }
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
                        $ekey = $extrasCatalog[$tab.cursor].key
                        if ($extrasSelected[$ekey]) { $extrasSelected.Remove($ekey) } else { $extrasSelected[$ekey] = $true }
                        Render
                    }
                }
                13 {
                    return @{
                        permission = $tabs[0].modes[$tabs[0].cursor].key
                        model      = $tabs[1].modes[$tabs[1].cursor].key
                        effort     = $tabs[2].modes[$tabs[2].cursor].key
                        extras     = @($extrasSelected.Keys | Where-Object { $extrasSelected[$_] })
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
                if ($null -ne $browsed) { $pickedPath = $browsed }
                continue
            }

            $cfg = Show-TabbedConfig -Path $subTarget
            if ($null -eq $cfg) { continue }

            $pickedPath         = $subTarget
            $selectedPath       = $pickedPath
            $selectedPermission = $cfg.permission
            $selectedModel      = $cfg.model
            $selectedEffort     = $cfg.effort
            $selectedExtras     = $cfg.extras
        }

        if ($null -ne $selectedPath) { break }
    }
}

Save-PathChoices -Path $selectedPath -Permission $selectedPermission -Model $selectedModel -Effort $selectedEffort

# ultracode needs an xhigh-capable (Opus or Fable) model. Resolve the effective model and force Opus if needed.
# Runs after Save-PathChoices so the user's real model choice is preserved in per-path state.
# Capture the overridden model so the launch step can show a notice (this point gets cleared by Clear-Host).
$ultraForcedFrom = $null
if ($selectedEffort -eq "ultracode") {
    $effModel = if ($selectedModel) { $selectedModel } else { $settingsModel }
    # opusplan runs Sonnet outside plan mode, so it is NOT xhigh-capable despite the "opus" substring.
    # Fable 5 supports xhigh (same effort range as Opus 4.8), so it counts as capable too.
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
