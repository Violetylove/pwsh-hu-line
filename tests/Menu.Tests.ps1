# HuMenu tests: completion wrapper, applier, menu renderer (rows/window/clear).

# --- HuCompletionApplier ---
It 'applier: replaces the token range' {
    $b = [HuLineBuffer]::new(); $b.SetText('Get-ChildItem C:\Wi')
    $item = [HuCompletion]::new('C:\Windows', 'Windows', 'ProviderContainer', 'C:\Windows')
    $cur = [HuCompletionApplier]::Apply($b, $item, 14, 5)
    Assert-Equal $b.Text 'Get-ChildItem C:\Windows' 'text'
    Assert-Equal $cur 24 'cursor'   # 14 + len('C:\Windows')=10
}
It 'applier: clamps out-of-range indices' {
    $b = [HuLineBuffer]::new(); $b.SetText('abc')
    $item = [HuCompletion]::new('X', 'X', 'Text', '')
    $cur = [HuCompletionApplier]::Apply($b, $item, -5, 999)
    Assert-Equal $b.Text 'X' 'text'
    Assert-Equal $cur 1 'cursor'
}
It 'applier: quoted completion pastes the quote into the buffer' {
    $b = [HuLineBuffer]::new(); $b.SetText('Get-ChildItem C:\Pro')
    $item = [HuCompletion]::new("'C:\Program Files'", 'Program Files', 'ProviderContainer', '')
    $cur = [HuCompletionApplier]::Apply($b, $item, 14, 6)   # 'C:\Pro' = 6 chars
    Assert-Equal $b.Text "Get-ChildItem 'C:\Program Files'" 'text'
    Assert-Equal $cur 32 'cursor'   # 14 + len("'C:\Program Files'")=18 → 14+18=32
}

# --- HuMenuRenderer ---
function New-Menu { [HuMenuRenderer]::new() }
function New-Items {
    param([string[]]$names)
    $list = [System.Collections.Generic.List[HuCompletion]]::new()
    foreach ($n in $names) { $list.Add([HuCompletion]::new($n, $n, 'Text', '')) }
    return $list
}

It 'menu: ComputeRows caps at maxRows' {
    $m = New-Menu
    Assert-Equal ($m.ComputeRows(5, 3)) 3 'fewer'
    Assert-Equal ($m.ComputeRows(5, 9)) 5 'capped'
    Assert-Equal ($m.ComputeRows(0, 9)) 0 'zero-max'
    Assert-Equal ($m.ComputeRows(5, 0)) 0 'no-items'
}
It 'menu: window scrolls with selection' {
    $m = New-Menu
    $items = New-Items @('a','b','c','d','e','f','g')
    $m.UpdateWindow(0, 4, 7) | Out-Null
    Assert-Equal $m.WindowStart 0 'start'
    $m.UpdateWindow(3, 4, 7) | Out-Null
    Assert-Equal $m.WindowStart 0 'selected-visible'
    $m.UpdateWindow(4, 4, 7) | Out-Null
    Assert-Equal $m.WindowStart 1 'scrolled-down'
    $m.UpdateWindow(6, 4, 7) | Out-Null
    Assert-Equal $m.WindowStart 3 'bottom-anchored'
    $m.UpdateWindow(0, 4, 7) | Out-Null
    Assert-Equal $m.WindowStart 0 'scrolled-back'
}
It 'menu: Draw renders rows with reverse-video selection and erases rows' {
    $m = New-Menu
    $items = New-Items @('Alpha','Beta','Gamma')
    $s = $m.Draw(10, 5, $items, 1)
    $parts = [regex]::Matches($s, "`e\[(\d+);1H`e\[2K") | ForEach-Object { [int]$_.Groups[1].Value }
    Assert-Equal ($parts -join ',') '11,12,13' 'rows'
    Assert-Contains $s "`e[7mBeta`e[27m" 'selected'
    Assert-NotContains $s "`e[7mAlpha" 'first-not-selected'
    Assert-Equal $m.RowsUsed 3 'rows-used'
}
It 'menu: Clear erases exactly what Draw drew' {
    $m = New-Menu
    $items = New-Items @('a','b','c','d')
    $null = $m.Draw(20, 3, $items, 0)
    Assert-Equal $m.RowsUsed 3 'rows-used'
    $c = $m.Clear(20)
    $rows = [regex]::Matches($c, "`e\[(\d+);1H`e\[2K") | ForEach-Object { [int]$_.Groups[1].Value }
    Assert-Equal ($rows -join ',') '21,22,23' 'cleared'
    Assert-Equal $m.RowsUsed 0 'reset'
}
It 'menu: Draw with no items is empty' {
    $m = New-Menu
    Assert-Equal ($m.Draw(5, 5, $null, 0)) '' 'null'
    Assert-Equal ($m.Draw(5, 5, (New-Items @()), 0)) '' 'empty'
}

# --- one row MUST be one terminal line (the "leftover characters" bug) ---
# PowerShell tooltips are multi-line; embedding them raw made a row emit CR/LF and
# wrap, and whatever landed outside the rows Clear() erases stayed on screen after
# a completion was accepted.
function New-TipItems([string]$name, [string]$tip) {
    $list = [System.Collections.Generic.List[HuCompletion]]::new()
    $list.Add([HuCompletion]::new($name, $name, 'Text', $tip))
    return $list
}

It 'menu: a multi-line tooltip collapses into one single-line row' {
    $m = New-Menu
    $items = New-TipItems 'Get-Alias' "Get-Alias [[-Name] <string[]>]`r`n`r`nGet-Alias [-Exclude <string[]>]"
    $s = $m.Draw(1, 5, $items, 0)
    Assert-NotContains $s "`r" 'no CR in the row'
    Assert-NotContains $s "`n" 'no LF in the row'
    Assert-Contains $s 'Get-Alias [[-Name] <string[]>]' 'tooltip text is kept'
}

It 'menu: a row is truncated to the renderer width' {
    $m = New-Menu
    $m.Width = 40
    $items = New-TipItems 'Get-AppLockerFileInformation' ('x' * 120)
    $s = $m.Draw(1, 5, $items, 0)
    $text = [regex]::Match($s, "`e\[2K(.+)$").Groups[1].Value
    $cells = [HuWidth]::OfAnsi($text)
    Assert-True ($cells -le 40) ("row is {0} cells, want <= 40" -f $cells)
    Assert-Contains $text ([string][char]0x2026) 'the cut is marked'
}

It 'menu: Width=0 disables truncation' {
    $m = New-Menu
    $m.Width = 0
    $items = New-TipItems 'abc' ('y' * 200)
    $s = $m.Draw(1, 5, $items, 0)
    Assert-True ($s.Length -gt 200) 'long row kept when truncation is off'
}

# --- a shorter draw must erase the previous, longer one --------------------
# The reported leftover: a tall menu was on screen, a later draw was shorter, and
# only the shorter row count got erased — so the rows below stayed visible.
It 'menu: a shorter Draw erases the tail of the previous longer draw' {
    $m = New-Menu
    $null = $m.Draw(10, 6, (New-Items @('a1', 'a2', 'a3', 'a4', 'a5', 'a6')), 0)
    Assert-Equal $m.RowsDrawn 6 'high-water recorded'
    $s = $m.Draw(10, 6, (New-Items @('b1', 'b2')), 0)
    $rows = [regex]::Matches($s, "`e\[(\d+);1H`e\[2K") | ForEach-Object { [int]$_.Groups[1].Value }
    Assert-Equal ($rows -join ',') '11,12,13,14,15,16' 'own rows plus the stale tail'
    Assert-Equal $m.RowsUsed 2 'last draw'
}

It 'menu: Clear erases down to the high-water mark' {
    $m = New-Menu
    $null = $m.Draw(10, 6, (New-Items @('a', 'b', 'c', 'd', 'e', 'f')), 0)
    $null = $m.Draw(10, 6, (New-Items @('x')), 0)
    $c = $m.Clear(10)
    $rows = [regex]::Matches($c, "`e\[(\d+);1H`e\[2K") | ForEach-Object { [int]$_.Groups[1].Value }
    Assert-Equal ($rows -join ',') '11,12,13,14,15,16' 'all six rows erased'
    Assert-Equal $m.RowsDrawn 0 'reset'
}