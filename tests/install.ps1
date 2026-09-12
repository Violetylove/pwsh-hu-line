#Requires -Version 7.0
# install.ps1 — end-to-end test for the deployment story (Install-PwshHuLine.ps1).
#
# The installer had never been executed: the user always ran demo.ps1 from the repo,
# so the deploy path (copy to a module root, patch $PROFILE, uninstall) was pure
# assumption. This drives it against TEMP paths via -ModuleRoot/-ProfilePath, so the
# real user profile is never touched.
#
# Usage: pwsh -NoProfile -File tests/install.ps1     (RESULT lines on stdout)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $root 'Install-PwshHuLine.ps1'
$stamp = [guid]::NewGuid().ToString('N').Substring(0, 8)
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) "hu-line-install-$stamp"
$moduleRoot = Join-Path $sandbox 'Modules'
$profilePath = Join-Path $sandbox 'profile.ps1'
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null

$script:Failed = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Ok) { Write-Host ("RESULT {0} PASS {1}" -f $Name, $Detail) }
    else { Write-Host ("RESULT {0} FAIL {1}" -f $Name, $Detail); $script:Failed++ }
}
function Read-Text([string]$Path) {
    if (-not [System.IO.File]::Exists($Path)) { return '' }
    return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
}
function Count-Of([string]$Text, [string]$Needle) {
    return ([regex]::Matches($Text, [regex]::Escape($Needle))).Count
}

# a profile with the user's own content AND the legacy unmarked wiring an earlier
# installer appended (the upgrade path that must not eat the user's lines)
$legacy = @(
    '# my own profile'
    'Set-Alias s scoop'
    'Import-Module pwsh-hu-line'
    'Enter-HuLineRepl'
) -join [System.Environment]::NewLine
[System.IO.File]::WriteAllText($profilePath, $legacy + [System.Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

& pwsh -NoProfile -File $installer -ModuleRoot $moduleRoot -ProfilePath $profilePath -Quiet | Out-Null
$installed = Join-Path $moduleRoot 'pwsh-hu-line'
$text = Read-Text $profilePath

Check 'install-copies-module' (Test-Path (Join-Path $installed 'pwsh-hu-line.psm1') -PathType Leaf) "psm1 at $installed"
Check 'install-copies-src-tree' (Test-Path (Join-Path $installed 'src/HuLine.ps1') -PathType Leaf) 'src/HuLine.ps1 present'
Check 'install-copies-every-class-file' `
    (@('HuCore.ps1', 'HuHistory.ps1', 'HuLine.ps1', 'HuMenu.ps1', 'HuCommand.ps1', 'HuLog.ps1' |
        Where-Object { -not (Test-Path (Join-Path $installed "src/$_") -PathType Leaf) }).Count -eq 0) 'all src files copied'
Check 'install-wires-profile-once' ((Count-Of $text '# >>> pwsh-hu-line') -eq 1 -and (Count-Of $text 'Enter-HuLineRepl') -eq 1) `
    ("blocks={0} repl-lines={1}" -f (Count-Of $text '# >>> pwsh-hu-line'), (Count-Of $text 'Enter-HuLineRepl'))
Check 'install-removes-legacy-wiring' ((Count-Of $text 'Import-Module pwsh-hu-line') -eq 1) 'only the marked block imports the module'
Check 'install-keeps-user-lines' ($text.Contains('Set-Alias s scoop') -and $text.Contains('# my own profile')) 'user content untouched'

# idempotent: a second install must not add a second block
& pwsh -NoProfile -File $installer -ModuleRoot $moduleRoot -ProfilePath $profilePath -Quiet | Out-Null
$text2 = Read-Text $profilePath
Check 'install-is-idempotent' ((Count-Of $text2 '# >>> pwsh-hu-line') -eq 1 -and (Count-Of $text2 'Enter-HuLineRepl') -eq 1) `
    ("blocks={0} repl-lines={1}" -f (Count-Of $text2 '# >>> pwsh-hu-line'), (Count-Of $text2 'Enter-HuLineRepl'))

# the DEPLOYED copy must import on its own (a half-copied tree must not pass)
$probe = @(& pwsh -NoProfile -Command "Import-Module '$(Join-Path $installed 'pwsh-hu-line.psd1')' -ErrorAction Stop; (Get-Command Read-HuLine).Name; (Get-Command Enter-HuLineRepl).Name; (Get-Command Get-HuRegions).Name" 2>&1)
Check 'deployed-module-imports' (($probe -contains 'Read-HuLine') -and ($probe -contains 'Enter-HuLineRepl') -and ($probe -contains 'Get-HuRegions')) `
    ("exports=[{0}]" -f (($probe | ForEach-Object { [string]$_ }) -join ' | '))

# the profile must actually load in a fresh shell (this is what "启动即接管" means)
$loaded = @(& pwsh -NoProfile -Command "`$env:PSModulePath = '$moduleRoot' + [IO.Path]::PathSeparator + `$env:PSModulePath; . '$profilePath' 2>&1 | Out-Null; (Get-Command Read-HuLine -ErrorAction SilentlyContinue).Name" 2>&1)
Check 'profile-loads-and-exports' ($loaded -contains 'Read-HuLine') ("loaded=[{0}]" -f (($loaded | ForEach-Object { [string]$_ }) -join ' | '))

# uninstall: module gone, profile unwired, user lines still there
& pwsh -NoProfile -File $installer -ModuleRoot $moduleRoot -ProfilePath $profilePath -Quiet -Uninstall | Out-Null
$text3 = Read-Text $profilePath
Check 'uninstall-removes-module' (-not (Test-Path -LiteralPath $installed)) 'module directory gone'
Check 'uninstall-unwires-profile' ((Count-Of $text3 'pwsh-hu-line') -eq 0 -and (Count-Of $text3 'Enter-HuLineRepl') -eq 0) 'no wiring left'
Check 'uninstall-keeps-user-lines' ($text3.Contains('Set-Alias s scoop')) 'user content untouched'

Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("SUMMARY failed={0}" -f $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
