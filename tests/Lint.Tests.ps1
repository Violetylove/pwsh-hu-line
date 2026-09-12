# Lint: PowerShell has NO C-style comments. `/* ... */` parses without error but
# is a COMMAND named '/*', so it only explodes when that branch actually runs —
# the worst kind of latent bug. It sat in AddTrailingPrefix's catch block and
# turned "enumeration failed" into "The term '/*' is not recognized", masking
# the original exception.
#
# This scans with the real parser instead of a regex so that regex literals such
# as '[*?\[\]]' or '[/\\]' cannot produce false positives.
It 'no source file contains a C-style comment (a command named /* or */)' {
    $repo = Split-Path -Parent $PSScriptRoot
    $files = @(Get-ChildItem -Path $repo -Recurse -File -Include '*.ps1', '*.psm1' |
        Where-Object { $_.FullName -notlike '*\scratch\dup\*' })   # scratch/dup is a generated copy
    Assert-True ($files.Count -gt 0) 'found source files to lint'

    $bad = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $files) {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
        # NOTE: $errors is ignored on purpose — files that reference classes from
        # other files (HuLine.ps1 → HuCore.ps1) report spurious type-resolution
        # errors here when parsed standalone (documented in AGENTS.md).
        $hits = @($ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -in @('/*', '*/')
        }, $true))
        if ($hits.Count -gt 0) { [void]$bad.Add($f.Name) }
    }
    Assert-Equal $bad.Count 0 ("files with C-style comments: " + ($bad -join ', '))
}
