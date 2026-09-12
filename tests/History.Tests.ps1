# History tests: navigation, dedupe, persistence.

It 'history: add skips empty and consecutive duplicates' {
    $h = [HuLineHistory]::new()
    $h.Add('dir'); $h.Add('dir'); $h.Add(''); $h.Add('cd x')
    Assert-Equal $h.Items.Count 2 'count'
    Assert-Equal $h.Items[0] 'dir' 'first'
    Assert-Equal $h.Items[1] 'cd x' 'second'
}
It 'history: Previous walks older, Next walks newer back to fresh' {
    $h = [HuLineHistory]::new()
    $h.Add('a'); $h.Add('b'); $h.Add('c')
    Assert-Equal ($h.Previous()) 'c' 'prev1'
    Assert-Equal ($h.Previous()) 'b' 'prev2'
    Assert-Equal ($h.Previous()) 'a' 'prev3'
    Assert-Equal ($h.Previous()) 'a' 'prev-at-oldest-stays'
    Assert-Equal ($h.Next()) 'b' 'next1'
    Assert-Equal ($h.Next()) 'c' 'next2'
    Assert-Equal ($h.Next()) '' 'next-to-fresh'
    Assert-Equal ($h.Next()) '' 'next-beyond-fresh'
}
It 'history: Add resets navigation position' {
    $h = [HuLineHistory]::new()
    $h.Add('a'); $h.Add('b')
    $null = $h.Previous()          # position now at 0
    $h.Add('c')                    # must reset to fresh
    Assert-Equal ($h.Previous()) 'c' 'prev-after-add'
}
It 'history: empty history' {
    $h = [HuLineHistory]::new()
    Assert-Equal ($h.Previous()) $null 'prev-null'
    Assert-Equal ($h.Next()) '' 'next-empty'
}
It 'history: save/load roundtrip' {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('hu-hist-' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        $h = [HuLineHistory]::new()
        $h.Add('Get-ChildItem'); $h.Add('cd C:\Windows')
        $h.Save($path)
        $h2 = [HuLineHistory]::new()
        $h2.Load($path)
        Assert-Equal $h2.Items.Count 2 'count'
        Assert-Equal $h2.Items[1] 'cd C:\Windows' 'last'
        Assert-Equal ($h2.Previous()) 'cd C:\Windows' 'nav-after-load'
    } finally {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}
It 'history: load missing file is a no-op' {
    $h = [HuLineHistory]::new()
    $h.Load('C:\definitely\missing\file.txt')
    Assert-Equal $h.Items.Count 0 'count'
}
It 'history: Search returns most recent prefix match' {
    $h = [HuLineHistory]::new()
    $h.Add('Get-ChildItem'); $h.Add('cd C:\Windows'); $h.Add('Get-Date')
    Assert-Equal ($h.Search('Get-')) 'Get-Date' 'most-recent'
    Assert-Equal ($h.Search('cd')) 'cd C:\Windows' 'cd'
    Assert-Equal ($h.Search('nope')) $null 'none'
}
It 'history: Search is case-insensitive; empty prefix yields no suggestion' {
    $h = [HuLineHistory]::new()
    $h.Add('Get-ChildItem'); $h.Add('git status')
    Assert-Equal ($h.Search('GIT')) 'git status' 'case'
    Assert-Equal ($h.Search('')) $null 'empty-prefix'
    Assert-Equal ([HuLineHistory]::new().Search('g')) $null 'empty-history'
}
It 'history: SearchAll most-recent-first with prefix filter' {
    $h = [HuLineHistory]::new()
    $h.Add('Get-ChildItem C:\Windows'); $h.Add('git status'); $h.Add('Get-Date'); $h.Add('git log')
    Assert-Equal (($h.SearchAll('git')) -join '|') 'git log|git status' 'git'
    Assert-Equal (($h.SearchAll('GET-')) -join '|') 'Get-Date|Get-ChildItem C:\Windows' 'case'
    Assert-Equal (($h.SearchAll('nope')) -join '|') '' 'none'
    Assert-Equal (($h.SearchAll('')) -join '|') 'git log|Get-Date|git status|Get-ChildItem C:\Windows' 'all'
    Assert-Equal (([HuLineHistory]::new().SearchAll('x')) -join '|') '' 'empty-history'
}
