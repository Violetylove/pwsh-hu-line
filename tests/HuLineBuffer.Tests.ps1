# LineBuffer tests: plain-text buffer + cursor semantics.

It 'buffer: insert appends' {
    $b = [HuLineBuffer]::new(); $b.Insert('abc')
    Assert-Equal $b.Text 'abc' 'text'; Assert-Equal $b.Cursor 3 'cursor'
}
It 'buffer: insert at middle' {
    $b = [HuLineBuffer]::new(); $b.Insert('abcd'); $b.Cursor = 2; $b.Insert('XY')
    Assert-Equal $b.Text 'abXYcd' 'text'; Assert-Equal $b.Cursor 4 'cursor'
}
It 'buffer: backspace removes before cursor' {
    $b = [HuLineBuffer]::new(); $b.Insert('abc'); $b.Backspace()
    Assert-Equal $b.Text 'ab' 'text'; Assert-Equal $b.Cursor 2 'cursor'
}
It 'buffer: backspace at start is a no-op' {
    $b = [HuLineBuffer]::new(); $b.Backspace()
    Assert-Equal $b.Text '' 'text'; Assert-Equal $b.Cursor 0 'cursor'
}
It 'buffer: delete removes at cursor' {
    $b = [HuLineBuffer]::new(); $b.Insert('abcd'); $b.Cursor = 1; $b.Delete()
    Assert-Equal $b.Text 'acd' 'text'; Assert-Equal $b.Cursor 1 'cursor'
}
It 'buffer: move/home/end' {
    $b = [HuLineBuffer]::new(); $b.Insert('abcd')
    $b.Home(); Assert-Equal $b.Cursor 0 'home'
    $b.MoveRight(); Assert-Equal $b.Cursor 1 'right'
    $b.MoveLeft(); Assert-Equal $b.Cursor 0 'left'
    $b.End(); Assert-Equal $b.Cursor 4 'end'
}
