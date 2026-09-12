#Requires -Version 7.0
# Install-PwshHuLine.ps1 — deploy the module and wire "启动即接管" into $PROFILE.
#
#   pwsh -NoProfile -File Install-PwshHuLine.ps1
#   pwsh -NoProfile -File Install-PwshHuLine.ps1 -Uninstall
#   pwsh -NoProfile -File Install-PwshHuLine.ps1 -ModuleRoot D:\mods -ProfilePath D:\me.ps1
#
# The profile is patched between MARKERS, so installing twice changes nothing and
# uninstalling is exact. The first version appended bare lines and matched them by
# substring — it could not tell its own lines from the user's.
param(
    [string]$ModuleRoot = (Join-Path $HOME 'Documents\PowerShell\Modules'),
    [string]$ProfilePath = $PROFILE,
    [switch]$Uninstall,
    [switch]$SkipProfile,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
$moduleName = 'pwsh-hu-line'
$dest = Join-Path $ModuleRoot $moduleName
$begin = "# >>> $moduleName (launch at startup) >>>"
$end = "# <<< $moduleName <<<"

function Say([string]$Message, [string]$Color = 'Cyan') {
    if (-not $Quiet) { Write-Host $Message -ForegroundColor $Color }
}

# Drops our marked block, plus the bare lines older installs appended (matched
# EXACTLY, so the user's own lines are never touched).
function Get-ProfileWithoutWiring([string]$Text) {
    $out = [System.Collections.Generic.List[string]]::new()
    $inside = $false
    foreach ($line in @($Text -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -eq $begin) { $inside = $true; continue }
        if ($t -eq $end) { $inside = $false; continue }
        if ($inside) { continue }
        if ($t -eq "Import-Module $moduleName" -or $t -eq 'Enter-HuLineRepl') { continue }
        [void]$out.Add($line)
    }
    return (($out -join [System.Environment]::NewLine).TrimEnd() + [System.Environment]::NewLine)
}

if ($Uninstall) {
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force
        Say "Removed module: $dest"
    } else {
        Say "Module not installed at $dest" 'DarkGray'
    }
    if (-not $SkipProfile -and (Test-Path -LiteralPath $ProfilePath)) {
        $text = Get-Content -LiteralPath $ProfilePath -Raw
        $clean = Get-ProfileWithoutWiring $text
        if ($clean -ne $text) {
            [System.IO.File]::WriteAllText($ProfilePath, $clean, [System.Text.UTF8Encoding]::new($false))
            Say "Unwired $ProfilePath"
        } else {
            Say "$ProfilePath was not wired" 'DarkGray'
        }
    }
    Say 'Done. Start a NEW pwsh session.' 'Green'
    exit 0
}

# --- install ------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item (Join-Path $repo 'src') $dest -Recurse -Force
Copy-Item (Join-Path $repo "$moduleName.psm1") $dest -Force
Copy-Item (Join-Path $repo "$moduleName.psd1") $dest -Force
Say "Installed module -> $dest"

# Sanity: the DEPLOYED copy must import (catches a half-copied tree, which the repo
# copy would never reveal).
$probe = & pwsh -NoProfile -Command "Import-Module '$dest/$moduleName.psd1' -ErrorAction Stop; (Get-Command Enter-HuLineRepl).Name" 2>&1
if ($probe -notcontains 'Enter-HuLineRepl') {
    Write-Warning "The deployed module does not import; something is missing under $dest"
    $probe | ForEach-Object { Write-Warning "  $_" }
    exit 1
}
Say 'Verified: the deployed copy imports and exports Enter-HuLineRepl' 'DarkGray'

if (-not $SkipProfile) {
    $profileDir = Split-Path -Parent $ProfilePath
    if ($profileDir) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }
    $existing = if (Test-Path -LiteralPath $ProfilePath) { Get-Content -LiteralPath $ProfilePath -Raw } else { '' }
    $body = (Get-ProfileWithoutWiring $existing).TrimEnd()
    $block = @($begin, "Import-Module $moduleName", 'Enter-HuLineRepl', $end) -join [System.Environment]::NewLine
    $nl = [System.Environment]::NewLine
    [System.IO.File]::WriteAllText($ProfilePath, ($body + $nl + $nl + $block + $nl), [System.Text.UTF8Encoding]::new($false))
    Say "Wired $ProfilePath (marker-delimited, idempotent)"
}

Say ''
Say 'Done. Start a NEW pwsh session; it enters the hu-line REPL automatically.' 'Green'
Say 'Inside the REPL: "stock" falls back to the stock prompt, "exit" quits pwsh.' 'DarkGray'
