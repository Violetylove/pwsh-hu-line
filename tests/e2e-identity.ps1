#Requires -Version 7.0
# e2e-identity.ps1 — regression driver for "two class identities, one name".
#
# A PowerShell class type identity is bound per module load. When a session ends
# up holding TWO copies of this module (a second path, a script-scope import, an
# installed copy next to a repo checkout), values built by one copy used to fail
# against signatures typed with the other copy:
#   "Cannot convert the HuLineBuffer value of type HuLineBuffer to type HuLineBuffer"
#   "Cannot find an overload for Add and the argument count: 1"
# Every class-typed parameter/property in src/ is now untyped (duck typing), so
# the second copy must work end to end: highlight → Tab completion → accept.
#
# Usage: pwsh -NoProfile -File tests/e2e-identity.ps1   (RESULT lines on stdout)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
# keep this run's diagnostic log in TEMP and read it back at the end
$env:HU_LINE_LOG = Join-Path ([System.IO.Path]::GetTempPath()) ('hu-line-identity-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
$dupDir = Join-Path ([System.IO.Path]::GetTempPath()) ('hu-line-dup-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$dupMod = Join-Path $dupDir 'pwsh-hu-line-dup'
New-Item -ItemType Directory -Force -Path $dupMod | Out-Null
Copy-Item (Join-Path $root 'src') $dupMod -Recurse -Force
Copy-Item (Join-Path $root 'pwsh-hu-line.psm1') $dupMod -Force
Copy-Item (Join-Path $root 'pwsh-hu-line.psd1') (Join-Path $dupMod 'pwsh-hu-line-dup.psd1') -Force

$script:Failed = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Ok) { Write-Host ("RESULT {0} PASS {1}" -f $Name, $Detail) }
    else { Write-Host ("RESULT {0} FAIL {1}" -f $Name, $Detail); $script:Failed++ }
}

# Drives Read-HuLine from the given command object: types $Text, optionally
# completes with Tab, then submits with Enter. Returns @{ Ok; Line; Error }.
function Drive([object]$Target, [string]$Text, [bool]$Complete) {
    $q = [System.Collections.Generic.List[System.ConsoleKeyInfo]]::new()
    foreach ($ch in $Text.ToCharArray()) { $q.Add([System.ConsoleKeyInfo]::new($ch, [ConsoleKey]::A, $false, $false, $false)) }
    if ($Complete) { $q.Add([System.ConsoleKeyInfo]::new("`t", [ConsoleKey]::Tab, $false, $false, $false)) }
    $q.Add([System.ConsoleKeyInfo]::new("`r", [ConsoleKey]::Enter, $false, $false, $false))
    $state = @{ I = 0 }
    $src = { if ($state.I -ge $q.Count) { throw 'KeySource exhausted' }; $v = $q[$state.I]; $state.I++; return $v }
    $sw = [System.IO.StringWriter]::new()
    try {
        $line = & $Target -Prompt '' -KeySource $src -OutWriter $sw
        return @{ Ok = $true; Line = $line; Error = '' }
    } catch {
        return @{ Ok = $false; Line = ''; Error = $_.Exception.Message }
    }
}

Set-Location $root
Import-Module (Join-Path $root 'pwsh-hu-line.psd1')
$first = @(Get-Command Read-HuLine) | Where-Object { $_.Module.Path -notlike '*hu-line-dup*' }

# Second copy under a different module name → every class name now has two
# identities in this session.
Import-Module (Join-Path $dupMod 'pwsh-hu-line-dup.psd1')
$second = @(Get-Command Read-HuLine) | Where-Object { $_.Module.Path -like '*hu-line-dup*' }

Check 'two-module-instances-loaded' (($null -ne $first) -and ($null -ne $second)) `
    ("first=[{0}] second=[{1}]" -f $first.Module.Path, $second.Module.Path)

# Single-match Tab goes through HuCompletionApplier.Apply — the path that used
# to throw "Cannot convert the HuLineBuffer value of type HuLineBuffer ...".
$r = Drive $second 'READ' $true
Check 'second-copy-single-match-apply' ($r.Ok -and ($r.Line -like '*README.md*')) `
    ("ok={0} line=[{1}] err={2}" -f $r.Ok, $r.Line, $r.Error)

# Highlighting builds HuRegion/HuStyle via the highlighter — the path that used
# to throw "Cannot find an overload for Add and the argument count: 1".
$r = Drive $second 'Get-ChildItem README' $true
Check 'second-copy-highlight-and-complete' ($r.Ok -and ($r.Line -like '*README.md*')) `
    ("ok={0} line=[{1}] err={2}" -f $r.Ok, $r.Line, $r.Error)

# The first copy must keep working with the second one loaded.
$r = Drive $first 'READ' $true
Check 'first-copy-still-works' ($r.Ok -and ($r.Line -like '*README.md*')) `
    ("ok={0} line=[{1}] err={2}" -f $r.Ok, $r.Line, $r.Error)

# The REPL host must refuse to take over a process holding more than one copy of
# the module — that is the state that yields the cryptic class-conversion error.
# (stdin is redirected here, but the guard runs before that check.)
$replWarnings = @()
Enter-HuLineRepl -WarningVariable replWarnings -WarningAction SilentlyContinue 6>$null 2>$null
$guardHit = @($replWarnings | Where-Object { $_ -like '*退出 pwsh*' }).Count -gt 0
Check 'repl-guard-detects-double-load' $guardHit ("warnings=[{0}]" -f (@($replWarnings) -join ' / '))

# The diagnostic log must contain the evidence trail: which class identities this
# copy resolved, and what the guard decided. This is the file that replaces
# guessing when something unexplainable happens in a real session.
$logText = ''
if (Test-Path -LiteralPath $env:HU_LINE_LOG) { $logText = [System.IO.File]::ReadAllText($env:HU_LINE_LOG, [System.Text.UTF8Encoding]::new($false)) }
Check 'diagnostic-log-has-identity' ($logText -like '*ident*HuLineBuffer=*') 'load-time identity fingerprint present'
Check 'diagnostic-log-has-guard' ($logText -like '*guard*copies=2*') ("guard decision with copies=2; log has {0} lines" -f (@($logText -split "`n").Count))
Remove-Item -LiteralPath $env:HU_LINE_LOG -ErrorAction SilentlyContinue

# demo.ps1 must refuse to start a second time in the same process: that is the
# state that produces a broken editor (every keystroke throws). Checked in a child
# process because it exits the shell.
$psd1 = Join-Path $root 'pwsh-hu-line.psd1'
$demo = Join-Path $root 'demo.ps1'
$demoOut = @(& pwsh -NoProfile -Command "Import-Module '$psd1'; & '$demo'" 2>&1)
$demoExit = $LASTEXITCODE
$demoText = ($demoOut | ForEach-Object { [string]$_ }) -join ' '
Check 'demo-refuses-dirty-process' (($demoExit -ne 0) -and ($demoText -like '*cannot be run twice*')) `
    ("exit={0} out=[{1}]" -f $demoExit, $demoText)

Remove-Item $dupDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("SUMMARY failed={0}" -f $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
