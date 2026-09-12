# scratch/screen-model.ps1 — a tiny terminal model, so "what is left on screen"
# can be computed instead of eyeballed. Models CSI cursor addressing (H/G), EL
# (K), wrapping at a given width, LF = CR+LF (Windows console behaviour), and
# scrolling. Feed it the captured -OutWriter stream of a driven session.
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/HuHistory.ps1')
Import-Module (Join-Path $root 'pwsh-hu-line.psd1') -Force

function Get-Screen([string]$Stream, [int]$Rows, [int]$Width) {
    $grid = @()
    for ($i = 0; $i -lt $Rows; $i++) { $grid += , ([char[]]::new($Width)) }
    for ($i = 0; $i -lt $Rows; $i++) { for ($j = 0; $j -lt $Width; $j++) { $grid[$i][$j] = ' ' } }
    $row = 0; $col = 0
    $i = 0
    $len = $Stream.Length
    while ($i -lt $len) {
        $c = $Stream[$i]
        if ($c -eq [char]27 -and ($i + 1) -lt $len -and $Stream[$i + 1] -eq '[') {
            $j = $i + 2
            $sb = [System.Text.StringBuilder]::new()
            while ($j -lt $len -and -not [char]::IsLetter($Stream[$j])) { [void]$sb.Append($Stream[$j]); $j++ }
            $final = if ($j -lt $len) { $Stream[$j] } else { '?' }
            $args2 = $sb.ToString() -split ';'
            switch ($final) {
                'H' {
                    $r = if ($args2.Count -ge 1 -and $args2[0] -ne '') { [int]$args2[0] - 1 } else { 0 }
                    $cc = if ($args2.Count -ge 2 -and $args2[1] -ne '') { [int]$args2[1] - 1 } else { 0 }
                    $row = [Math]::Max(0, [Math]::Min($Rows - 1, $r)); $col = [Math]::Max(0, [Math]::Min($Width - 1, $cc))
                }
                'G' { $cc = if ($args2[0] -ne '') { [int]$args2[0] - 1 } else { 0 }; $col = [Math]::Max(0, [Math]::Min($Width - 1, $cc)) }
                'K' {
                    $mode = if ($args2[0] -eq '') { 0 } else { [int]$args2[0] }
                    if ($mode -eq 2) { for ($k = 0; $k -lt $Width; $k++) { $grid[$row][$k] = ' ' } }
                    else { for ($k = $col; $k -lt $Width; $k++) { $grid[$row][$k] = ' ' } }
                }
                'J' {
                    $mode = if ($args2[0] -eq '') { 0 } else { [int]$args2[0] }
                    if ($mode -eq 2) { for ($r2 = 0; $r2 -lt $Rows; $r2++) { for ($k = 0; $k -lt $Width; $k++) { $grid[$r2][$k] = ' ' } } }
                }
            }
            $i = $j + 1
            continue
        }
        if ($c -eq "`r") { $col = 0; $i++; continue }
        if ($c -eq "`n") {
            $row++; $col = 0
            if ($row -ge $Rows) {   # scroll: drop the top line
                for ($r2 = 0; $r2 -lt $Rows - 1; $r2++) { $grid[$r2] = $grid[$r2 + 1] }
                $grid[$Rows - 1] = [char[]]::new($Width)
                for ($k = 0; $k -lt $Width; $k++) { $grid[$Rows - 1][$k] = ' ' }
                $row = $Rows - 1
            }
            $i++
            continue
        }
        if ([int]$c -lt 32) { $i++; continue }
        if ($col -ge $Width) { $col = 0; $row++; if ($row -ge $Rows) { $row = $Rows - 1 } }
        $grid[$row][$col] = $c
        $col++
        $i++
    }
    return ($grid | ForEach-Object { (-join $_).TrimEnd() })
}

function Drive([string[]]$Chars) {
    $q = [System.Collections.Generic.List[System.ConsoleKeyInfo]]::new()
    foreach ($c in $Chars) {
        if ($c -eq 'TAB') { $q.Add([System.ConsoleKeyInfo]::new("`t", [ConsoleKey]::Tab, $false, $false, $false)) }
        elseif ($c -eq 'ENTER') { $q.Add([System.ConsoleKeyInfo]::new("`r", [ConsoleKey]::Enter, $false, $false, $false)) }
        else { $q.Add([System.ConsoleKeyInfo]::new([char]$c, [ConsoleKey]::A, $false, $false, $false)) }
    }
    $state = @{ I = 0 }
    $src = { if ($state.I -ge $q.Count) { throw 'exhausted' }; $v = $q[$state.I]; $state.I++; return $v }
    $sw = [System.IO.StringWriter]::new()
    try { $line = Read-HuLine -Prompt '' -KeySource $src -OutWriter $sw } catch { $line = "ERR $($_.Exception.Message)" }
    return @{ Line = $line; Screen = $sw.ToString() }
}

$out = [System.Collections.Generic.List[string]]::new()
Set-Location ([System.Environment]::GetFolderPath('UserProfile'))
foreach ($w in @(60, 80, 100, 140)) {
    foreach ($spec in @(
            @(@('c', 'd', ' ', '~', '/', 'TAB', 'ENTER'), 'cd ~/ + TAB + ENTER'),
            @(@('G', 'e', 't', '-', 'TAB', 'ENTER'), 'Get- + TAB + ENTER'))) {
        $r = Drive $spec[0]
        $screen = Get-Screen $r.Screen 24 $w
        [void]$out.Add("### width=$w  $($spec[1])  line=[$($r.Line)]")
        $n = 0
        foreach ($rowText in $screen) {
            [void]$out.Add(('  {0,2}| {1}' -f $n, $rowText))
            $n++
        }
        [void]$out.Add('')
    }
}
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'screen-model.txt'), ($out -join "`r`n"), [System.Text.UTF8Encoding]::new($false))
