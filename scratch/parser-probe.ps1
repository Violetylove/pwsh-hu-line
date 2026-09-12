# Probe: verify assumptions about [Parser]::ParseInput for path highlighting.
# Run: pwsh -NoProfile -File scratch/parser-probe.ps1

function Probe {
    param([string]$Label, [string]$Text)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    Write-Host "=== $Label : [$Text] ==="
    Write-Host ("errors: " + @($errors).Count)
    $cmdCount = 0
    $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object {
        $cmdCount++
        $c = $_
        Write-Host ("  CmdAST InvOp={0} Elements={1}" -f $c.InvocationOperator, $c.CommandElements.Count)
        for ($i = 0; $i -lt $c.CommandElements.Count; $i++) {
            $el = $c.CommandElements[$i]
            $kind = $el.GetType().Name
            $txt = ""
            $ext = ""
            if ($el -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $txt = " value=[$($el.Value)] type=$($el.StringConstantType)"
            }
            if ($el.Extent) { $ext = " extent={0}..{1} ('{2}')" -f $el.Extent.StartOffset, $el.Extent.EndOffset, $el.Extent.Text }
            Write-Host ("    [{0}] {1}{2}{3}" -f $i, $kind, $txt, $ext)
        }
    }
    if ($cmdCount -eq 0) { Write-Host "  (no CommandAst)" }
    Write-Host ("  tokens: " + (($tokens | ForEach-Object { $_.Kind.ToString() + ":'" + $_.Text + "'" }) -join ", "))
    Write-Host ""
}

Probe "bareword arg" "Get-ChildItem C:\Windows\System32"
Probe "single-quoted" "Get-ChildItem 'C:\Program Files'"
Probe "double-quoted plain" 'Get-ChildItem "C:\Windows"'
Probe "ampersand call" "& ./scripts/build.ps1 -Tag v1"
Probe "partial trailing token" "cd /usr/lo"
Probe "bare partial no separator" "git sta"
Probe "variable inside" 'Get-ChildItem $env:WINDIR\foo'
Probe "tilde" "Get-ChildItem ~/.config"
Probe "redirection" "Get-ChildItem C:\Windows > out.txt"
Probe "parameter with value" "Get-ChildItem -Path C:\Windows -Filter *.dll"
Probe "stop parsing --%" "cmd /c echo %PATH% --% C:\foo bar"
Probe "empty command" ""
