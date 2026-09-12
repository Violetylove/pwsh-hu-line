#Requires -Version 7.0
# Zero-dependency test runner (PowerShell Gallery is unreachable in this
# environment, so no Pester). Usage:  pwsh -NoProfile -File tests/run-tests.ps1
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/HuCore.ps1')
. (Join-Path $root 'src/HuHistory.ps1')
. (Join-Path $root 'src/HuLine.ps1')
. (Join-Path $root 'src/HuMenu.ps1')
. (Join-Path $root 'src/HuCommand.ps1')

$script:Passed = 0
$script:Failed = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()

function It {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host ("  [PASS] " + $Name) -ForegroundColor Green
    } catch {
        $script:Failed++
        $script:Failures.Add($Name + ' :: ' + $_.Exception.Message)
        Write-Host ("  [FAIL] " + $Name) -ForegroundColor Red
        Write-Host ("         " + $_.Exception.Message) -ForegroundColor Red
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Label)
    if (-not $Condition) { throw "expected true: $Label" }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) { throw "expected [$Expected], got [$Actual]: $Label" }
}

function Assert-Contains {
    param([string]$Actual, [string]$Fragment, [string]$Label)
    # Ordinal: rendered output is full of ESC sequences, and culture-sensitive
    # IndexOf treats control characters as ignorable — it would happily "find"
    # ESC[4m inside "[4m" and turn the assertion vacuous.
    if ($Actual.IndexOf($Fragment, [System.StringComparison]::Ordinal) -lt 0) { throw "expected to contain [$Fragment], got [$Actual]: $Label" }
}

function Assert-NotContains {
    param([string]$Actual, [string]$Fragment, [string]$Label)
    if ($Actual.IndexOf($Fragment, [System.StringComparison]::Ordinal) -ge 0) { throw "expected NOT to contain [$Fragment], got [$Actual]: $Label" }
}

# Collects one "RESULT <name> <PASS|FAIL> <detail>" line from an E2E driver
# (tests/e2e-loop.ps1, tests/e2e-console.ps1).
function Add-E2EResult {
    param([string]$Line, [string]$Source)
    $p = $Line -split ' ', 4
    if ($p.Count -lt 3) { return }
    $detail = if ($p.Count -ge 4) { $p[3] } else { '' }
    if ($p[2] -eq 'PASS') {
        $script:Passed++
        Write-Host ('  [PASS] ' + $p[1] + ' :: ' + $detail) -ForegroundColor Green
    } else {
        $script:Failed++
        $script:Failures.Add($Source + ' ' + $p[1] + ' :: ' + $detail)
        Write-Host ('  [FAIL] ' + $p[1] + ' :: ' + $detail) -ForegroundColor Red
    }
}

Write-Host '== hu-line tests =='

Get-ChildItem (Join-Path $PSScriptRoot '*.Tests.ps1') | Sort-Object Name | ForEach-Object {
    Write-Host ('-- ' + $_.Name)
    . $_.FullName
}

# --- module smoke tests (fresh pwsh processes, avoids class redefinition) ---
Write-Host '-- module smoke'
$rootEsc = $root.Replace("'", "''")
$sysRoot = $env:SystemRoot

$importProbe = Join-Path ([System.IO.Path]::GetTempPath()) ('hu-line-import-' + [guid]::NewGuid().ToString('N') + '.txt')
$importLines = pwsh -NoProfile -Command "Import-Module '$rootEsc\pwsh-hu-line.psd1'; Write-Output ((Get-Command Read-HuLine).Name); Write-Output ((Get-Command Enter-HuLineRepl).Name); Write-Output ((Get-Command Get-HuRegions).Name); Write-Output ((Get-HuRegions -Text 'Get-ChildItem $sysRoot' -LocationPath '$sysRoot').Count)" 2>$null
$ok = ($importLines.Count -ge 4) -and ($importLines[0] -eq 'Read-HuLine') -and ($importLines[1] -eq 'Enter-HuLineRepl') -and ($importLines[2] -eq 'Get-HuRegions') -and ($importLines[3] -eq '1')
if ($ok) { $script:Passed++; Write-Host '  [PASS] module imports, exports work, highlighter region count = 1' -ForegroundColor Green }
else {
    $script:Failed++; $script:Failures.Add('module import smoke :: ' + ($importLines -join ' | '))
    Write-Host '  [FAIL] module import smoke' -ForegroundColor Red
    Write-Host ("         " + ($importLines -join ' | ')) -ForegroundColor Red
}

$pipeOut = @('piped line test' | pwsh -NoProfile -Command "Import-Module '$rootEsc\pwsh-hu-line.psd1'; Read-HuLine") 2>$null
if (($pipeOut.Count -eq 1) -and ($pipeOut[0] -eq 'piped line test')) {
    $script:Passed++; Write-Host '  [PASS] Read-HuLine falls back to ReadLine when stdin is redirected' -ForegroundColor Green
} else {
    $script:Failed++; $script:Failures.Add('piped fallback :: ' + ($pipeOut -join ' | '))
    Write-Host '  [FAIL] Read-HuLine piped fallback' -ForegroundColor Red
}

# Key-loop end-to-end tests (own process; drives Read-HuLine with a key queue
# via the -KeySource hook and asserts on results + captured screen output).
Write-Host '-- editor loop E2E'
$loopOut = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'e2e-loop.ps1') 2>&1
$loopResults = @($loopOut | Where-Object { $_ -like 'RESULT *' })
$loopFailed = @($loopResults | Where-Object { $_ -like 'RESULT * FAIL *' })
foreach ($r in $loopResults) { Add-E2EResult -Line $r -Source 'e2e-loop' }
if ($loopResults.Count -eq 0) {
    $script:Failed++; $script:Failures.Add('e2e-loop :: no results (driver crashed)')
    Write-Host '  [FAIL] e2e-loop driver produced no results' -ForegroundColor Red
    $loopOut | Select-Object -Last 5 | ForEach-Object { Write-Host ('         ' + $_) -ForegroundColor Red }
}

# The editor draws through [Console]::Out, which is encoded with the console's
# output code page — CP936 here, which cannot represent starship's ❯ (U+276F)
# and writes '?' instead. That is only reproducible on a REAL console, so the
# driver runs under `conhost.exe --headless` (available since Win10 1809) and
# reads the glyph back out of the screen buffer. No conhost → skipped.
Write-Host '-- console encoding (real console)'
$conhost = Join-Path $env:SystemRoot 'System32/conhost.exe'
if (Test-Path $conhost) {
    $encResult = Join-Path ([System.IO.Path]::GetTempPath()) ('hu-line-enc-' + [guid]::NewGuid().ToString('N') + '.txt')
    & $conhost --headless pwsh -NoProfile -File (Join-Path $PSScriptRoot 'e2e-console.ps1') -ResultPath $encResult 2>&1 | Out-Null
    $encLines = @()
    if (Test-Path $encResult) { $encLines = @(Get-Content $encResult) }
    foreach ($r in ($encLines | Where-Object { $_ -like 'RESULT *' })) { Add-E2EResult -Line $r -Source 'e2e-console' }
    if ($encLines.Count -eq 0) {
        $script:Failed++; $script:Failures.Add('e2e-console :: no results (driver crashed)')
        Write-Host '  [FAIL] e2e-console driver produced no results' -ForegroundColor Red
    }
    Remove-Item $encResult -ErrorAction SilentlyContinue
} else {
    Write-Host '  [SKIP] conhost.exe not found — real-console encoding check skipped' -ForegroundColor DarkGray
}

# Two copies of the module in one session = two identities for every class name.
# Class-typed members used to blow up there ("Cannot convert the HuLineBuffer
# value of type HuLineBuffer to type HuLineBuffer"); the driver loads a real
# second copy and asserts it still works end to end.
Write-Host '-- module identity (two copies loaded)'
$idOut = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'e2e-identity.ps1') 2>&1
$idResults = @($idOut | Where-Object { $_ -like 'RESULT *' })
foreach ($r in $idResults) { Add-E2EResult -Line $r -Source 'e2e-identity' }
if ($idResults.Count -eq 0) {
    $script:Failed++; $script:Failures.Add('e2e-identity :: no results (driver crashed)')
    Write-Host '  [FAIL] e2e-identity driver produced no results' -ForegroundColor Red
    $idOut | Select-Object -Last 5 | ForEach-Object { Write-Host ('         ' + $_) -ForegroundColor Red }
}

# Deployment: the installer copies the module, wires $PROFILE between markers and
# can undo both — driven against TEMP paths so the real profile is never touched.
Write-Host '-- install / uninstall'
$instOut = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'e2e-install.ps1') 2>&1
$instResults = @($instOut | Where-Object { $_ -like 'RESULT *' })
foreach ($r in $instResults) { Add-E2EResult -Line $r -Source 'e2e-install' }
if ($instResults.Count -eq 0) {
    $script:Failed++; $script:Failures.Add('e2e-install :: no results (driver crashed)')
    Write-Host '  [FAIL] e2e-install driver produced no results' -ForegroundColor Red
    $instOut | Select-Object -Last 5 | ForEach-Object { Write-Host ('         ' + $_) -ForegroundColor Red }
}

Write-Host ''
Write-Host ("passed: $script:Passed   failed: $script:Failed")
if ($script:Failed -gt 0) {
    Write-Host 'Failures:'
    $script:Failures | ForEach-Object { Write-Host ('  - ' + $_) -ForegroundColor Red }
    exit 1
}
exit 0
