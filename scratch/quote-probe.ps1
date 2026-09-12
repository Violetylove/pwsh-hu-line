# scratch/quote-probe.ps1 — how does the parser shape a quoted / ampersand command?
$inputs = @(
    "'Get-ChildItem' x",
    '& "Get-ChildItem" x',
    "& 'Get-ChildItem' x",
    '"Get-ChildItem" x',
    "Get-ChildItem 'C:\Windows'"
)
foreach ($src in $inputs) {
    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$t, [ref]$e)
    "=== [$src]  errors=$(@($e).Count) ==="
    foreach ($n in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        foreach ($i in 0..($n.CommandElements.Count - 1)) {
            $el = $n.CommandElements[$i]
            "   [{0}] {1} extent={2}..{3} text=[{4}]" -f $i, $el.GetType().Name, $el.Extent.StartOffset, $el.Extent.EndOffset, $el.Extent.Text
        }
    }
}
