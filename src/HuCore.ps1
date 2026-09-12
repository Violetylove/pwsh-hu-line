#Requires -Version 7.0
# HuCore.ps1 — core value types for hu-line rendering. No dependencies.

# A set of visual attributes applied to a span of the input buffer.
class HuStyle {
    [bool]$Underline = $false
    [bool]$Bold = $false
    [string]$Foreground = ''   # '' | black..white | bright-* | decimal 256-color id

    HuStyle() {}
    HuStyle([bool]$underline, [bool]$bold, [string]$foreground) {
        $this.Underline = $underline
        $this.Bold = $bold
        $this.Foreground = $foreground
    }

    # NOTE: class-typed parameters are deliberately UNTYPED throughout this
    # module. A PowerShell class type identity is bound per module load, so when
    # a session holds two copies of this module (two paths, a reload, a
    # script-scope import) a value created by one copy cannot convert into the
    # same-named type of the other. The runtime errors are:
    #   "Cannot convert the HuLineBuffer value of type HuLineBuffer to type HuLineBuffer"
    #   "Cannot find an overload for Add and the argument count: 1"
    # Untyped parameters bind by duck typing and cannot hit that. Regression
    # driver: tests/e2e-identity.ps1.
    static [bool] IsEmpty($s) {
        return (-not $s.Underline) -and (-not $s.Bold) -and ($s.Foreground -eq '')
    }

    static [bool] Same($a, $b) {
        return ($a.Underline -eq $b.Underline) -and ($a.Bold -eq $b.Bold) -and ($a.Foreground -eq $b.Foreground)
    }

    static [object] Merge($a, $b) {
        $fg = if ($a.Foreground) { $a.Foreground } elseif ($b.Foreground) { $b.Foreground } else { '' }
        return [HuStyle]::new(($a.Underline -or $b.Underline), ($a.Bold -or $b.Bold), $fg)
    }

    # SGR parameter list to turn these attributes ON, e.g. "1;4;38;5;34".
    hidden [string] ToSgrOn() {
        $parts = [System.Collections.Generic.List[string]]::new()
        if ($this.Bold) { [void]$parts.Add('1') }
        if ($this.Underline) { [void]$parts.Add('4') }
        if ($this.Foreground) {
            $c = [HuStyle]::ColorToSgr($this.Foreground)
            if ($c) { [void]$parts.Add($c) }
        }
        return ($parts -join ';')
    }

    # SGR parameter list to turn OFF only these attributes (targeted reset,
    # so unrelated active attributes in the terminal are preserved).
    hidden [string] ToSgrOff() {
        $parts = [System.Collections.Generic.List[string]]::new()
        if ($this.Bold) { [void]$parts.Add('22') }
        if ($this.Underline) { [void]$parts.Add('24') }
        if ($this.Foreground) { [void]$parts.Add('39') }
        return ($parts -join ';')
    }

    static [string] ColorToSgr([string]$name) {
        $basic = @{ black = '0'; red = '1'; green = '2'; yellow = '3'; blue = '4'; magenta = '5'; cyan = '6'; white = '7' }
        $m = [regex]::Match($name, '^bright-(.+)$')
        if ($m.Success -and $basic.ContainsKey($m.Groups[1].Value)) { return ('9' + $basic[$m.Groups[1].Value]) }
        if ($basic.ContainsKey($name)) { return ('3' + $basic[$name]) }
        if ([regex]::IsMatch($name, '^\d+$')) { return ('38;5;' + $name) }
        return ''
    }
}

# A styled span of the input buffer. [Start, End) — UTF-16 char offsets.
class HuRegion {
    [int]$Start
    [int]$End
    $Style          # untyped: see the note in HuStyle

    HuRegion([int]$start, [int]$end, $style) {
        $this.Start = $start
        $this.End = $end
        $this.Style = $style
    }

    [string] ToString() {
        $kind = if ($this.Style.Underline) { 'underline' } else { 'plain' }
        return ('{0}..{1} {2}' -f $this.Start, $this.End, $kind)
    }
}

# Terminal cell width (wcwidth approximation, CJK/emoji-aware).
class HuWidth {
    static [int] OfRune([int]$cp) {
        if ($cp -lt 0x20) { return 0 }          # C0 controls (never in buffer)
        if ($cp -eq 0x7F) { return 0 }          # DEL
        # zero-width combining marks
        if (($cp -ge 0x0300 -and $cp -le 0x036F) -or
            ($cp -ge 0x1AB0 -and $cp -le 0x1AFF) -or
            ($cp -ge 0x1DC0 -and $cp -le 0x1DFF) -or
            ($cp -ge 0x20D0 -and $cp -le 0x20FF) -or
            ($cp -ge 0xFE20 -and $cp -le 0xFE2F)) { return 0 }
        # East Asian Wide / Fullwidth (approximation of Unicode EastAsianWidth)
        if (($cp -ge 0x1100 -and $cp -le 0x115F) -or   # Hangul Jamo
            ($cp -ge 0x2E80 -and $cp -le 0x303E) -or   # CJK radicals, punctuation
            ($cp -ge 0x3041 -and $cp -le 0x33FF) -or   # kana, CJK symbols
            ($cp -ge 0x3400 -and $cp -le 0x4DBF) -or   # CJK Ext A
            ($cp -ge 0x4E00 -and $cp -le 0x9FFF) -or   # CJK unified
            ($cp -ge 0xA000 -and $cp -le 0xA4CF) -or   # Yi
            ($cp -ge 0xAC00 -and $cp -le 0xD7A3) -or   # Hangul syllables
            ($cp -ge 0xF900 -and $cp -le 0xFAFF) -or   # CJK compat ideographs
            ($cp -ge 0xFE30 -and $cp -le 0xFE4F) -or   # CJK compat forms
            ($cp -ge 0xFF00 -and $cp -le 0xFF60) -or   # fullwidth forms
            ($cp -ge 0xFFE0 -and $cp -le 0xFFE6) -or   # fullwidth signs
            ($cp -ge 0x1F300 -and $cp -le 0x1F64F) -or # emoji
            ($cp -ge 0x1F900 -and $cp -le 0x1F9FF) -or
            ($cp -ge 0x20000 -and $cp -le 0x3FFFD)) { return 2 }  # CJK Ext B+
        return 1
    }

    static [int] Of([string]$text) {
        $w = 0
        $i = 0
        $len = $text.Length
        while ($i -lt $len) {
            $cp = 0
            if ([char]::IsHighSurrogate($text[$i]) -and ($i + 1) -lt $len -and [char]::IsLowSurrogate($text[$i + 1])) {
                $cp = [char]::ConvertToUtf32($text[$i], $text[$i + 1])
                $i += 2
            } else {
                $cp = [int]$text[$i]
                $i += 1
            }
            $w += [HuWidth]::OfRune($cp)
        }
        return $w
    }

    # Visible width of text that may contain ANSI escapes (prompts from the
    # `prompt` function, e.g. starship). Strips CSI (ESC[ ... final byte),
    # OSC (ESC] ... BEL|ESC\), and DECSC/DECRC (ESC 7 / ESC 8); the escapes
    # themselves are zero-width, the rest is measured normally.
    static [int] OfAnsi([string]$text) {
        $sb = [System.Text.StringBuilder]::new()
        $i = 0
        $len = $text.Length
        while ($i -lt $len) {
            if ($text[$i] -eq [char]27) {
                if ($i + 1 -lt $len -and $text[$i + 1] -eq '[') {          # CSI
                    $i += 2
                    while ($i -lt $len -and -not ([char]::IsLetter($text[$i]) -or ($text[$i] -ge '@' -and $text[$i] -le '~'))) { $i++ }
                    if ($i -lt $len) { $i++ }
                    continue
                }
                if ($i + 1 -lt $len -and $text[$i + 1] -eq ']') {          # OSC (hyperlink etc.)
                    $i += 2
                    while ($i -lt $len) {
                        if ($text[$i] -eq [char]7) { $i++; break }          # BEL
                        if ($text[$i] -eq [char]27 -and $i + 1 -lt $len -and $text[$i + 1] -eq '\') { $i += 2; break }  # ST
                        $i++
                    }
                    continue
                }
                if ($i + 1 -lt $len -and ($text[$i + 1] -eq '7' -or $text[$i + 1] -eq '8')) { $i += 2; continue }  # DECSC/DECRC
                $i++
                continue
            }
            [void]$sb.Append($text[$i])
            $i++
        }
        return [HuWidth]::Of($sb.ToString())
    }

    # Number of terminal rows a text occupies (newline-aware). Used to place
    # the input line below a possibly multi-line prompt.
    static [int] LineCount([string]$text) {
        if ([string]::IsNullOrEmpty($text)) { return 1 }
        $n = 1
        for ($i = 0; $i -lt $text.Length; $i++) {
            if ($text[$i] -eq "`n") { $n++ }
            elseif ($text[$i] -eq "`r") {
                if ($i + 1 -lt $text.Length -and $text[$i + 1] -eq "`n") { $i++ }
                $n++
            }
        }
        return $n
    }

    # The part of the text after the last newline — what a redraw writes on the
    # input line (the prompt's earlier lines are drawn once and left alone).
    static [string] LineTail([string]$text) {
        $idx = $text.LastIndexOfAny([char[]]@("`r", "`n"))
        if ($idx -lt 0) { return $text }
        return $text.Substring($idx + 1)
    }
}

# 中文 Windows 的控制台输出码页是 GB2312/CP936，编不出的字符（starship 的 ❯、Nerd Font
# 私用区字形、emoji）会被 [Console]::Out 静默写成 '?'。宿主层（Write-Host/$Host.UI.Write）
# 走 UTF-16 无损，但本编辑器要绝对定位光标、只能走 [Console]::Out，所以自己把码页临时切到
# UTF-8；行结束后还原，命令仍在原码页下运行（否则本机中文工具吐的 GBK 会变乱码）。
class HuConsoleEncoding {
    # 切到 UTF-8（Windows 上同时调 SetConsoleOutputCP，终端才按 UTF-8 解码），返回旧编码供还原。
    static [System.Text.Encoding] BeginUtf8() {
        try {
            $previous = [Console]::OutputEncoding
            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
            return $previous
        } catch {
            return $null
        }
    }

    static [void] End([System.Text.Encoding]$previous) {
        if ($null -eq $previous) { return }
        try { [Console]::OutputEncoding = $previous } catch { }
    }

    # True when $Text survives a round-trip through the CURRENT console output
    # encoding. False documents the '?' substitution above (used by tests).
    static [bool] RoundTrips([string]$text) {
        try {
            $e = [Console]::OutputEncoding
            return ($e.GetString($e.GetBytes($text)) -eq $text)
        } catch {
            return $false
        }
    }
}

# Rows math for the editor's on-screen layout. The editor draws with ABSOLUTE
# rows (ESC[<row>;1H) and keeps its own bookkeeping, but a terminal has no rows
# below the last one: writing there SCROLLS the screen, which silently shifts
# everything that bookkeeping refers to. That is the reported "input line on the
# last row → the completion menu flickers and never appears": the menu is drawn
# below the input row, so the editor must scroll itself some room first and then
# shift its row numbers by exactly the same amount.
#
# Pure functions on purpose — the arithmetic is unit-tested (tests/Layout.Tests.ps1)
# while the scrolling itself can only be judged on a real console.
class HuLayout {
    # Rows that exist BELOW the input row (0-based) in a $windowHeight-row window.
    static [int] RowsBelow([int]$inputRow, [int]$windowHeight) {
        if ($windowHeight -le 0) { return 0 }
        $n = $windowHeight - 1 - $inputRow
        if ($n -lt 0) { return 0 }
        return $n
    }

    # How many rows must be scrolled up so that $need rows fit below the input row.
    static [int] Deficit([int]$inputRow, [int]$windowHeight, [int]$need) {
        $d = $need - [HuLayout]::RowsBelow($inputRow, $windowHeight)
        if ($d -lt 0) { return 0 }
        return $d
    }

    # How many rows to scroll up just to bring the input row itself back on screen.
    static [int] Offscreen([int]$inputRow, [int]$windowHeight) {
        if ($windowHeight -le 0) { return 0 }
        $d = $inputRow - ($windowHeight - 1)
        if ($d -lt 0) { return 0 }
        return $d
    }

    # Row budget for the menu: never more than the window can ever show (after
    # scrolling as far up as possible), and never more than the caller wants.
    static [int] MaxRows([int]$windowHeight, [int]$want) {
        if ($windowHeight -le 1) { return 1 }
        if ($want -lt ($windowHeight - 1)) { return $want }
        return $windowHeight - 1
    }

    # Visual rows a piece of text occupies in a $width-cell terminal. This is
    # wrap-aware, unlike [HuWidth]::LineCount which only counts '\n': as soon as a
    # prompt line or the input line is wider than the terminal it wraps, and a
    # wrapped line breaks absolute row addressing exactly like the last-row case
    # (the erase covers one visual row, the rest stays behind, rows drift).
    static [int] TextRows([string]$text, [int]$width) {
        if ([string]::IsNullOrEmpty($text)) { return 1 }
        if ($width -le 0) { return [HuWidth]::LineCount($text) }
        $rows = 0
        foreach ($line in [regex]::Split($text, "`r`n|`n|`r")) {
            $cells = [HuWidth]::OfAnsi($line)
            $n = [Math]::Ceiling($cells / [double]$width)
            if ($n -lt 1) { $n = 1 }
            $rows += [int]$n
        }
        if ($rows -lt 1) { return 1 }
        return $rows
    }

    # Where the cursor sits inside the input area: @{ Row = 0-based row offset from
    # the input area's first line; Col = 1-based column for ESC[<col>G }.
    # $promptCells = display width of the input area's first line (the prompt tail),
    # $lineCells = display width of the buffer text BEFORE the cursor.
    static [System.Collections.Hashtable] CursorPos([int]$promptCells, [int]$lineCells, [int]$width) {
        $pos = $promptCells + $lineCells
        if ($pos -lt 0) { $pos = 0 }
        if ($width -le 0) { return @{ Row = 0; Col = $pos + 1 } }
        $row = [int][Math]::Floor($pos / [double]$width)
        $col = ($pos - ($row * $width)) + 1
        # an exact multiple means the terminal is holding a pending wrap: the cursor
        # is still painted on the LAST cell of that row, not the first of the next.
        if ($pos -gt 0 -and ($pos % $width) -eq 0) { $row = $row - 1; $col = $width }
        return @{ Row = $row; Col = $col }
    }
}

# Launch-mode classifier. A $PROFILE-wired REPL runs for EVERY pwsh start, and a
# `-File`/`-Command` launch keeps a REAL console on stdin — so the "stdin is
# redirected" check in Enter-HuLineRepl cannot catch it, and the REPL would take
# over: the script's first line never runs, the process just parks at the prompt.
# Pure, so the classification is unit-tested here; the real-console proof is in
# tests/e2e-console.ps1.
class HuLaunch {
    # Switches that mean "pwsh was started to run something", not to sit at a prompt.
    static [string[]] ScriptFlags() {
        return @('-File', '-Command', '-c', '-EncodedCommand', '-e', '-ec', '-NonInteractive')
    }

    # The flags actually present in a command line (empty = interactive start).
    # -contains is case-insensitive, matching how pwsh parses its own switches.
    static [object] ScriptedFlags([string[]]$commandLine) {
        $hits = [System.Collections.Generic.List[string]]::new()
        if ($null -eq $commandLine) { return $hits.ToArray() }
        $known = [HuLaunch]::ScriptFlags()
        foreach ($a in $commandLine) {
            if ($null -ne $a -and $known -contains $a) { [void]$hits.Add($a) }
        }
        return $hits.ToArray()
    }
}
