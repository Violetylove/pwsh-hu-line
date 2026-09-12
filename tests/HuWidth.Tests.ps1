# Width tests: CJK/emoji-aware terminal cell width.

It 'width: ASCII' { Assert-Equal ([HuWidth]::Of('abc')) 3 'ascii' }
It 'width: CJK' { Assert-Equal ([HuWidth]::Of('中文')) 4 'cjk' }
It 'width: mixed' { Assert-Equal ([HuWidth]::Of('a中b')) 4 'mixed' }
It 'width: combining mark is zero' { Assert-Equal ([HuWidth]::OfRune(0x0301)) 0 'combining' }
It 'width: emoji surrogate pair is 2' { Assert-Equal ([HuWidth]::Of('😀')) 2 'emoji' }
It 'width: empty string' { Assert-Equal ([HuWidth]::Of('')) 0 'empty' }
It 'width: fullwidth digits' { Assert-Equal ([HuWidth]::Of('１２３')) 6 'fullwidth' }
It 'width-ansi: SGR stripped, content measured' {
    Assert-Equal ([HuWidth]::OfAnsi("`e[32mabc`e[0m")) 3 'sgr'
}
It 'width-ansi: OSC hyperlink stripped' {
    Assert-Equal ([HuWidth]::OfAnsi("`e]8;;http://x`e\abc`e]8;;`e\")) 3 'osc'
}
It 'width-ansi: mixed SGR + CJK' {
    Assert-Equal ([HuWidth]::OfAnsi("`e[1mPS 中文`e[0m ")) 8 'mixed'
}
It 'width-ansi: no escapes = plain width' {
    Assert-Equal ([HuWidth]::OfAnsi('abc中文')) 7 'plain'
}
It 'width-ansi: empty' {
    Assert-Equal ([HuWidth]::OfAnsi('')) 0 'empty'
}
It 'line-count: single line' {
    Assert-Equal ([HuWidth]::LineCount('')) 1 'empty'
    Assert-Equal ([HuWidth]::LineCount('abc')) 1 'plain'
}
It 'line-count: multi-line prompt' {
    Assert-Equal ([HuWidth]::LineCount("PS`n> ")) 2 'lf'
    Assert-Equal ([HuWidth]::LineCount("PS`r`n> ")) 2 'crlf'
    Assert-Equal ([HuWidth]::LineCount("PS`n")) 2 'trailing-lf'
}
It 'line-tail: last line after final newline' {
    Assert-Equal ([HuWidth]::LineTail('abc')) 'abc' 'no-newline'
    Assert-Equal ([HuWidth]::LineTail("PS`n> ")) '> ' 'lf'
    Assert-Equal ([HuWidth]::LineTail("PS`r`n> ")) '> ' 'crlf'
    Assert-Equal ([HuWidth]::LineTail("x`n")) '' 'trailing-lf'
}
