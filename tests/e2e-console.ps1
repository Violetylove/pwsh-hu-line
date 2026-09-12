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

[System.IO.File]::WriteAllText($ResultPath, ($lines -join "`n"), [System.Text.UTF8Encoding]::new($false))
