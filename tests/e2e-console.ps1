#Requires -Version 7.0
# Real-console regression for the render path of Read-HuLine.
#
# The editor draws through [Console]::Out, which encodes with the console's
# output code page (GB2312/CP936 on a Chinese Windows). Glyphs that page cannot
# represent — starship's ❯ (U+276F), Nerd-Font/Powerline private-use glyphs,
# emoji — are silently written as '?'. [HuConsoleEncoding] switches that page
# to UTF-8 for the duration of one edit loop.
#
# A pipe cannot reproduce this: redirection replaces the very encoder under
# test. So the runner starts this script under `conhost.exe --headless`, which
# attaches a real console, and the script reads the glyph back out of the
# screen buffer with $Host.UI.RawUI.GetBufferContents. stdout IS the console
# here, so results go to -ResultPath instead of stdout.
param([Parameter(Mandatory)][string]$ResultPath)

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/HuCore.ps1')

$lines = [System.Collections.Generic.List[string]]::new()
function Report([string]$Name, [bool]$Ok, [string]$Detail) {
    [void]$lines.Add(('RESULT {0} {1} {2}' -f $Name, $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Detail))
}
function Read-Cell([int]$Y) {
    $rect = [System.Management.Automation.Host.Rectangle]::new(0, $Y, 0, $Y)
    return $Host.UI.RawUI.GetBufferContents($rect)[0, 0].Character
}
# Details are printed by the runner through a CP936 pipe, so report code points
# rather than the glyph itself — otherwise a correct '❯' shows up as '?' in the
# test log and the evidence becomes unreadable.
function Code([string]$S) {
    if ([string]::IsNullOrEmpty($S)) { return '(empty)' }
    return ('U+{0:X4}' -f [int][char]$S[0])
}

$glyph = [string][char]0x276F      # ❯ U+276F — what starship's character module emits
try {
    # Deterministic premise: force the code page that loses the glyph.
    [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936)
    [Console]::SetCursorPosition(0, 2)
    [Console]::Out.Write($glyph)
    [Console]::Out.Flush()
    $before = Read-Cell 2
    Report 'cp936-baseline-mangles-glyph' ($before -eq '?') "cp936 Write(U+276F) -> [$(Code $before)]"

    $y = 4
    [Console]::SetCursorPosition(0, $y)
    $snapshot = [HuConsoleEncoding]::BeginUtf8()
    [Console]::Out.Write($glyph)
    [Console]::Out.Flush()
    $after = Read-Cell $y
    Report 'utf8-guard-renders-glyph' ($after -eq $glyph) "after BeginUtf8 Write(U+276F) -> [$(Code $after)]"

    [HuConsoleEncoding]::End($snapshot)
    Report 'utf8-guard-restores-codepage' ([Console]::OutputEncoding.CodePage -eq 936) "restored to CP$([Console]::OutputEncoding.CodePage)"
} catch {
    Report 'e2e-console-driver' $false $_.Exception.Message
}

# --- a profile-wired REPL must not swallow `pwsh -File ...` --------------------
# $PROFILE runs for EVERY pwsh start, and a `-File`/`-Command` launch keeps a real
# console on stdin — so the "stdin is redirected" check does NOT catch it and the
# REPL would take over, leaving the script unrun (the process just sits at the
# prompt waiting for a key). Reproducing that needs a real console, hence here:
# a grandchild pwsh, launched with -File against a temp $PROFILE that wires the
# module exactly like the installer does, must run its script to the end.
try {
    $probe = Join-Path ([System.IO.Path]::GetTempPath()) ('hu-line-launch-' + [guid]::NewGuid().ToString('N'))
    $probeHome = Join-Path $probe 'home'
    $profDir = Join-Path $probeHome 'Documents\PowerShell'
    New-Item -ItemType Directory -Force -Path $profDir | Out-Null
    $marker = Join-Path $probe 'script-ran.txt'
    $psd1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'pwsh-hu-line.psd1'

    # Exactly the installer's wiring. Overriding USERPROFILE points pwsh at this
    # throwaway profile, so the real one is never touched.
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Join-Path $profDir 'Microsoft.PowerShell_profile.ps1'),
        "Import-Module '$psd1'`r`nEnter-HuLineRepl`r`n", $utf8)
    $scriptPath = Join-Path $probe 'probe.ps1'
    [System.IO.File]::WriteAllText($scriptPath, "[System.IO.File]::WriteAllText('$marker', 'ran')`r`n", $utf8)

    $oldHome = $env:USERPROFILE
    $oldLog = $env:HU_LINE_LOG
    $env:USERPROFILE = $probeHome
    $env:HU_LINE_LOG = Join-Path $probe 'child.log'
    try {
        $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
        $p = Start-Process -FilePath $conhost -PassThru `
            -ArgumentList '--headless', 'pwsh', '-File', $scriptPath
        # A regressed guard parks the child at the prompt forever: bound the wait,
        # then kill the tree so the suite cannot hang.
        $exited = $p.WaitForExit(30000)
        if (-not $exited) { $p.Kill($true); $p.WaitForExit(5000) }
        $ran = Test-Path -LiteralPath $marker
        Report 'scripted-launch-is-not-swallowed' ($ran -and $exited) `
            "script ran=$ran exited=$exited waited=$(-not $exited)"
    } finally {
        $env:USERPROFILE = $oldHome
        $env:HU_LINE_LOG = $oldLog
        Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {
    Report 'scripted-launch-driver' $false $_.Exception.Message
}

[System.IO.File]::WriteAllText($ResultPath, ($lines -join "`n"), [System.Text.UTF8Encoding]::new($false))
