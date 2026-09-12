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
