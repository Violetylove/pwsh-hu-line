# Highlighter tests: which spans get underlined, mirroring zsh-syntax-highlighting
# `path` / `path_prefix` semantics, with the deviations noted in the source comments.

$testLoc = Join-Path ([System.IO.Path]::GetTempPath()) ('hu-line-' + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($testLoc) | Out-Null

function New-Hl { param([string]$loc = $testLoc) [HuPathHighlighter]::new($loc) }
function Get-Spans {
    param([string]$text, $hl)
    @($hl.GetRegions($text) | ForEach-Object { "$($_.Start)..$($_.End)" })
}

$sysRoot = $env:SystemRoot

try {
    It 'hl: existing dir arg is underlined' {
        $text = 'Get-ChildItem ' + $sysRoot
        Assert-Equal ((Get-Spans $text (New-Hl)) -join ',') ('14..' + (14 + $sysRoot.Length)) 'spans'
    }
    It 'hl: missing path in the middle is not underlined' {
        # non-trailing position → no AST match, and prefix rule only looks at
        # the last word ('more' is not path-like) → no spans.
        Assert-Equal ((Get-Spans 'Get-ChildItem C:\NoSuchThing_HuLine123 more' (New-Hl)) -join ',') '' 'spans'
    }
    It 'hl: trailing token with existing parent but NO matching entry is not underlined' {
        # zsh-faithful: the parent exists but nothing starts with the fragment.
        $tok = $sysRoot + '\WinHuLineNoExist'
        Assert-Equal ((Get-Spans ('cd ' + $tok) (New-Hl)) -join ',') '' 'spans'
    }
    It 'hl: bareword fragment prefix IS underlined (single component)' {
        [System.IO.Directory]::CreateDirectory((Join-Path $testLoc 'WinPrefix')) | Out-Null
        Assert-Equal ((Get-Spans 'cd WinPre' (New-Hl)) -join ',') '3..9' 'spans'
    }
    It 'hl: deep partial path prefix underlined via glob' {
        $tok = $sysRoot + '\System32\driv'
        Assert-Equal ((Get-Spans ('cd ' + $tok) (New-Hl)) -join ',') ('3..' + (3 + $tok.Length)) 'spans'
    }
    It 'hl: after --% a matching prefix is not underlined' {
        Assert-Equal ((Get-Spans 'cmd /c echo --% C:\Wi' (New-Hl)) -join ',') '' 'spans'
    }
    It 'hl: trailing token inside a comment is not underlined' {
        $expectArg = '3..' + (3 + $sysRoot.Length)
        Assert-Equal ((Get-Spans ('cd ' + $sysRoot + ' # foo') (New-Hl)) -join ',') $expectArg 'spans'
    }
    It 'hl: command name alone is not underlined' {
        Assert-Equal ((Get-Spans 'Get-ChildItem' (New-Hl)) -join ',') '' 'spans'
    }
    It 'hl: command-position relative path is underlined' {
        [System.IO.File]::WriteAllText((Join-Path $testLoc 'probe.ps1'), '')
        Assert-Equal ((Get-Spans './probe.ps1' (New-Hl)) -join ',') '0..11' 'spans'
    }
    It 'hl: parameter name skipped, value underlined' {
        $text = 'Get-ChildItem -Path ' + $sysRoot
        Assert-Equal ((Get-Spans $text (New-Hl)) -join ',') ('20..' + (20 + $sysRoot.Length)) 'spans'
    }
    It 'hl: tilde expands to home' {
        Assert-Equal ((Get-Spans 'Get-ChildItem ~' (New-Hl)) -join ',') '14..15' 'spans'
    }
    It 'hl: bare trailing word is not underlined' {
        Assert-Equal ((Get-Spans 'git sta' (New-Hl)) -join ',') '' 'spans'
    }
    It 'hl: token with variable expansion skipped' {
        Assert-Equal ((Get-Spans 'Get-ChildItem $env:WINDIR\foo' (New-Hl)) -join ',') '' 'spans'
    }
    It 'hl: quoted path underlined (extent includes quotes)' {
        $q = "'" + $sysRoot + "'"
        Assert-Equal ((Get-Spans ('Get-ChildItem ' + $q) (New-Hl)) -join ',') ('14..' + (14 + $q.Length)) 'spans'
    }
    It 'hl: wildcard token skipped' {
        Assert-Equal ((Get-Spans 'Get-ChildItem C:\Windows\*.dll' (New-Hl)) -join ',') '' 'spans'
    }
    It 'hl: after --% nothing is underlined' {
        Assert-Equal ((Get-Spans 'cmd /c echo --% C:\Windows' (New-Hl)) -join ',') '' 'spans'
    }
    It 'hl: redirection target underlined when it exists' {
        [System.IO.File]::WriteAllText((Join-Path $testLoc 'out.txt'), '')
        $prefix = 'Get-ChildItem ' + $sysRoot + ' > '
        $expectArg = '14..' + (14 + $sysRoot.Length)
        $expectRedir = $prefix.Length.ToString() + '..' + ($prefix.Length + 7)
        Assert-Equal ((Get-Spans ($prefix + 'out.txt') (New-Hl $testLoc)) -join ',') ($expectArg + ',' + $expectRedir) 'spans'
    }
    It 'hl: trailing whitespace suppresses prefix region' {
        Assert-Equal ((Get-Spans ('cd ' + $sysRoot + ' ') (New-Hl)) -join ',') ('3..' + (3 + $sysRoot.Length)) 'spans'
    }
    It 'hl: no duplicate region when token exists' {
        Assert-Equal ((Get-Spans ('cd ' + $sysRoot) (New-Hl)) -join ',') ('3..' + (3 + $sysRoot.Length)) 'spans'
    }
    It 'hl: relative path resolved against location' {
        [System.IO.Directory]::CreateDirectory((Join-Path $testLoc 'subdir')) | Out-Null
        Assert-Equal ((Get-Spans 'Get-ChildItem subdir' (New-Hl)) -join ',') '14..20' 'spans'
    }
    It 'hl: empty text' {
        Assert-Equal ((Get-Spans '' (New-Hl)) -join ',') '' 'spans'
    }
    It 'hl: no location, relative token unchecked' {
        Assert-Equal ((Get-Spans 'Get-ChildItem subdir' ([HuPathHighlighter]::new(''))) -join ',') '' 'spans'
    }
} finally {
    if (Test-Path $testLoc) { [System.IO.Directory]::Delete($testLoc, $true) }
}
