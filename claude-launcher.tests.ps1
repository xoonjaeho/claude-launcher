<#
  Live input-injection tests for claude-launcher.

  `claude-launcher.ps1 -SelfTest` covers the pure parts: decoding an INPUT_RECORD and the
  viewport/tab-bar arithmetic. It cannot cover the half where the bugs actually lived -- that a
  real console record reaches the right handler and changes the right thing on screen. Two
  defects got through -SelfTest and were only caught here: a `return ,$segs` that made
  `Get-TabSegments | Where-Object` see one array instead of four segments, and a `$r` loop
  counter silently overwriting `$R`, the ANSI reset.

  So this drives the real launcher: it starts one in its own console, writes records into that
  console with WriteConsoleInput, and reads the rendered screen back with
  ReadConsoleOutputCharacter. Rows and columns are located by their text, never hard-coded, so
  the tests survive a re-layout.

  Wheel scrolling needs a list longer than the console, which no real directory here guarantees,
  so a fixture of $FixtureDirs empty directories is created next to the launcher and removed
  afterwards.

  Run:  powershell -NoProfile -File claude-launcher.tests.ps1
  Exit: 0 all passed, 1 otherwise.

  -Launcher may point at a copy -- a mutant, say -- but that copy must sit in THIS directory. The
  child is started here and the fixture is created here, and the browse scenario only reaches the
  fixture because this directory has session history under ~/.claude/projects, which is what puts
  the launcher in its known-project flow. A copy run from anywhere else takes the project-list
  flow instead, Browse opens somewhere else, and the fixture assertion fails as if the launcher
  were broken.
#>
param(
    [string]$Launcher    = "$PSScriptRoot\claude-launcher.ps1",
    [string]$FixtureName = ".test-many-dirs",
    [int]   $FixtureDirs = 60,
    [int]   $BootMs      = 15000       # the launcher shells out to `claude` twice before drawing
)

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class TCon {
    [StructLayout(LayoutKind.Sequential)] public struct COORD { public short X; public short Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SMALL_RECT { public short Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct CSBI {
        public COORD dwSize; public COORD dwCursorPosition; public ushort wAttributes;
        public SMALL_RECT srWindow; public COORD dwMaximumWindowSize;
    }
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string n, uint a, uint s, IntPtr sa, uint d, uint f, IntPtr t);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool WriteConsoleInputW(IntPtr h, byte[] b, uint n, out uint w);
    // CharSet.Unicode is load-bearing: the default is Ansi, and an Ansi-marshalled StringBuilder
    // handed to a W function reads back empty.
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool ReadConsoleOutputCharacterW(IntPtr h, StringBuilder sb, uint n, COORD c, out uint r);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CSBI i);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
}
'@

$out = New-Object Collections.Generic.List[string]
$pass = 0; $fail = 0
# Nothing may be printed while attached to the child's console -- it would land on the child's
# screen and corrupt the very thing being asserted. Everything is buffered until the end.
function Say($m) { $out.Add($m) }
function Ok($m)   { $script:pass++; Say "  PASS  $m" }
function Bad($m)  { $script:fail++; Say "  FAIL  $m" }

$fixture = Join-Path (Split-Path $Launcher -Parent) $FixtureName
$child = $null; $hIn = [IntPtr]::Zero; $hOut = [IntPtr]::Zero

# --- console plumbing -------------------------------------------------------------------------

function Start-Launcher {
    $script:child = Start-Process powershell -PassThru -WorkingDirectory (Split-Path $Launcher -Parent) `
                    -ArgumentList '-NoProfile', '-File', $Launcher, '-FromBat'
    [void][TCon]::FreeConsole()
    # The console exists only once the child has created it, so retry rather than sleeping blind.
    $deadline = [datetime]::UtcNow.AddMilliseconds(10000)
    while (-not [TCon]::AttachConsole([uint32]$script:child.Id)) {
        if ([datetime]::UtcNow -gt $deadline) { throw "could not attach to the launcher console" }
        Start-Sleep -Milliseconds 200
    }
    $rw = [uint32]2147483648 -bor [uint32]1073741824
    $script:hIn  = [TCon]::CreateFileW("CONIN$",  $rw, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    $script:hOut = [TCon]::CreateFileW("CONOUT$", $rw, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
}

function Stop-Launcher {
    if ($script:hIn  -ne [IntPtr]::Zero) { [void][TCon]::CloseHandle($script:hIn);  $script:hIn  = [IntPtr]::Zero }
    if ($script:hOut -ne [IntPtr]::Zero) { [void][TCon]::CloseHandle($script:hOut); $script:hOut = [IntPtr]::Zero }
    [void][TCon]::FreeConsole()
    if ($script:child -and -not $script:child.HasExited) { $script:child.Kill() }
    $script:child = $null
}

function Get-Rows {
    $i = New-Object TCon+CSBI
    if (-not [TCon]::GetConsoleScreenBufferInfo($hOut, [ref]$i)) { return @() }
    $w = $i.dwSize.X
    $rows = @()
    for ($y = $i.srWindow.Top; $y -le $i.srWindow.Bottom; $y++) {
        $sb = New-Object Text.StringBuilder ($w + 1)
        $c = New-Object TCon+COORD; $c.X = 0; $c.Y = $y
        $n = [uint32]0
        # ReadConsoleOutputCharacter does not terminate the buffer, so cut it to what it wrote.
        if ([TCon]::ReadConsoleOutputCharacterW($hOut, $sb, [uint32]$w, $c, [ref]$n)) {
            $rows += [pscustomobject]@{ Y = $y; Text = $sb.ToString(0, [int]$n).TrimEnd() }
        }
    }
    # No `,$rows`: callers pipe this straight into Where-Object, and the comma would hand them
    # the whole array as a single item -- the same trap that broke Get-TabSegments.
    return $rows
}

# Waits for a row to match, and returns it. Polling beats a fixed sleep: the launcher shells out
# to `claude` on startup and that is the slowest, least predictable part of every scenario.
function Wait-Row([string]$Pattern, [int]$TimeoutMs = 6000) {
    $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($true) {
        $hit = Get-Rows | Where-Object { $_.Text -match $Pattern } | Select-Object -First 1
        if ($hit) { return $hit }
        if ([datetime]::UtcNow -gt $deadline) { return $null }
        Start-Sleep -Milliseconds 150
    }
}

# --- record injection -------------------------------------------------------------------------

function New-Rec([uint16]$Type) { $r = New-Object byte[] 20; [BitConverter]::GetBytes($Type).CopyTo($r, 0); return ,$r }

function Send-Recs($Recs) {
    # @(,$rec) at every call site: @($rec) would unroll a byte[] into 20 separate bytes.
    $buf = New-Object byte[] (20 * $Recs.Count)
    for ($i = 0; $i -lt $Recs.Count; $i++) { $Recs[$i].CopyTo($buf, $i * 20) }
    $w = [uint32]0
    [void][TCon]::WriteConsoleInputW($hIn, $buf, [uint32]$Recs.Count, [ref]$w)
}

function Send-Key([int]$Vk, [char]$Ch = [char]0) {
    $d = New-Rec 1; $d[4] = 1
    [BitConverter]::GetBytes([uint16]1).CopyTo($d, 8)       # wRepeatCount
    [BitConverter]::GetBytes([uint16]$Vk).CopyTo($d, 10)
    [BitConverter]::GetBytes([uint16]$Ch).CopyTo($d, 14)    # UnicodeChar: the 1-9 jump reads this
    $u = New-Rec 1
    [BitConverter]::GetBytes([uint16]1).CopyTo($u, 8)
    [BitConverter]::GetBytes([uint16]$Vk).CopyTo($u, 10)
    [BitConverter]::GetBytes([uint16]$Ch).CopyTo($u, 14)
    Send-Recs @($d, $u)
}

function Send-Click([int]$Row, [int]$Col) {
    $d = New-Rec 2
    [BitConverter]::GetBytes([int16]$Col).CopyTo($d, 4)
    [BitConverter]::GetBytes([int16]$Row).CopyTo($d, 6)
    [BitConverter]::GetBytes([uint32]1).CopyTo($d, 8)     # FROM_LEFT_1ST_BUTTON_PRESSED
    $u = New-Rec 2
    [BitConverter]::GetBytes([int16]$Col).CopyTo($u, 4)
    [BitConverter]::GetBytes([int16]$Row).CopyTo($u, 6)   # release: buttons clear
    Send-Recs @($d, $u)
}

function Send-Wheel([int]$Delta) {
    $r = New-Rec 2
    [BitConverter]::GetBytes([int32]($Delta -shl 16)).CopyTo($r, 8)   # signed, in the high word
    [BitConverter]::GetBytes([uint32]4).CopyTo($r, 16)                # MOUSE_WHEELED
    Send-Recs @(,$r)
}

# Clicks the row whose text matches $Pattern, at the column where $At starts within it (default:
# a few columns in). Locating by text is what keeps these tests independent of the layout.
function Click-Row([string]$Pattern, [string]$At = $null, [int]$TimeoutMs = 6000) {
    $row = Wait-Row $Pattern $TimeoutMs
    if (-not $row) { return $false }
    $col = if ($At) { $row.Text.IndexOf($At) } else { 6 }
    if ($col -lt 0) { return $false }
    Send-Click $row.Y $col
    return $true
}

function Get-Position {
    # Browse's windowing indicator, e.g. "   4-26 / 61".
    $row = Wait-Row '^\s*\d+-\d+ / \d+$' 4000
    if (-not $row -or $row.Text -notmatch '(\d+)-(\d+) / (\d+)') { return $null }
    return [pscustomobject]@{ First = [int]$Matches[1]; Last = [int]$Matches[2]; Total = [int]$Matches[3] }
}

function Get-LaunchBat {
    $p = Join-Path $env:TEMP "claude_launch.bat"
    for ($i = 0; $i -lt 20; $i++) {
        if (Test-Path $p) { return [IO.File]::ReadAllText($p) }
        Start-Sleep -Milliseconds 200
    }
    return ""
}
function Clear-LaunchBat { Remove-Item (Join-Path $env:TEMP "claude_launch.bat") -ErrorAction SilentlyContinue }

# --- setup -------------------------------------------------------------------------------------

$out.Add("=== claude-launcher -SelfTest ===")
$st = & powershell -NoProfile -File $Launcher -SelfTest 2>&1
if (($st -join "`n") -match 'SelfTest OK') { Ok "-SelfTest" } else { Bad "-SelfTest: $($st -join ' ')" }

# -NoMenu -DryRun is what Claude drives from a console-less shell, so these run it as a plain
# subprocess and read only its exit code, stderr and last stdout line. USERPROFILE points at a
# seeded profile: a saved per-path choice the launch must ignore, and a defaultMode it must report.
$out.Add("")
$out.Add("=== -NoMenu -DryRun ===")
$here        = Split-Path $Launcher -Parent
$profileDir  = Join-Path $env:TEMP "claude-launcher-nomenu-profile"
$seededState = Join-Path $profileDir ".claude\claude-launcher.json"
$realState   = Join-Path $env:USERPROFILE ".claude\claude-launcher.json"
$realProfile = $env:USERPROFILE
$prevClaudeCode = $env:CLAUDECODE
$utf8 = [System.Text.UTF8Encoding]::new($false)
New-Item -ItemType Directory -Path (Join-Path $profileDir ".claude") -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $profileDir ".claude\settings.json"), '{"permissions":{"defaultMode":"plan"}}', $utf8)
[IO.File]::WriteAllText($seededState, (@{ perPath = @{ $here = @{ permission = "bypassPermissions"; model = "opus"; effort = "max"; extras = @() } } } | ConvertTo-Json -Depth 5), $utf8)
function Get-Sha($p) { if (Test-Path $p) { (Get-FileHash $p -Algorithm SHA256).Hash } else { "absent" } }
$seededHash = Get-Sha $seededState
$realHash   = Get-Sha $realState

function Invoke-DryRun([string[]]$LauncherArgs) {
    $prevEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = $utf8          # the child writes UTF-8; the prompt below is Korean
    try { $lines = @(& powershell -NoProfile -File $Launcher -NoMenu -DryRun @LauncherArgs 2>&1); $code = $LASTEXITCODE }
    finally { [Console]::OutputEncoding = $prevEnc }
    $stdout = @($lines | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    $json = $null
    if ($stdout.Count -gt 0) { try { $json = $stdout[-1] | ConvertFrom-Json } catch {} }
    [pscustomobject]@{ Code = $code; Json = $json; Stdout = ($stdout -join " | ")
                       Stderr = (@($lines | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join " ") }
}
function Test-Rejected($Name, $R) {
    if ($R.Code -eq 1 -and -not $R.Json) { Ok "$Name -> exit 1, no JSON" } else { Bad "$Name -> exit $($R.Code), stdout: $($R.Stdout)" }
}

try {
    $env:USERPROFILE = $profileDir
    $env:CLAUDECODE  = "1"
    $r = Invoke-DryRun @("-Path", $here)
    if ($r.Code -ne 0 -or -not $r.Json) { Bad "(a) a plain run did not end in JSON: exit $($r.Code), stderr: $($r.Stderr)" }
    else {
        if (@($r.Json.argv).Count -eq 0 -and $null -eq $r.Json.env.EFFORT_LEVEL) { Ok "(a) every option omitted -> no flags, no EFFORT_LEVEL, despite a saved choice" }
        else { Bad "(a) omitted options produced argv [$(@($r.Json.argv) -join ' ')] EFFORT_LEVEL=$($r.Json.env.EFFORT_LEVEL)" }
        if ($r.Json.inheritedMode -eq "plan" -and $r.Json.cwd -eq $here) { Ok "inheritedMode read from permissions.defaultMode, cwd resolved" }
        else { Bad "inheritedMode=$($r.Json.inheritedMode) cwd=$($r.Json.cwd)" }
        if (@($r.Json.envRemoved) -contains "CLAUDECODE") { Ok "(m) CLAUDECODE is removed before launch" }
        else { Bad "(m) envRemoved lacks CLAUDECODE: [$(@($r.Json.envRemoved) -join ' ')]" }
    }

    $prompt = "한글 `"fix this`" ; %PATH% & C:\dir with space\`n/next"
    $hex = -join ([Text.Encoding]::UTF8.GetBytes($prompt) | ForEach-Object { $_.ToString("x2") })
    $r = Invoke-DryRun @("-Path", $here, "-Mode", "plan", "-PromptHex", $hex)
    $want = @("--permission-mode", "plan", "--", $prompt)
    $got  = @(if ($r.Json) { $r.Json.argv })
    if ($r.Code -eq 0 -and $got.Count -eq $want.Count -and -not (Compare-Object $got $want -SyncWindow 0 -CaseSensitive)) { Ok "(l) a hex prompt lands after -- verbatim, last line is JSON" }
    else { Bad "(l) exit $($r.Code), argv [$($got -join ' | ')], stderr: $($r.Stderr)" }

    $r = Invoke-DryRun @("-Path", $here, "-Mode", "bogus")
    Test-Rejected "(d) -Mode bogus" $r
    if ($r.Stderr -match 'bypassPermissions') { Ok "(d) the rejection names the allowed modes" } else { Bad "(d) stderr: $($r.Stderr)" }
    Test-Rejected "(g) nonexistent -Path" (Invoke-DryRun @("-Path", (Join-Path $here "no-such-dir")))
    Test-Rejected "(h) -NoMenu -FromBat" (Invoke-DryRun @("-Path", $here, "-FromBat"))
    Test-Rejected "(i) no -Path" (Invoke-DryRun @())
} finally {
    $env:USERPROFILE = $realProfile
    if ($null -eq $prevClaudeCode) { Remove-Item env:CLAUDECODE -ErrorAction SilentlyContinue } else { $env:CLAUDECODE = $prevClaudeCode }
}
if ((Get-Sha $seededState) -eq $seededHash -and (Get-Sha $realState) -eq $realHash) { Ok "(f) claude-launcher.json unchanged (seeded and real)" }
else { Bad "(f) a -NoMenu run rewrote claude-launcher.json" }
Remove-Item $profileDir -Recurse -Force -ErrorAction SilentlyContinue

$out.Add("")
$out.Add("=== fixture ===")
if (Test-Path $fixture) { Remove-Item $fixture -Recurse -Force }
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
1..$FixtureDirs | ForEach-Object { New-Item -ItemType Directory -Path (Join-Path $fixture ("d{0:d2}" -f $_)) -Force | Out-Null }
$out.Add("  $FixtureDirs directories under $fixture")
$out.Add("")
$out.Add("=== injected input ===")

try {

# --- scenarios ---------------------------------------------------------------------------------

function Scenario([string]$Name, [scriptblock]$Body, [string]$UserProfile) {
    Say $Name
    Clear-LaunchBat
    $prevProfile = $env:USERPROFILE
    try { if ($UserProfile) { $env:USERPROFILE = $UserProfile }; Start-Launcher; & $Body } catch { Bad "threw: $_" }
    finally { $env:USERPROFILE = $prevProfile; Stop-Launcher }
}

# Which menu model lacks effort control is the installed catalog's call, and a catalog can give
# every family the full ladder. The scenarios that need one without it run on a copy of the real
# profile whose cached catalog has the menu's Haiku ladder emptied; the cache stamp still matches
# the installed binary, so the launcher uses it instead of rescanning.
function New-NoEffortHaikuProfile {
    $dir  = Join-Path $env:TEMP "claude-launcher-no-effort-profile"
    $real = Join-Path $env:USERPROFILE ".claude"
    $cache = Get-Content (Join-Path $real "claude-launcher-models.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $haiku = @($cache.effort | Where-Object { $_.id -eq $cache.latest.haiku })
    if ($haiku.Count -ne 1) { throw "the cached catalog has no entry for $($cache.latest.haiku)" }
    $haiku[0].levels = @(); $haiku[0].cost = @{}
    # The same project names as the real profile keep the launcher in the known-project flow these
    # scenarios click through; the launcher reads only the directory names.
    Get-ChildItem (Join-Path $real "projects") -Directory | ForEach-Object {
        New-Item -ItemType Directory -Force -Path (Join-Path $dir ".claude\projects\$($_.Name)") | Out-Null
    }
    $settings = Join-Path $real "settings.json"
    if (Test-Path $settings) { Copy-Item $settings (Join-Path $dir ".claude\settings.json") -Force }
    [IO.File]::WriteAllText((Join-Path $dir ".claude\claude-launcher-models.json"), ($cache | ConvertTo-Json -Depth 10 -Compress), [System.Text.UTF8Encoding]::new($false))
    return $dir
}

# The launcher's first screen, after `claude --version` and `claude auth status` have returned.
# Anchored on the footer, which Show-Menu's own Render draws -- NOT on the "Select a directory"
# header above it, which is printed before Show-Menu is even called. Enable-MouseInput flushes the
# input buffer immediately before that first Render, so anything injected while only the header is
# on screen is discarded and the scenario silently does nothing.
function Wait-Boot { Wait-Row '\[Esc\] (quit|back)' $BootMs }

Scenario "menu: a click selects the item under the pointer" {
    if (-not (Wait-Boot)) { Bad "the launcher never drew its first menu"; return }
    if (-not (Click-Row '^\s*\S*\s*1\..*\(current\)')) { Bad "no current-directory row to click"; return }
    if (Wait-Row 'Configure this session') { Ok "click advanced to the configuration screen" }
    else { Bad "click did not advance past the directory menu" }
}

Scenario "config: a click on the tab bar switches tab" {
    if (-not (Wait-Boot)) { Bad "the launcher never drew its first menu"; return }
    if (-not (Click-Row '^\s*\S*\s*1\..*\(current\)')) { Bad "no current-directory row to click"; return }
    if (-not (Wait-Row 'Configure this session')) { Bad "never reached the configuration screen"; return }
    if (-not (Click-Row '\[ Permission \]' 'Model')) { Bad "no tab bar to click"; return }
    # The regression this pins: the click threw inside Show-Config, which returned $null, and the
    # caller read that as Esc and went back to the directory menu.
    if (Wait-Row '\[ Model \]' 3000) { Ok "the Model tab became active" } else { Bad "the tab did not switch" }
    if (Wait-Row 'Select a (directory|project)' 3000) { Bad "fell back to the directory menu" }
    elseif (Wait-Row '\[Esc\] back' 1000) { Ok "stayed on the configuration screen" }
    else { Bad "neither screen is on display" }
}

Scenario "config: a click on an item launches with it selected" {
    if (-not (Wait-Boot)) { Bad "the launcher never drew its first menu"; return }
    if (-not (Click-Row '^\s*\S*\s*1\..*\(current\)')) { Bad "no current-directory row to click"; return }
    if (-not (Click-Row '\d+\. plan\b')) { Bad "the Permission tab has no plan row"; return }
    $bat = Get-LaunchBat
    if ($bat -match '--permission-mode plan') { Ok "launched with --permission-mode plan" }
    else { Bad "launch command was: $($bat -replace '\r?\n', ' | ')" }
}

Scenario "config: a click on an Extras row toggles instead of launching" {
    if (-not (Wait-Boot)) { Bad "the launcher never drew its first menu"; return }
    if (-not (Click-Row '^\s*\S*\s*1\..*\(current\)')) { Bad "no current-directory row to click"; return }
    if (-not (Click-Row '\[ Permission \]' 'Extras')) { Bad "no tab bar to click"; return }
    if (-not (Wait-Row '\[ Extras \]' 3000)) { Bad "the Extras tab did not open"; return }
    if (-not (Click-Row '^\s*\d+\. \S')) { Bad "the Extras tab has no rows"; return }
    if (Wait-Row '\[x\]' 3000) { Ok "the checkbox toggled on" } else { Bad "nothing toggled" }
    if ((Get-LaunchBat) -eq "") { Ok "a click on a checkbox did not launch" } else { Bad "it launched" }
    # ...and the footer must not have told the user it would.
    $foot = Wait-Row '\[Esc\] back' 2000
    if (-not $foot) { Bad "no footer on the Extras tab" }
    elseif ($foot.Text -match '\[Enter/click\] launch') { Bad "the Extras footer promises a click launches" }
    else { Ok "the Extras footer promises only what a click does there" }
}

Scenario "config: the keyboard path launches the same way a click does" {
    if (-not (Wait-Boot)) { Bad "the launcher never drew its first menu"; return }
    if (-not (Click-Row '^\s*\S*\s*1\..*\(current\)')) { Bad "no current-directory row to click"; return }
    if (-not (Wait-Row 'Configure this session')) { Bad "never reached the configuration screen"; return }
    Send-Key 0x31 '1'          # jump to Permission item 1, "inherit", which passes no flag
    Start-Sleep -Milliseconds 500
    Send-Key 13                # Enter
    $bat = Get-LaunchBat
    if ($bat -notmatch 'cd /d') { Bad "Enter did not launch"; return }
    Ok "Enter launched"
    # Same Get-Result that a click goes through, so this pins the keyboard half of that shared exit.
    if ($bat -match '--permission-mode') { Bad "'inherit' still passed a permission flag: $($bat -replace '\r?\n', ' | ')" }
    else { Ok "the keyboard-picked item is what got launched" }
}

# The Effort tab is derived from the Model tab, and only a real console can show that the
# derivation actually reaches the screen when the Model cursor moves. Model rows are ordered by
# $ModelTiers: 1 inherit, 2 Fable, 3 Opus, 4 Sonnet, 5 Haiku.
$noEffortProfile = try { New-NoEffortHaikuProfile } catch { Bad "could not seed a catalog without Haiku effort: $_"; $null }
Scenario "config: the Effort tab follows the model" -UserProfile $noEffortProfile {
    if (-not (Wait-Boot)) { Bad "the launcher never drew its first menu"; return }
    if (-not (Click-Row '^\s*\S*\s*1\..*\(current\)')) { Bad "no current-directory row to click"; return }
    if (-not (Wait-Row 'Configure this session')) { Bad "never reached the configuration screen"; return }
    if (-not (Click-Row '\[ Permission \]' 'Model')) { Bad "no tab bar to click"; return }
    if (-not (Wait-Row '\[ Model \]' 3000)) { Bad "the Model tab did not open"; return }
    Send-Key 0x33 '3'          # Opus: the full ladder
    Start-Sleep -Milliseconds 300
    if (-not (Click-Row '\[ Model \]' 'Effort')) { Bad "could not reach the Effort tab"; return }
    if (-not (Wait-Row '\[ Effort \]' 3000)) { Bad "the Effort tab did not open"; return }
    # Which level is marked is the installed binary's call -- Opus 4.7 defaults to xhigh, Opus 5 to
    # high -- so pin the marker, not the level, or a model release breaks a working launcher.
    if (Wait-Row '\d+\. \S+ \(default\)' 2000) { Ok "the model's default level is marked" }
    else { Bad "no default marker on the Opus ladder" }
    # With the percentage: a bare xhigh row also exists in the catalog-less fallback ladder, so
    # matching only the level would pass with the whole derivation removed.
    if (Wait-Row '\d+\. xhigh\b.*\d+%' 2000) { Ok "a supported level is offered, priced" } else { Bad "Opus lost xhigh or its price" }

    if (-not (Click-Row '\[ Effort \]' 'Model')) { Bad "could not get back to the Model tab"; return }
    if (-not (Wait-Row '\[ Model \]' 3000)) { Bad "the Model tab did not reopen"; return }
    Send-Key 0x35 '5'          # Haiku: no effort control at all
    Start-Sleep -Milliseconds 300
    if (-not (Click-Row '\[ Model \]' 'Effort')) { Bad "could not reach the Effort tab again"; return }
    if (-not (Wait-Row '\[ Effort \]' 3000)) { Bad "the Effort tab did not reopen"; return }
    if (-not (Wait-Row '\d+\. auto\b' 2000)) { Bad "the Effort tab lost every row"; return }
    if (Wait-Row '\d+\. (low|medium|high|xhigh|max)\b' 1500) { Bad "a model with no effort control still offered levels" }
    else { Ok "a model with no effort control offers none" }
}

# A click on a Model row is the one path that changes the model and launches without drawing
# another frame, so it is the one that shipped a level the new model does not accept.
Scenario "config: clicking a model launches without the previous model's effort" -UserProfile $noEffortProfile {
    if (-not (Wait-Boot)) { Bad "the launcher never drew its first menu"; return }
    if (-not (Click-Row '^\s*\S*\s*1\..*\(current\)')) { Bad "no current-directory row to click"; return }
    if (-not (Wait-Row 'Configure this session')) { Bad "never reached the configuration screen"; return }
    if (-not (Click-Row '\[ Permission \]' 'Model')) { Bad "no tab bar to click"; return }
    if (-not (Wait-Row '\[ Model \]' 3000)) { Bad "the Model tab did not open"; return }
    Send-Key 0x33 '3'          # Opus, whose ladder has max
    Start-Sleep -Milliseconds 300
    if (-not (Click-Row '\[ Model \]' 'Effort')) { Bad "could not reach the Effort tab"; return }
    if (-not (Wait-Row '\[ Effort \]' 3000)) { Bad "the Effort tab did not open"; return }
    Send-Key 0x37 '7'          # max
    Start-Sleep -Milliseconds 300
    # Without this the assertion below would also pass having selected nothing at all.
    if (-not (Wait-Row 'Effort\s+max\b' 2000)) { Bad "max was not selected on the Effort tab"; return }
    if (-not (Click-Row '\[ Effort \]' 'Model')) { Bad "could not get back to the Model tab"; return }
    if (-not (Wait-Row '\[ Model \]' 3000)) { Bad "the Model tab did not reopen"; return }
    if (-not (Click-Row '\d+\. Haiku')) { Bad "the Model tab has no Haiku row"; return }
    $bat = Get-LaunchBat
    if ($bat -notmatch '--model haiku') { Bad "the clicked model did not launch: $($bat -replace '\r?\n', ' | ')"; return }
    Ok "the clicked model launched"
    if ($bat -match '--effort') { Bad "carried the previous model's effort: $($bat -replace '\r?\n', ' | ')" }
    else { Ok "a level Haiku does not accept was dropped" }
}

Scenario "input queued before a transition must not act on the next screen" {
    if (-not (Wait-Boot)) { Bad "the launcher never drew its first menu"; return }
    $b = Wait-Row 'Browse'
    if (-not $b) { Bad "no Browse row to click"; return }
    # Both presses land in the buffer in one write, so the second is queued before Show-Menu has
    # returned. Row 6 is the second entry of the browser list, so if the stale press survives the
    # transition it opens the fixture directory. Measured doing exactly that before the fix.
    Send-Click $b.Y 6
    Send-Click 6 6
    Start-Sleep -Milliseconds 2500
    $p = Wait-Row 'Browse  ' 3000
    if (-not $p) { Bad "never reached the browser"; return }
    if ($p.Text -match [regex]::Escape($FixtureName)) { Bad "the queued press opened $FixtureName on the next screen" }
    else { Ok "the queued press was discarded at the screen boundary" }
}

Scenario "menu: the wheel moves the cursor" {
    if (-not (Wait-Boot)) { Bad "the launcher never drew its first menu"; return }
    Send-Wheel -120; Start-Sleep -Milliseconds 250
    Send-Wheel -120
    if (-not (Wait-Row '❯\s*3\.' 3000)) { Bad "two wheel-down notches did not reach item 3"; return }
    Ok "two wheel-down notches moved the cursor to item 3"
    Send-Wheel 120
    if (Wait-Row '❯\s*2\.' 3000) { Ok "a wheel-up notch moved it back" } else { Bad "wheel up did nothing" }
}

Scenario "browse: a long list is windowed and the wheel scrolls it" {
    if (-not (Wait-Boot)) { Bad "the launcher never drew its first menu"; return }
    if (-not (Click-Row 'Browse')) { Bad "no Browse row to click"; return }
    if (-not (Wait-Row 'select here')) { Bad "the browser did not open"; return }
    if (-not (Click-Row ([regex]::Escape($FixtureName)))) { Bad "the fixture directory is not listed"; return }

    $p = Get-Position
    if (-not $p) { Bad "no position line -- the list was not windowed"; return }
    if ($p.Total -ne ($FixtureDirs + 1)) { Bad "expected $($FixtureDirs + 1) entries, the line says $($p.Total)"; return }
    if ($p.First -ne 1) { Bad "the window did not start at the top ($($p.First))"; return }
    if ($p.Last -ge $p.Total) { Bad "the whole list fits, so nothing is being windowed"; return }
    Ok "$($FixtureDirs + 1) entries windowed to $($p.Last - $p.First + 1) rows"

    Send-Wheel -120
    Start-Sleep -Milliseconds 400
    $q = Get-Position
    if (-not $q) { Bad "the position line vanished after a wheel notch"; return }
    if ($q.First -eq ($p.First + 3) -and $q.Total -eq $p.Total) { Ok "one wheel-down notch scrolled 3 rows" }
    else { Bad "wheel down moved the window from $($p.First) to $($q.First)" }

    Send-Wheel 120
    Start-Sleep -Milliseconds 400
    $r2 = Get-Position
    if ($r2 -and $r2.First -eq $p.First) { Ok "a wheel-up notch scrolled back" }
    else { Bad "wheel up left the window at $($r2.First)" }

    # Nothing above the top: the clamp must hold rather than run the index negative.
    Send-Wheel 120; Start-Sleep -Milliseconds 300
    $s2 = Get-Position
    if ($s2 -and $s2.First -eq 1) { Ok "scrolling past the top clamps" } else { Bad "the top clamp failed" }
}


} finally {
    Stop-Launcher
    if (Test-Path $fixture) { Remove-Item $fixture -Recurse -Force }
    if ($noEffortProfile -and (Test-Path $noEffortProfile)) { Remove-Item $noEffortProfile -Recurse -Force }
    Clear-LaunchBat          # the last launching scenario leaves one behind otherwise
}

# Only now is it safe to print: every FreeConsole has run, so this lands on the caller's stdout
# instead of on a launcher screen an assertion was about to read.
$out | ForEach-Object { Write-Host $_ }
Write-Host ""
Write-Host "$pass passed, $fail failed"
exit ([int]($fail -gt 0))
