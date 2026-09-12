#Requires -Version 7.0
# pwsh-hu-line.psm1 — 模块入口：Read-HuLine（行编辑器）、Enter-HuLineRepl（REPL 宿主）、
# Get-HuRegions（调试导出）。

$srcDir = Join-Path $PSScriptRoot 'src'
. (Join-Path $srcDir 'HuCore.ps1')
. (Join-Path $srcDir 'HuHistory.ps1')
. (Join-Path $srcDir 'HuLine.ps1')
. (Join-Path $srcDir 'HuMenu.ps1')
. (Join-Path $srcDir 'HuCommand.ps1')   # 命令着色
. (Join-Path $srcDir 'HuLog.ps1')       # 最后：它的 Identity() 要给上面的类取指纹

# 本份代码的"修订指纹"：Enter-HuLineRepl 接管前与磁盘比对——源文件在加载后被改过，
# 就说明本进程跑的是旧类，必须重开 pwsh（带类的模块不能热重载）。
$script:HuSourceStamp = @{}
foreach ($huFile in @($PSCommandPath) + @(Get-ChildItem -LiteralPath $srcDir -Filter '*.ps1' | ForEach-Object { $_.FullName })) {
    try { $script:HuSourceStamp[$huFile] = (Get-Item -LiteralPath $huFile).LastWriteTimeUtc.Ticks } catch { }
}

[HuLog]::Init('')
[HuLog]::Write('info', 'load', "pwsh=$($PSVersionTable.PSVersion) pid=$PID module=$PSCommandPath")
[HuLog]::Write('info', 'ident', [HuLog]::Identity())
[HuLog]::Write('info', 'env', [HuLog]::Environment())

# 把"类对象过时"这种非逻辑错误换成人话：进程里若混有旧修订的 [HuCompletionApplier]，
# 它的类型化 Apply() 会以 "Cannot convert ... to type ..." 拒绝我们的 buffer。
function Invoke-HuCompletionApply {
    [CmdletBinding()]
    param($Buffer, $Item, [int]$ReplaceIndex, [int]$ReplaceLength)
    try {
        [void][HuCompletionApplier]::Apply($Buffer, $Item, $ReplaceIndex, $ReplaceLength)
    } catch {
        # Record the one fact that settles "which class object won": the runtime
        # handle of the buffer's type vs the handle of the parameter that the
        # resolved Apply() declares. Equal handles + a failure = something else;
        # different handles = two revisions of this module alive in this process.
        try {
            $paramType = [HuCompletionApplier].GetMethod('Apply').GetParameters()[0].ParameterType
            [HuLog]::Write('error', 'apply', ('buffer={0} applyBufferParam={1} identical={2} bufferText=[{3}]' -f
                [HuLog]::HandleOf($Buffer.GetType()),
                [HuLog]::HandleOf($paramType),
                ($paramType.TypeHandle.Value -eq $Buffer.GetType().TypeHandle.Value),
                $Buffer.Text))
        } catch { }
        [HuLog]::Error('apply', 'completion apply failed', $_)
        throw ("$($_.Exception.Message)`n提示：若上述错误是 class 转换（HuLineBuffer → HuLineBuffer），" +
               '说明本 pwsh 进程里混有旧版本模块的类对象（热重载 pwsh-hu-line 所致），不是仓库代码的问题。' +
               "请完全退出 pwsh 重开，再运行 demo.ps1。诊断日志：$([HuLog]::Path)")
    }
}

<#
.SYNOPSIS
    Reads one line from the terminal with zsh-style live path underlining.
.DESCRIPTION
    A minimal raw-mode line editor: plain-text buffer, region-list renderer
    (SGR underline), and a synchronous per-keystroke path highlighter based on
    the real PowerShell parser. Returns $null when the user cancels with Ctrl+C.
    With -History, Up/Down arrows navigate session history and fish-style inline
    suggestions (dim, accepted with →/Ctrl+F) are shown. Falls back to plain
    [Console]::ReadLine() when stdin is redirected.
.PARAMETER Prompt
    Plain text shown before the input area. ANSI escapes in the prompt are not
    measured correctly yet (v1 limitation).
.PARAMETER History
    Optional history object (module-internal [HuLineHistory]); enables Up/Down
    navigation. Untyped on purpose: module classes are not resolvable in the
    parameter types of exported functions (PowerShell quirk).
.EXAMPLE
    Read-HuLine -Prompt 'PS> '
#>
function Read-HuLine {
    [CmdletBinding()]
    param(
        [string]$Prompt = '',
        $History = $null,
        # Internal test hook: a scriptblock returning ConsoleKeyInfo. When
        # provided, the editor reads keys from it instead of the console, and
        # the stdin-redirected fallback is skipped (enables deterministic
        # end-to-end tests of the key loop).
        $KeySource = $null,
        # Test hook: TextWriter capturing the rendered screen output (menu rows,
        # redraws) so tests can assert on menu open/refresh/hide.
        $OutWriter = $null,
        # Test hooks (headless): pretend the terminal is this many columns/rows so
        # the wrap-aware and scroll-aware layout can be driven and asserted without
        # a console. 0 = ask the console; with no console 0 means "unknown", which
        # degrades the layout to newline-only counting and skips all scrolling.
        [int]$TermCols = 0,
        [int]$TermRows = 0
    )
    $readKey = { [Console]::ReadKey($true) }
    if ($null -ne $KeySource) { $readKey = $KeySource }
    if ([Console]::IsInputRedirected -and $null -eq $KeySource) {
        return [Console]::ReadLine()
    }

    # Test hook (KeySource): the editor never touches the real console — output
    # goes to a StringWriter and ALL console field access (even reads, which
    # throw "invalid handle" without a console) is skipped.
    $interactiveConsole = ($null -eq $KeySource)
    $oldTreatCtrlC = $false
    $oldVisible = $false
    $oldOutEncoding = $null
    $oldOut = [Console]::Out
    if ($interactiveConsole) {
        $oldTreatCtrlC = [Console]::TreatControlCAsInput
        $oldVisible = [Console]::CursorVisible
    }
    try {
        if (-not $interactiveConsole) {
            if ($null -eq $OutWriter) { $OutWriter = [System.IO.StringWriter]::new() }
            [Console]::SetOut($OutWriter)
        }
        if ($interactiveConsole) {
            [Console]::TreatControlCAsInput = $true
            [Console]::CursorVisible = $false
            # Prompt glyphs (starship's ❯ U+276F, Powerline/Nerd-Font PUA glyphs,
            # emoji) do not exist in the console's code page on a Chinese Windows
            # (GB2312/CP936) and .NET would draw them as '?'. [Console]::Out is
            # the only writer here, so make that path lossless for this edit loop
            # and restore it before the line is handed back to the caller.
            $oldOutEncoding = [HuConsoleEncoding]::BeginUtf8()
        }

        $buffer = [HuLineBuffer]::new()
        $loc = Get-Location -ErrorAction SilentlyContinue
        $fsPath = ''
        if ($loc -and $loc.Provider.Name -eq 'FileSystem') { $fsPath = $loc.ProviderPath }
        $highlighter = [HuPathHighlighter]::new($fsPath)
        # Command-name colouring. The session-dependent half is this resolver:
        # "what IS this name here?" Command discovery is cached for the whole
        # session ($script: scope) — re-asking per keystroke would re-scan PATH.
        if ($null -eq $script:HuCommandCache) { $script:HuCommandCache = @{} }
        $commandResolver = {
            param($name)
            try {
                $ci = $ExecutionContext.SessionState.InvokeCommand.GetCommand(
                    $name, [System.Management.Automation.CommandTypes]::All)
                if ($null -eq $ci) { return 'unknown' }
                $t = [string]$ci.CommandType
                if ($t -eq 'Alias') { return 'alias' }
                if ($t -eq 'Application' -or $t -eq 'ExternalScript') { return 'application' }
                return 'command'      # Cmdlet / Function / Filter / Configuration
            } catch { return 'unknown' }
        }
        $cmdHighlighter = [HuCommandHighlighter]::new($commandResolver, $script:HuCommandCache)
        $renderer = [HuRegionRenderer]::new()

        # Terminal size: the console's own when there is one, the test hooks
        # otherwise. 0 = unknown → newline-only layout and no scrolling.
        $termWidth = 0
        $termHeight = 0
        if ($interactiveConsole) {
            try { $termWidth = [Console]::WindowWidth } catch { $termWidth = 0 }
            try { $termHeight = [Console]::WindowHeight } catch { $termHeight = 0 }
        }
        if ($TermCols -gt 0) { $termWidth = $TermCols }
        if ($TermRows -gt 0) { $termHeight = $TermRows }

        # 提示符只整块画一次，之后每次重绘只碰"输入区"（提示符最后一行起），所以打字不会把
        # 提示符一行行往下推；折行也算视觉行。行号账本放 hashtable（scriptblock 改不了外层
        # 局部变量），因为下面的 $ensureRoom 要挪这些数字。
        $layout = @{ StartRow = 0; InputRow = 0; LineRows = 1; WindowHeight = $termHeight }
        if ($interactiveConsole) { $layout.StartRow = [Console]::CursorTop }
        $promptRows = [HuLayout]::TextRows($Prompt, $termWidth)
        $layout.InputRow = $layout.StartRow + $promptRows - 1
        $promptTail = [HuWidth]::LineTail($Prompt)
        $promptCells = [HuWidth]::OfAnsi($promptTail)

        # 终端没有"最后一行之下"：往屏外写会滚动屏幕，让绝对行号整体错位（表现为输入行每键
        # 都闪、补全菜单一闪即隐）。所以先腾行：光标停到末行、发 N 个换行让整屏上滚，再把
        # 账本里的行号同步减 N。
        $ensureRoom = {
            param([int]$need)
            if ($layout.WindowHeight -le 0) { return }      # unknown window: nothing to compute
            $scroll = [Math]::Max(
                [HuLayout]::Offscreen($layout.InputRow, $layout.WindowHeight),
                [HuLayout]::Deficit($layout.InputRow, $layout.WindowHeight, $need))
            if ($scroll -le 0) { return }
            if (($layout.InputRow - $scroll) -lt 0) { $scroll = $layout.InputRow }
            if ($scroll -le 0) { return }
            [Console]::Out.Write("`e[$($layout.WindowHeight);1H" + ("`n" * $scroll))
            [Console]::Out.Flush()
            $layout.InputRow = $layout.InputRow - $scroll
            $layout.StartRow = [Math]::Max(0, $layout.StartRow - $scroll)
        }

        & $ensureRoom ($layout.LineRows - 1)   # the input area itself must be on screen
        if ($interactiveConsole) {
            [Console]::Out.Write("`e[$($layout.StartRow + 1);1H" + $Prompt)
            [Console]::Out.Flush()
        }

        # Repaint state shared with $drawMenu: a cache that ONLY $redraw writes, so
        # the menu can put the cursor back where the (possibly wrapped) line wants it.
        $renderState = @{ Text = ''; CursorColumn = 1; CursorRow = 0 }

        $redraw = {
            $suggestion = ''
            if ($null -ne $History) {
                $suggestion = $History.Search($buffer.Text)
                if ($null -eq $suggestion) { $suggestion = '' }
            }
            # Two highlighters, one region list: the renderer splits on every
            # boundary and merges the styles covering a run, so the path underline
            # and the command colour compose without either knowing about the other.
            $regions = @($highlighter.GetRegions($buffer.Text)) + @($cmdHighlighter.GetRegions($buffer.Text))
            $r = $renderer.Render($promptTail, $buffer.Text, $buffer.Cursor, $regions, $suggestion)
            $renderState.Text = $r.Text
            # How many VISUAL rows the input area needs (the line may wrap), where the
            # cursor goes inside it, and make sure those rows exist before using them.
            # Erase by HIGH-WATER mark: a line that shrinks back from two rows to one
            # would otherwise leave its second row behind (same family as the menu's
            # stale rows). $layout.LineRows still holds the previous count here.
            $rows = [HuLayout]::TextRows($promptTail + $r.Text, $termWidth)
            $eraseRows = [Math]::Max($rows, $layout.LineRows)
            $layout.LineRows = $rows
            & $ensureRoom ($eraseRows - 1)
            $pos = [HuLayout]::CursorPos($promptCells, [HuWidth]::Of($buffer.Text.Substring(0, $buffer.Cursor)), $termWidth)
            $renderState.CursorRow = $pos.Row
            $renderState.CursorColumn = $pos.Col
            # Erase every visual row we own, rewrite the text (it wraps by itself),
            # then park the cursor at the mapped position.
            $out = [System.Text.StringBuilder]::new()
            for ($i = 0; $i -lt $eraseRows; $i++) {
                [void]$out.Append("`e[$($layout.InputRow + $i + 1);1H`e[2K")
            }
            [void]$out.Append("`e[$($layout.InputRow + 1);1H")
            [void]$out.Append($renderState.Text)
            [void]$out.Append("`e[$($layout.InputRow + $renderState.CursorRow + 1);$($renderState.CursorColumn)H")
            [Console]::Out.Write($out.ToString())
            [Console]::Out.Flush()
        }
        & $redraw

        $submit = $false
        # ↑-walk state machine: 'none' | 'plain' (empty-buffer walk) | 'prefix'
        # (anchored prefix search). A plain walk must keep walking older entries
        # on repeated ↑ — switching to prefix-search after the first entry was
        # the "only previous command reachable" bug.
        $upMode = 'none'
        $upSearchPrefix = ''
        $upSearchMatches = @()
        $upSearchIdx = 0
        $upSearchOriginal = ''
        # Menu + render state live in hashtables: `& scriptblock` helpers CANNOT
        # assign enclosing function locals, but hashtable member writes
        # propagate. This is what keeps hideMenu/openMenu stateful.
        $menuState = @{ Items = $null; Selected = 0; ReplaceIndex = 0; ReplaceLen = 0; StartRow = 0 }
        $menuRenderer = [HuMenuRenderer]::new()
        # A menu row must never wrap: the part that wraps lands outside the rows
        # Clear() erases and survives on screen (see HuMenuRenderer.Draw). Give the
        # renderer the real terminal width; the 80-cell default covers tests and
        # any case where the width cannot be read.
        if ($termWidth -gt 0) { $menuRenderer.Width = [Math]::Max(20, $termWidth - 1) }
        $menuMaxRows = 6
        if ($layout.WindowHeight -gt 0) { $menuMaxRows = [HuLayout]::MaxRows($layout.WindowHeight, $menuMaxRows) }

        # NOTE: $redraw is defined ONCE, above. It used to be defined twice — the
        # first copy won the initial paint and the second won every later redraw,
        # which is a fine way to make "what is on screen" depend on history.
        $drawMenu = {
            if ($null -eq $menuState.Items -or $menuState.Items.Count -eq 0) { return }
            # The menu lives BELOW the input area (which may itself wrap over several
            # rows): make sure those rows exist first, or the terminal scrolls under
            # our absolute rows and the menu flickers without ever appearing.
            & $ensureRoom ($layout.LineRows - 1 + $menuMaxRows)
            $menuState.StartRow = $layout.InputRow + $layout.LineRows
            [Console]::Out.Write($menuRenderer.Draw($menuState.StartRow, $menuMaxRows, $menuState.Items, $menuState.Selected))
            # Put the cursor back where the (possibly wrapped) line wants it: the menu
            # draw moved it. The input row itself needs no repaint — nothing has
            # changed the buffer since the last $redraw.
            [Console]::Out.Write("`e[$($layout.InputRow + $renderState.CursorRow + 1);$($renderState.CursorColumn)H")
            [Console]::Out.Flush()
        }
        $hideMenu = {
            if ($null -ne $menuState.Items) {
                [Console]::Out.Write($menuRenderer.Clear($menuState.StartRow))
                $menuState.Items = $null
                [Console]::Out.Flush()
            }
        }
        $getCompletions = {
            $comp = $null
            try {
                $comp = [System.Management.Automation.CommandCompletion]::CompleteInput($buffer.Text, $buffer.Cursor, $null)
            } catch { $comp = $null }
            if ($null -eq $comp -or $null -eq $comp.CompletionMatches -or $comp.CompletionMatches.Count -eq 0) { return $null }
            $items = [System.Collections.Generic.List[HuCompletion]]::new()
            foreach ($m in $comp.CompletionMatches) { $items.Add([HuCompletion]::new($m)) }
            return @{ Items = $items; ReplaceIndex = $comp.ReplacementIndex; ReplaceLen = $comp.ReplacementLength }
        }
        $acceptMenu = {
            if ($null -eq $menuState.Items -or $menuState.Items.Count -eq 0) { return }
            # Capture the selection BEFORE hiding: hideMenu nulls Items.
            $item = $menuState.Items[$menuState.Selected]
            $ri = $menuState.ReplaceIndex
            $rl = $menuState.ReplaceLen
            & $hideMenu
            Invoke-HuCompletionApply -Buffer $buffer -Item $item -ReplaceIndex $ri -ReplaceLength $rl
            & $redraw
        }
        $cancelMenu = { & $hideMenu; & $redraw }
        # Recompute completions for the current buffer and refresh the open menu;
        # hide it when nothing matches anymore. Live-updates on edit: characters
        # narrow it, backspace widens it. This is only safe because
        # HuMenuRenderer erases by HIGH-WATER mark — a shrinking menu used to leave
        # the rows below it on screen (see tests/Menu.Tests.ps1).
        $refreshMenu = {
            if ($null -eq $menuState.Items) { return }
            $c = & $getCompletions
            if ($null -eq $c) {
                & $hideMenu
                & $redraw
            } else {
                $menuState.Items = $c.Items
                $menuState.Selected = [Math]::Min($menuState.Selected, $menuState.Items.Count - 1)
                if ($menuState.Selected -lt 0) { $menuState.Selected = 0 }
                $menuState.ReplaceIndex = $c.ReplaceIndex
                $menuState.ReplaceLen = $c.ReplaceLen
                # Repaint the line FIRST (the edit must be visible), then the menu:
                # $drawMenu no longer repaints the input row itself.
                & $redraw
                & $drawMenu
            }
        }
        while (-not $submit) {
            $ki = & $readKey
            if ($null -eq $ki) { continue }
            $k = $ki.Key
            $ch = $ki.KeyChar

            if ($ch -eq [char]3) {              # Ctrl+C → cancel the line
                & $hideMenu
                [Console]::Out.Write("`n")
                return $null
            }
            if ($ch -eq "`r" -or $ch -eq "`n") {
                if ($null -ne $menuState.Items) {
                    # Enter on an open menu accepts the selection AND submits
                    # (PSReadLine / fish behaviour: one keystroke runs it).
                    & $acceptMenu
                    $submit = $true
                    continue
                }
                $submit = $true; continue
            }
            if ($null -ne $menuState.Items) {
                # Menu navigation mode: Tab / Shift+Tab / Up / Down / Esc.
                if ($k -eq [ConsoleKey]::Tab) {
                    if ($ch -eq [char]0 -or ($ki.Modifiers -band [ConsoleModifiers]::Shift) -ne 0) {
                        $menuState.Selected--; if ($menuState.Selected -lt 0) { $menuState.Selected = $menuState.Items.Count - 1 }
                    } else {
                        $menuState.Selected++; if ($menuState.Selected -ge $menuState.Items.Count) { $menuState.Selected = 0 }
                    }
                    & $drawMenu; continue
                } elseif ($k -eq [ConsoleKey]::UpArrow) {
                    $menuState.Selected--; if ($menuState.Selected -lt 0) { $menuState.Selected = 0 }
                    & $drawMenu; continue
                } elseif ($k -eq [ConsoleKey]::DownArrow) {
                    $menuState.Selected++; if ($menuState.Selected -ge $menuState.Items.Count) { $menuState.Selected = $menuState.Items.Count - 1 }
                    & $drawMenu; continue
                } elseif ($k -eq [ConsoleKey]::Escape) {
                    & $cancelMenu; continue
                } elseif ($k -eq [ConsoleKey]::Backspace -or $k -eq [ConsoleKey]::Delete) {
                    if ($k -eq [ConsoleKey]::Backspace) { $buffer.Backspace() } else { $buffer.Delete() }
                    $upMode = 'none'
                    & $refreshMenu
                    continue
                } elseif ($ch -ne [char]0) {
                    $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
                    if ($cat -eq [System.Globalization.UnicodeCategory]::Control -or
                        $cat -eq [System.Globalization.UnicodeCategory]::Format) { & $hideMenu; continue }
                    $insert = $ch.ToString()
                    if ([char]::IsHighSurrogate($ch)) {
                        $k2 = & $readKey
                        if ($null -ne $k2 -and [char]::IsLowSurrogate($k2.KeyChar)) { $insert = "$ch$($k2.KeyChar)" }
                    }
                    $buffer.Insert($insert)
                    $upMode = 'none'
                    & $refreshMenu
                    continue
                } else {
                    & $hideMenu
                    # fall through to normal key handling below
                }
            }
            if ($k -eq [ConsoleKey]::Backspace) { $buffer.Backspace(); $upMode = 'none' }
            elseif ($k -eq [ConsoleKey]::Delete) { $buffer.Delete(); $upMode = 'none' }
            elseif ($k -eq [ConsoleKey]::LeftArrow) { $buffer.MoveLeft() }
            elseif ($k -eq [ConsoleKey]::RightArrow) {
                # fish-style: accept the suggestion when the cursor is at the end
                $sug = if ($null -ne $History) { $History.Search($buffer.Text) } else { $null }
                if ($sug -and $buffer.Cursor -eq $buffer.Text.Length -and $sug.Length -gt $buffer.Text.Length) {
                    $buffer.SetText($sug); $upMode = 'none'
                } else { $buffer.MoveRight() }
            }
            elseif ($k -eq [ConsoleKey]::Home) { $buffer.Home() }
            elseif ($k -eq [ConsoleKey]::End) { $buffer.End() }
            elseif ($k -eq [ConsoleKey]::Tab) {
                # Tab with no menu yet → single completion or open the menu
                $c = & $getCompletions
                if ($null -eq $c) { & $redraw }
                elseif ($c.Items.Count -eq 1) {
                    Invoke-HuCompletionApply -Buffer $buffer -Item $c.Items[0] -ReplaceIndex $c.ReplaceIndex -ReplaceLength $c.ReplaceLen
                    & $redraw
                } else {
                    $menuState.Items = $c.Items
                    $menuState.Selected = 0
                    $menuState.ReplaceIndex = $c.ReplaceIndex
                    $menuState.ReplaceLen = $c.ReplaceLen
                    & $drawMenu
                }
            }
            elseif ($k -eq [ConsoleKey]::UpArrow) {
                if ($null -ne $History) {
                    if ($upMode -eq 'none') {
                        if ($buffer.Text -eq '') {
                            # empty buffer → plain walk
                            $upMode = 'plain'
                            $t = $History.Previous()
                            if ($null -ne $t) { $buffer.SetText($t) }
                        } else {
                            # non-empty buffer → ANCHORED prefix search
                            # (zsh history-beginning-search / fish ↑)
                            $upSearchPrefix = $buffer.Text
                            $upSearchOriginal = $buffer.Text
                            $upSearchMatches = @($History.SearchAll($upSearchPrefix))
                            if ($upSearchMatches.Count -gt 0) {
                                $upMode = 'prefix'
                                $upSearchIdx = 0
                                $buffer.SetText($upSearchMatches[0])
                            }
                        }
                    } elseif ($upMode -eq 'plain') {
                        # keep walking older entries
                        $t = $History.Previous()
                        if ($null -ne $t) { $buffer.SetText($t) }
                    } else {
                        # continue to an older prefix match
                        $upSearchIdx++
                        if ($upSearchIdx -lt $upSearchMatches.Count) { $buffer.SetText($upSearchMatches[$upSearchIdx]) }
                    }
                }
            }
            elseif ($k -eq [ConsoleKey]::DownArrow) {
                if ($null -ne $History) {
                    if ($upMode -eq 'prefix') {
                        if ($upSearchIdx -gt 0) {
                            $upSearchIdx--
                            $buffer.SetText($upSearchMatches[$upSearchIdx])
                        } else {
                            $buffer.SetText($upSearchOriginal)
                            $upMode = 'none'
                        }
                    } else {
                        $t = $History.Next()
                        if ($t -eq '') { $upMode = 'none' }
                        $buffer.SetText($t)
                    }
                }
            }
            elseif ($ch -eq [char]12) {         # Ctrl+L → clear screen, redraw prompt + line
                [Console]::Out.Write("`e[2J`e[H")
                $layout.StartRow = 0
                $layout.InputRow = [HuWidth]::LineCount($Prompt) - 1
                [Console]::Out.Write($Prompt)
                [Console]::Out.Flush()
                & $redraw
                if ($null -ne $menuState.Items) { & $drawMenu }
            }
            elseif ($ch -eq [char]6) {          # Ctrl+F → accept suggestion
                $sug = if ($null -ne $History) { $History.Search($buffer.Text) } else { $null }
                if ($sug -and $sug.Length -gt $buffer.Text.Length) { $buffer.SetText($sug); $upMode = 'none' }
            }
            elseif ($ch -eq [char]18) {         # Ctrl+R → incremental history search
                if ($null -ne $History) {
                    $searchPattern = ''
                    $searchMatches = @($History.SearchAll(''))
                    $searchIdx = 0
                    $searchMode = $true
                    while ($searchMode) {
                        $match = ''
                        if ($searchMatches.Count -gt 0 -and $searchIdx -lt $searchMatches.Count) { $match = $searchMatches[$searchIdx] }
                        $line = "(reverse-i-search)`e[7m$searchPattern`e[27m`: "
                        if ($match) { $line += $match }
                        [Console]::Out.Write("`e[$($layout.InputRow + 1);1H`e[2K" + $promptTail + $line)
                        [Console]::Out.Write("`e[$([HuWidth]::OfAnsi($promptTail) + [HuWidth]::OfAnsi($line) + 1)G")
                        [Console]::Out.Flush()

                        $k2 = [Console]::ReadKey($true)
                        $ch2 = $k2.KeyChar
                        $k2k = $k2.Key
                        if ($ch2 -eq "`r" -or $ch2 -eq "`n") {
                            if ($match) { $buffer.SetText($match) }
                            $searchMode = $false
                        } elseif ($ch2 -eq [char]3 -or $k2k -eq [ConsoleKey]::Escape) {
                            $searchMode = $false                    # cancel, keep buffer
                        } elseif ($k2k -eq [ConsoleKey]::Backspace) {
                            if ($searchPattern.Length -gt 0) {
                                $searchPattern = $searchPattern.Substring(0, $searchPattern.Length - 1)
                                $searchMatches = @($History.SearchAll($searchPattern))
                                $searchIdx = 0
                            }
                        } elseif ($ch2 -eq [char]18) {              # Ctrl+R again → older match
                            if ($searchMatches.Count -gt 0) { $searchIdx = ($searchIdx + 1) % $searchMatches.Count }
                        } elseif ($ch2 -ne [char]0) {
                            $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch2)
                            if ($cat -ne [System.Globalization.UnicodeCategory]::Control -and
                                $cat -ne [System.Globalization.UnicodeCategory]::Format) {
                                $searchPattern += $ch2
                                $searchMatches = @($History.SearchAll($searchPattern))
                                $searchIdx = 0
                            }
                        }
                    }
                    $upMode = 'none'
                }
            }
            elseif ($k -eq [ConsoleKey]::Escape) { continue }
            elseif ($ch -ne [char]0) {
                $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
                if ($cat -eq [System.Globalization.UnicodeCategory]::Control -or
                    $cat -eq [System.Globalization.UnicodeCategory]::Format) { continue }
                $insert = $ch.ToString()
                if ([char]::IsHighSurrogate($ch)) {   # recombine surrogate pairs (emoji)
                    $k2 = [Console]::ReadKey($true)
                    if ([char]::IsLowSurrogate($k2.KeyChar)) { $insert = "$ch$($k2.KeyChar)" }
                }
                $buffer.Insert($insert)
                $upMode = 'none'
            }
            else { continue }
            & $redraw
        }
        [Console]::Out.Write("`n")
        return $buffer.Text
    }
    finally {
        if (-not $interactiveConsole) { [Console]::SetOut($oldOut) }
        if ($interactiveConsole) {
            [Console]::CursorVisible = $oldVisible
            [Console]::TreatControlCAsInput = $oldTreatCtrlC
            # Restore before returning the line: the command that runs next must
            # see the console's original code page (native tools on this machine
            # emit GBK, which CP65001 would render as mojibake).
            [HuConsoleEncoding]::End($oldOutEncoding)
        }
    }
}

<#
.SYNOPSIS
    Takes over the interactive input loop: prompt → hu-line editor → execute.
.DESCRIPTION
    The "pwsh 启动即接管" host. Runs a REPL loop using Read-HuLine (path
    underlining + history). Command semantics:
      exit / quit → end the whole pwsh session
      stock / native → leave the REPL; pwsh falls back to its stock PSReadLine
                       prompt (REPL is started from $PROFILE, so this returns
                       control to the normal interactive loop)
    Ctrl+C cancels the current line and reprompts. History persists to
    -HistoryPath (default ~\.hu-line_history).
.PARAMETER HistoryPath
    History file; loaded at start, saved on exit. '' disables persistence.
.EXAMPLE
    Enter-HuLineRepl
#>
function Enter-HuLineRepl {
    [CmdletBinding()]
    param(
        [string]$HistoryPath = (Join-Path $HOME '.hu-line_history')
    )
    # --- stale-process guards (see the class-identity trap in AGENTS.md) --------
    # A pwsh process cannot hot-reload a class-carrying module safely. Run all
    # three checks up front, write the facts to the log, and explain — instead of
    # letting the first Tab press die with "Cannot convert the HuLineBuffer value
    # of type HuLineBuffer to type HuLineBuffer".
    $copies = @(Get-Module | Where-Object { $_.Name -like 'pwsh-hu-line*' })
    $staleFiles = @($script:HuSourceStamp.Keys | Where-Object {
        try { (Get-Item -LiteralPath $_).LastWriteTimeUtc.Ticks -ne $script:HuSourceStamp[$_] } catch { $false }
    })
    $selfTest = 'ok'
    try {
        [void][HuCompletionApplier]::Apply([HuLineBuffer]::new(), [HuCompletion]::new('', '', '', ''), 0, 0)
    } catch {
        $selfTest = $_.Exception.Message
    }
    # Smoke-test the WHOLE per-keystroke pipeline on cold type literals, not just
    # the completion call: a process that hot-reloaded this module can hold class
    # objects from the old revision and then EVERY keystroke throws (the highlighter
    # cannot Add its region into the other revision's list) — which the user sees
    # as "the input line flickers on every character and Tab does nothing".
    $smoke = [System.Collections.Generic.List[string]]::new()
    try {
        $hlProbe = [HuPathHighlighter]::new('')
        $regProbe = $hlProbe.GetRegions('Get-ChildItem C:\Windows')
        $null = [HuRegionRenderer]::new().Render('PS> ', 'abc', 1, $regProbe, '')
        [void]$smoke.Add(('highlight+render=ok regions={0}' -f @($regProbe).Count))
    } catch {
        [void]$smoke.Add("highlight+render=$($_.Exception.Message)")
        $selfTest = $_.Exception.Message
    }
    [HuLog]::Write('info', 'guard', ("copies={0} staleFiles={1} selfTest={2} smoke=[{3}]" -f
        $copies.Count, $staleFiles.Count, $selfTest, ($smoke -join ' ; ')))
    [HuLog]::Write('info', 'ident', [HuLog]::Identity())

    if ($copies.Count -gt 1) {
        Write-Warning ("本进程加载了 $($copies.Count) 份 pwsh-hu-line（热重载会留下旧版本的类对象）——" +
                       'Tab 补全必然会报 class 转换错误。请完全退出 pwsh 重开，再运行 demo.ps1。')
        foreach ($c in $copies) { Write-Warning ('  - ' + $c.Name + ' @ ' + $c.Path) }
        [HuLog]::Write('warn', 'guard', 'refused: multiple module copies loaded')
        return
    }
    if ($staleFiles.Count -gt 0) {
        Write-Warning ("本进程里的 pwsh-hu-line 已过期（$($staleFiles.Count) 个源文件在加载之后被改过）——" +
                       'PowerShell 无法安全热重载带类的模块，请完全退出 pwsh 重开。')
        foreach ($f in $staleFiles) { [HuLog]::Write('warn', 'guard', 'stale source: ' + $f) }
        return
    }
    if ($selfTest -ne 'ok') {
        Write-Warning ("本进程的 pwsh-hu-line 类对象互相不匹配，管线自检失败：$selfTest")
        Write-Warning ("自检明细：$($smoke -join ' ; ')")
        Write-Warning '请完全退出 pwsh 重开（Remove-Module 不足以清掉进程里旧的类对象）。'
        return
    }

    if ([Console]::IsInputRedirected) {
        Write-Warning 'Enter-HuLineRepl needs a real console; stdin is redirected.'
        return
    }

    $history = [HuLineHistory]::new()
    if ($HistoryPath) { $history.Load($HistoryPath) }

    # Evaluate the user's `prompt` function once per line (the standard pwsh
    # mechanism — starship/oh-my-posh work by overriding it). The information
    # stream is redirected so stray Write-Host output inside prompt functions
    # (starship emits an empty Write-Host) does not corrupt the layout.
    $getPrompt = {
        try {
            $p = & prompt 6>$null 2>$null
        } catch {
            $p = $null
        }
        if ($null -eq $p) { return '' }
        # Join chunks without separators (Out-String would inject newlines and
        # turn a single-line prompt into a multi-line one), then trim any
        # trailing line breaks the function emitted.
        $s = (($p | ForEach-Object { if ($null -ne $_) { $_.ToString() } }) -join '').TrimEnd("`r", "`n")
        if ([string]::IsNullOrEmpty($s)) {
            $loc = Get-Location -ErrorAction SilentlyContinue
            $s = 'PS ' + $(if ($loc) { $loc.ProviderPath } else { '?' }) + '> '
        }
        return $s
    }

    [HuLog]::Write('info', 'repl', "start history=$HistoryPath")
    Write-Host ('hu-line log: ' + [HuLog]::Path) -ForegroundColor DarkGray
    $editorFailures = 0
    try {
        while ($true) {
            $promptText = & $getPrompt
            try {
                $line = Read-HuLine -Prompt $promptText -History $history
            } catch {
                # Record everything, then stay usable — but do NOT loop forever: a
                # process with mixed class identities throws on EVERY call, which
                # the user perceives as a flickering input line plus a dead Tab.
                # Fall back to the stock prompt with an instruction instead.
                $editorFailures++
                [HuLog]::Error('repl', "Read-HuLine failed (consecutive=$editorFailures)", $_)
                [HuLog]::Write('info', 'ident', [HuLog]::Identity())
                [HuLog]::Write('info', 'env', [HuLog]::Environment())
                if ($editorFailures -ge 2) {
                    Write-Warning "编辑循环连续失败 $editorFailures 次：本进程的 pwsh-hu-line 类对象已不可用（最常见原因：在本窗口里热重载过模块）。"
                    Write-Warning "已回落原生提示符。请完全退出 pwsh 重开；诊断已写入 $([HuLog]::Path)。"
                    break
                }
                Write-Warning ("输入行失败（已记入 $([HuLog]::Path)）：$($_.Exception.Message)")
                continue
            }
            $editorFailures = 0

            if ($null -eq $line) { continue }          # Ctrl+C → cancel, reprompt
            $trimmed = $line.Trim()
            if ($trimmed -eq '') { continue }
            [HuLog]::Write('info', 'line', ("len={0} text={1}" -f $line.Length, $line))
            if ($trimmed -in @('exit', 'quit')) {
                if ($HistoryPath) { $history.Save($HistoryPath) }
                exit                                    # end the whole session
            }
            if ($trimmed -in @('stock', 'native')) { break }   # back to stock prompt

            $history.Add($line)
            try { Invoke-Expression $line } catch {
                Write-Host $_.Exception.Message -ForegroundColor Red
            }
        }
    }
    finally {
        if ($HistoryPath) { $history.Save($HistoryPath) }
    }
}

<#
.SYNOPSIS
    Debug helper: returns the underline regions the highlighter produces for a
    piece of text. Useful for inspecting/tuning the highlighter.
.EXAMPLE
    Get-HuRegions -Text 'Get-ChildItem C:\Windows' -LocationPath $PWD.ProviderPath
#>
function Get-HuRegions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$LocationPath = ''
    )
    $hl = [HuPathHighlighter]::new($LocationPath)
    return , @($hl.GetRegions($Text))
}

Export-ModuleMember -Function Read-HuLine, Enter-HuLineRepl, Get-HuRegions
