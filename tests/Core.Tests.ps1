# Core.Tests.ps1 — src/HuCore.ps1：宽度、布局算术、控制台编码。

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

# HuLayout — the rows arithmetic behind "the editor must make room for itself".
# Reported bug: with the input line on the LAST row of the terminal, the
# completion menu (drawn below it) has no rows to live in, so the terminal scrolls
# under our absolute row addressing → the menu flickers and never appears.
# The scrolling itself needs a real console; this arithmetic is what decides
# whether and by how much to scroll, and it is unit-tested here.

It 'layout: RowsBelow counts the rows under the input row' {
    Assert-Equal ([HuLayout]::RowsBelow(0, 24)) 23 'top row'
    Assert-Equal ([HuLayout]::RowsBelow(23, 24)) 0 'last row → nothing below'
    Assert-Equal ([HuLayout]::RowsBelow(30, 24)) 0 'past the window → clamp at 0'
    Assert-Equal ([HuLayout]::RowsBelow(5, 0)) 0 'unknown window → 0'
}

It 'layout: Deficit is how much to scroll for the menu to fit' {
    Assert-Equal ([HuLayout]::Deficit(0, 24, 6)) 0 'plenty of room → no scroll'
    Assert-Equal ([HuLayout]::Deficit(20, 24, 6)) 3 'only 3 rows below → scroll 3'
    Assert-Equal ([HuLayout]::Deficit(23, 24, 6)) 6 'last row → scroll the full need'
}

It 'layout: Offscreen brings the input row itself back into view' {
    Assert-Equal ([HuLayout]::Offscreen(10, 24)) 0 'already visible'
    Assert-Equal ([HuLayout]::Offscreen(23, 24)) 0 'last row is visible'
    Assert-Equal ([HuLayout]::Offscreen(24, 24)) 1 'one row past the end'
    Assert-Equal ([HuLayout]::Offscreen(30, 24)) 7 'far past the end'
}

It 'layout: MaxRows never exceeds the window' {
    Assert-Equal ([HuLayout]::MaxRows(24, 6)) 6 'window roomier than the want'
    Assert-Equal ([HuLayout]::MaxRows(4, 6)) 3 'window caps the want'
    Assert-Equal ([HuLayout]::MaxRows(1, 6)) 1 'degenerate window still yields one row'
}

It 'layout: TextRows counts wrapped rows, not only newlines' {
    Assert-Equal ([HuLayout]::TextRows('', 80)) 1 'empty → one row'
    Assert-Equal ([HuLayout]::TextRows('abc', 80)) 1 'fits'
    Assert-Equal ([HuLayout]::TextRows(('x' * 80), 80)) 1 'exactly one row'
    Assert-Equal ([HuLayout]::TextRows(('x' * 81), 80)) 2 'one cell over → wraps'
    Assert-Equal ([HuLayout]::TextRows("a`nb", 80)) 2 'newline'
    Assert-Equal ([HuLayout]::TextRows((('x' * 80) + "`n" + ('x' * 80)), 80)) 2 'two full rows'
    Assert-Equal ([HuLayout]::TextRows("`e[32mabc`e[39m", 80)) 1 'ANSI is zero width'
    Assert-Equal ([HuLayout]::TextRows('中中中', 4)) 2 'CJK cells count'
    Assert-Equal ([HuLayout]::TextRows(('x' * 81), 0)) 1 'unknown width → newline count only'
}

It 'layout: CursorPos maps a text position onto row/column' {
    $p = [HuLayout]::CursorPos(2, 0, 80)
    Assert-Equal $p.Row 0 'start of the line'
    Assert-Equal $p.Col 3 'just after the prompt'
    $p = [HuLayout]::CursorPos(2, 5, 80)
    Assert-Equal $p.Col 8 'five cells into the buffer'
    $p = [HuLayout]::CursorPos(2, 78, 80)
    Assert-Equal $p.Row 0 'exactly full: wrap is pending, still on this row'
    Assert-Equal $p.Col 80 'on the last cell'
    $p = [HuLayout]::CursorPos(2, 79, 80)
    Assert-Equal $p.Row 1 'one over → second visual row'
    Assert-Equal $p.Col 2 'second cell of it'
    $p = [HuLayout]::CursorPos(0, 5, 0)
    Assert-Equal $p.Row 0 'unknown width → single row'
    Assert-Equal $p.Col 6 'plain column'
}

# HuConsoleEncoding — the console output code page on this machine is GB2312
# (CP936), which cannot represent prompt glyphs such as starship's ❯ (U+276F);
# .NET silently writes '?' for them. These tests pin the guard that makes the
# editor's write path lossless. The real-console proof (screen buffer readback)
# lives in tests/e2e-console.ps1.

function Get-ConsoleEncodingOrNull {
    try { return [Console]::OutputEncoding } catch { return $null }
}

It 'HuConsoleEncoding.BeginUtf8 switches [Console]::Out to a lossless encoder' {
    if ($null -eq (Get-ConsoleEncodingOrNull)) { return }   # no console attached: not applicable
    $snapshot = [HuConsoleEncoding]::BeginUtf8()
    try {
        Assert-Equal ([Console]::OutputEncoding.WebName) 'utf-8' 'console output encoding'
        Assert-True ([Console]::Out.Encoding.WebName -eq 'utf-8') 'Console.Out encoder is utf-8'
        Assert-True ([HuConsoleEncoding]::RoundTrips([string][char]0x276F)) '❯ survives a round-trip'
        $bytes = [Console]::Out.Encoding.GetBytes([string][char]0x276F)
        Assert-Equal $bytes.Length 3 '❯ is three UTF-8 bytes'
        Assert-Equal $bytes[0] 0xE2 '❯ encodes as E2 9D AF'
    } finally {
        [HuConsoleEncoding]::End($snapshot)
    }
}

It 'HuConsoleEncoding.End restores the original code page' {
    if ($null -eq (Get-ConsoleEncodingOrNull)) { return }
    $before = [Console]::OutputEncoding.CodePage
    $snapshot = [HuConsoleEncoding]::BeginUtf8()
    [HuConsoleEncoding]::End($snapshot)
    Assert-Equal ([Console]::OutputEncoding.CodePage) $before 'code page restored'
}

It 'documented degradation: a non-UTF-8 code page turns ❯ into ?' {
    if ($null -eq (Get-ConsoleEncodingOrNull)) { return }
    if ([Console]::OutputEncoding.CodePage -eq 65001) { return }   # already UTF-8: nothing to degrade
    Assert-True (-not [HuConsoleEncoding]::RoundTrips([string][char]0x276F)) 'non-UTF-8 page cannot encode ❯'
    $bytes = [Console]::Out.Encoding.GetBytes([string][char]0x276F)
    Assert-Equal $bytes.Length 1 'degraded to a single byte'
    Assert-Equal $bytes[0] 0x3F "'❯' degrades to '?' (0x3F) — this is the reported bug"
}

It 'HuConsoleEncoding.End tolerates a null snapshot (no console)' {
    [HuConsoleEncoding]::End($null)     # must not throw
    Assert-True $true 'null snapshot is a no-op'
}
