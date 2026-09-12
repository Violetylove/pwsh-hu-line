# Renderer tests: region overlay → SGR output + cursor column math + suggestion.

function New-Renderer { [HuRegionRenderer]::new() }
function New-U { param([int]$s, [int]$e) [HuRegion]::new($s, $e, [HuStyle]::new($true, $false, '')) }

It 'render: plain line' {
    $r = (New-Renderer).Render('', 'abc', 3, @(), '')
    Assert-Equal $r.Text 'abc' 'text'
    Assert-Equal $r.CursorColumn 4 'col'
}
It 'render: with prompt' {
    $r = (New-Renderer).Render('PS> ', 'abc', 3, @(), '')
    Assert-Equal $r.Text 'PS> abc' 'text'
    Assert-Equal $r.CursorColumn 8 'col'   # prompt 'PS> ' is 4 cells
}
It 'render: underline middle span' {
    $r = (New-Renderer).Render('', 'abcdef', 3, @(New-U 1 4), '')
    Assert-Equal $r.Text ("a`e[4mbcd`e[24mef") 'text'
    Assert-Equal $r.CursorColumn 4 'col'
}
It 'render: underline whole line' {
    $r = (New-Renderer).Render('', 'abcdef', 6, @(New-U 0 6), '')
    Assert-Equal $r.Text ("`e[4mabcdef`e[24m") 'text'
}
It 'render: CJK cursor column counts width 2' {
    $r = (New-Renderer).Render('', '中文ab', 2, @(), '')
    Assert-Equal $r.CursorColumn 5 'col'
}
It 'render: CJK inside underline span' {
    $r = (New-Renderer).Render('', 'a中文b', 4, @(New-U 1 3), '')
    Assert-Equal $r.Text ("a`e[4m中文`e[24mb") 'text'
}
It 'render: adjacent same-style regions merge into one span' {
    $regions = @((New-U 1 3), (New-U 3 5))
    $r = (New-Renderer).Render('', 'abcdef', 0, $regions, '')
    Assert-Equal $r.Text ("a`e[4mbcde`e[24mf") 'text'   # regions 1..3 and 3..5 → one span 1..5
}
It 'render: two separate spans' {
    $regions = @((New-U 1 2), (New-U 4 5))
    $r = (New-Renderer).Render('', 'abcdef', 0, $regions, '')
    Assert-Equal $r.Text ("a`e[4mb`e[24mcd`e[4me`e[24mf") 'text'
}
It 'render: null regions tolerated' {
    $r = (New-Renderer).Render('', 'ab', 2, $null, '')
    Assert-Equal $r.Text 'ab' 'text'
    Assert-Equal $r.CursorColumn 3 'col'
}
It 'render: cursor in middle of CJK buffer' {
    $r = (New-Renderer).Render('> ', '中a文b', 3, @(), '')
    Assert-Equal $r.CursorColumn 8 'col'   # prompt 2 + width('中a文')=5 + 1
}
It 'render: ANSI prompt measured by visible width' {
    $r = (New-Renderer).Render("`e[32mPS> `e[0m", 'abc', 3, @(), '')
    Assert-Equal $r.Text ("`e[32mPS> `e[0mabc") 'text'
    Assert-Equal $r.CursorColumn 8 'col'   # 'PS> ' = 4 visible cells + 3 + 1
}
It 'render: suggestion remainder drawn dim' {
    $r = (New-Renderer).Render('', 'ab', 2, @(), 'abcdef')
    Assert-Equal $r.Text ("ab`e[2mcdef`e[22m") 'text'
    Assert-Equal $r.CursorColumn 3 'col'
}
It 'render: suggestion not drawn when it equals the buffer' {
    $r = (New-Renderer).Render('', 'ab', 2, @(), 'ab')
    Assert-Equal $r.Text 'ab' 'text'
}
It 'render: suggestion not drawn when it does not start with the buffer' {
    $r = (New-Renderer).Render('', 'ab', 2, @(), 'zzzz')
    Assert-Equal $r.Text 'ab' 'text'
}
It 'render: suggestion after underlined span closes then dims' {
    $r = (New-Renderer).Render('', 'abcd', 4, @(New-U 0 2), 'abcdef')
    Assert-Equal $r.Text ("`e[4mab`e[24mcd`e[2mef`e[22m") 'text'
}
