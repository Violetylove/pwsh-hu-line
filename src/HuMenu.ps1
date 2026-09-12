#Requires -Version 7.0
# HuMenu.ps1 — Tab completion menu for the line editor. Depends on HuCore.ps1,
# HuLine.ps1 (HuLineBuffer). No module-function calls.

# Wraps a CommandCompletion result for the menu (avoids coupling the editor to
# PS CompletionResult shapes in rendering/tests).
class HuCompletion {
    [string]$Text
    [string]$ListItem
    [string]$ToolTip
    [string]$ResultType

    HuCompletion() {}
    HuCompletion([System.Management.Automation.CompletionResult]$r) {
        if ($null -eq $r) { return }
        $this.Text = $r.CompletionText
        $this.ListItem = $r.ListItemText
        $this.ToolTip = $r.ToolTip
        $this.ResultType = [string]$r.ResultType
    }
    HuCompletion([string]$text, [string]$listItem, [string]$resultType, [string]$toolTip) {
        $this.Text = $text
        $this.ListItem = $listItem
        $this.ToolTip = $toolTip
        $this.ResultType = $resultType
    }
}

# Applies a completion to the buffer, replacing [replaceIndex, replaceIndex+len)
# with the completion text. Returns the new cursor position (end of insertion).
class HuCompletionApplier {
    # $buffer / $item untyped on purpose — see the note in HuCore.ps1 (class
    # type identity differs per module load, and the conversion error it causes
    # is "Cannot convert the X value of type X to type X").
    static [int] Apply($buffer, $item, [int]$replaceIndex, [int]$replaceLen) {
        $text = $buffer.Text
        if ($replaceIndex -lt 0) { $replaceIndex = 0 }
        if ($replaceIndex -gt $text.Length) { $replaceIndex = $text.Length }
        if ($replaceIndex + $replaceLen -gt $text.Length) { $replaceLen = $text.Length - $replaceIndex }
        if ($replaceLen -lt 0) { $replaceLen = 0 }
        $newText = $text.Substring(0, $replaceIndex) + $item.Text + $text.Substring($replaceIndex + $replaceLen)
        $buffer.SetText($newText)
        return $replaceIndex + $item.Text.Length
    }
}

# Multi-line completion menu drawable below the input line. Uses absolute row
# addressing (ESC[<row>;1H), erases only what it drew (Clear), and keeps the
# selected row inside a scrolling window. The input line is left untouched —
# the caller redraws it separately.
class HuMenuRenderer {
    [int]$RowsUsed = 0
    [int]$WindowStart = 0
    [string]$Separator = '  '
    # Terminal width in cells; rows are truncated to it (0 = no truncation). The
    # editor sets the real width when it has a console; 80 is the safe default.
    [int]$Width = 80
    # High-water mark of rows currently on screen since the last Clear. A later,
    # SHORTER draw must also erase the tail of the previous one — otherwise stale
    # menu rows stay visible (reported as "backspaced until nothing matched; the
    # first rows were cleared but the rows below remained on screen").
    [int]$RowsDrawn = 0

    [int] ComputeRows([int]$maxRows, [int]$itemCount) {
        if ($itemCount -le 0 -or $maxRows -le 0) { return 0 }
        return [Math]::Min($itemCount, $maxRows)
    }

    [int] UpdateWindow([int]$selected, [int]$maxRows, [int]$itemCount) {
        $rows = $this.ComputeRows($maxRows, $itemCount)
        if ($rows -eq 0) { $this.WindowStart = 0; return 0 }
        if ($selected -lt $this.WindowStart) { $this.WindowStart = $selected }
        elseif ($selected -ge $this.WindowStart + $rows) { $this.WindowStart = $selected - $rows + 1 }
        if ($this.WindowStart -gt $itemCount - $rows) { $this.WindowStart = $itemCount - $rows }
        if ($this.WindowStart -lt 0) { $this.WindowStart = 0 }
        return $this.WindowStart
    }

    # 一行菜单必须严格等于一个终端行：PowerShell 的 tooltip 是多行的（Get-Alias 四行），
    # 原样塞进去会折行/换行，落在 Clear() 擦除范围外的部分就留在屏幕上。

    hidden [string] OneLine([string]$s) {
        return [regex]::Replace([string]$s, '[\r\n\t]+', ' ')
    }

    # Cuts $s to at most $cells display cells (CJK/emoji aware) and marks the cut.
    static [string] Truncate([string]$s, [int]$cells) {
        if ($cells -le 1 -or [HuWidth]::Of($s) -le $cells) { return $s }
        $sb = [System.Text.StringBuilder]::new()
        $w = 0
        $i = 0
        while ($i -lt $s.Length) {
            $cp = [int]$s[$i]
            $size = 1
            if ([char]::IsHighSurrogate($s[$i]) -and ($i + 1) -lt $s.Length -and [char]::IsLowSurrogate($s[$i + 1])) {
                $cp = [char]::ConvertToUtf32($s[$i], $s[$i + 1])
                $size = 2
            }
            $cw = [HuWidth]::OfRune($cp)
            if (($w + $cw) -gt ($cells - 1)) { break }
            [void]$sb.Append($s.Substring($i, $size))
            $w += $cw
            $i += $size
        }
        return $sb.ToString() + [char]0x2026     # …
    }

    # Escape sequence drawing the (scrolled) menu below startRow0 (0-based).
    [string] Draw([int]$startRow0, [int]$maxRows, $items, [int]$selected) {
        if ($null -eq $items) { return '' }
        $rows = $this.ComputeRows($maxRows, $items.Count)
        $this.UpdateWindow($selected, $maxRows, $items.Count) | Out-Null
        $sb = [System.Text.StringBuilder]::new()
        for ($k = 0; $k -lt $rows; $k++) {
            $i = $this.WindowStart + $k
            $item = $items[$i]
            $row = $startRow0 + $k
            $text = $this.OneLine($item.ListItem)
            $tip = ''
            if ($item.ToolTip -and $item.ToolTip -ne $item.ListItem) { $tip = $this.OneLine($item.ToolTip) }
            if ($this.Width -gt 0) {
                $text = [HuMenuRenderer]::Truncate($text, $this.Width)
                $rest = $this.Width - [HuWidth]::Of($text) - [HuWidth]::Of($this.Separator)
                $tip = if ($rest -gt 1) { [HuMenuRenderer]::Truncate($tip, $rest) } else { '' }
            }
            [void]$sb.Append("`e[$($row + 1);1H")
            [void]$sb.Append("`e[2K")
            if ($i -eq $selected) { [void]$sb.Append("`e[7m") }
            [void]$sb.Append($text)
            if ($tip) { [void]$sb.Append("`e[2m" + $this.Separator + $tip + "`e[22m") }
            if ($i -eq $selected) { [void]$sb.Append("`e[27m") }
        }
        # erase the tail of a previous, longer draw
        for ($k = $rows; $k -lt $this.RowsDrawn; $k++) {
            [void]$sb.Append("`e[$($startRow0 + $k + 1);1H")
            [void]$sb.Append("`e[2K")
        }
        if ($rows -gt $this.RowsDrawn) { $this.RowsDrawn = $rows }
        $this.RowsUsed = $rows
        return $sb.ToString()
    }

    [string] Clear([int]$startRow0) {
        $sb = [System.Text.StringBuilder]::new()
        # Erase the HIGH-WATER mark, not just the last draw: the menu may have been
        # drawn taller earlier, and those rows are still on screen.
        $rows = [Math]::Max($this.RowsUsed, $this.RowsDrawn)
        for ($r = 0; $r -lt $rows; $r++) {
            [void]$sb.Append("`e[$($startRow0 + $r + 1);1H")
            [void]$sb.Append("`e[2K")
        }
        $this.RowsUsed = 0
        $this.RowsDrawn = 0
        return $sb.ToString()
    }
}