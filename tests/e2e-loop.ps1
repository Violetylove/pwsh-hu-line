#Requires -Version 7.0
# e2e-loop.ps1 — end-to-end tests for the Read-HuLine key loop.
# Runs in its own pwsh process (module classes are module-scoped; the script
# dot-sources HuHistory.ps1 into the global scope to build history objects).
#
# Usage: pwsh -NoProfile -File tests/e2e-loop.ps1     (exit 0 = all pass)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/HuHistory.ps1')          # global HuLineHistory for the driver
Import-Module (Join-Path $root 'pwsh-hu-line.psd1') -Force

# No 'prompt' function needed: we pass -Prompt '' explicitly.

$script:Failed = 0

function New-KeyQueue([object[]]$Spec) {
    $q = [System.Collections.Generic.List[System.ConsoleKeyInfo]]::new()
    foreach ($s in $Spec) {
        switch ($s) {
            'UP'    { $q.Add([System.ConsoleKeyInfo]::new([char]0, [ConsoleKey]::UpArrow, $false, $false, $false)); continue }
            'DOWN'  { $q.Add([System.ConsoleKeyInfo]::new([char]0, [ConsoleKey]::DownArrow, $false, $false, $false)); continue }
            'TAB'   { $q.Add([System.ConsoleKeyInfo]::new("`t", [ConsoleKey]::Tab, $false, $false, $false)); continue }
            'ESC'   { $q.Add([System.ConsoleKeyInfo]::new([char]27, [ConsoleKey]::Escape, $false, $false, $false)); continue }
            'BS'    { $q.Add([System.ConsoleKeyInfo]::new([char]8, [ConsoleKey]::Backspace, $false, $false, $false)); continue }
            'CTRL-L'{ $q.Add([System.ConsoleKeyInfo]::new([char]12, [ConsoleKey]::L, $false, $false, $true)); continue }
            'ENTER' { $q.Add([System.ConsoleKeyInfo]::new("`r", [ConsoleKey]::Enter, $false, $false, $false)); continue }
            default { $q.Add([System.ConsoleKeyInfo]::new([char]$s, [ConsoleKey]::A, $false, $false, $false)) }
        }
    }
    return $q
}

# Drives the editor with a key sequence; returns @{ Line; Screen }.
# $Width/$Height pretend the terminal is that big (the layout's wrap/scroll logic
# needs a known size); 0 = unknown, i.e. a single-row line and no scrolling.
# -AllowExhaustion stops the drive when the key queue runs out and returns the
# screen as it was at that moment — the only way to inspect something the editor
# tears down before it returns (an open menu, for instance). The exhaustion throw
# is a harness mechanism, so catching it is not hiding a real failure.
function Drive([object[]]$Spec, $History, [int]$Width = 0, [int]$Height = 0, [string]$Prompt = '', [switch]$AllowExhaustion, [string]$Pending = '', [int]$KeyDelayMs = 0) {
    $q = New-KeyQueue $Spec
    $state = @{ I = 0 }
    # Throw when the script runs out of keys: without this the editor spins
    # forever on null keys and the test hangs instead of failing.
    $src = {
        if ($state.I -ge $q.Count) { throw "KeySource exhausted after $($state.I) keys" }
        if ($KeyDelayMs -gt 0) { Start-Sleep -Milliseconds $KeyDelayMs }
        $v = $q[$state.I]; $state.I++; return $v
    }
    # -Pending: the scripted stand-in for [Console]::KeyAvailable.
    #   queue  — the rest of the queue is already waiting: what a PASTE looks like
    #   always — a console that never stops claiming pending input (the hazard the
    #            burst guard has to survive)
    $probe = $null
    if ($Pending -eq 'queue') { $probe = { $state.I -lt $q.Count } }
    elseif ($Pending -eq 'always') { $probe = { $true } }
    $sw = [System.IO.StringWriter]::new()
    $line = ''
    try {
        $line = Read-HuLine -Prompt $Prompt -History $History -KeySource $src -OutWriter $sw `
            -TermCols $Width -TermRows $Height -PendingSource $probe
    } catch {
        if (-not $AllowExhaustion) { throw }
        $line = '<exhausted>'
    }
    return @{ Line = $line; Screen = $sw.ToString() }
}

# How many times the input row got repainted: each $redraw erases the rows it owns
# with ESC[2K before writing them back. Counts PAINTS, not characters — "one paint
# per pasted character" is exactly the regression the paste-burst case pins down.
function Count-Paints([string]$Stream) {
    return ([regex]::Matches($Stream, [regex]::Escape("`e[2K"))).Count
}

function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Ok) { Write-Host ("RESULT {0} PASS {1}" -f $Name, $Detail) }
    else { Write-Host ("RESULT {0} FAIL {1}" -f $Name, $Detail); $script:Failed++ }
}

# Every paint of the input row, in ORDER, as visible text. The editor erases the
# row(s), then writes the text, then parks the cursor, so the text is what follows
# the erase block and any SGR — a paint whose only content is escapes yields ''.
# Lets a test assert what was ON SCREEN at a moment, not just the final buffer.
function Get-ScreenRows([string]$Stream, [int]$Rows, [int]$Width) {
    $grid = @()
    for ($i = 0; $i -lt $Rows; $i++) {
        $line = [char[]]::new($Width)
        for ($j = 0; $j -lt $Width; $j++) { $line[$j] = ' ' }
        $grid += , $line
    }
    $row = 0; $col = 0
    $i = 0
    $len = $Stream.Length
    while ($i -lt $len) {
        $c = $Stream[$i]
        if ($c -eq [char]27 -and ($i + 1) -lt $len -and $Stream[$i + 1] -eq '[') {
            $j = $i + 2
            $sb = [System.Text.StringBuilder]::new()
            while ($j -lt $len -and -not [char]::IsLetter($Stream[$j])) { [void]$sb.Append($Stream[$j]); $j++ }
            $final = if ($j -lt $len) { $Stream[$j] } else { '?' }
            $a = $sb.ToString() -split ';'
            switch ($final) {
                'H' {
                    $r = if ($a.Count -ge 1 -and $a[0] -ne '') { [int]$a[0] - 1 } else { 0 }
                    $cc = if ($a.Count -ge 2 -and $a[1] -ne '') { [int]$a[1] - 1 } else { 0 }
                    $row = [Math]::Max(0, [Math]::Min($Rows - 1, $r)); $col = [Math]::Max(0, [Math]::Min($Width - 1, $cc))
                }
                'G' { $cc = if ($a[0] -ne '') { [int]$a[0] - 1 } else { 0 }; $col = [Math]::Max(0, [Math]::Min($Width - 1, $cc)) }
                'K' {
                    $mode = if ($a[0] -eq '') { 0 } else { [int]$a[0] }
                    $from = if ($mode -eq 2) { 0 } else { $col }
                    for ($k = $from; $k -lt $Width; $k++) { $grid[$row][$k] = ' ' }
                }
                'J' {
                    $mode = if ($a[0] -eq '') { 0 } else { [int]$a[0] }
                    if ($mode -eq 2) { for ($r2 = 0; $r2 -lt $Rows; $r2++) { for ($k = 0; $k -lt $Width; $k++) { $grid[$r2][$k] = ' ' } } }
                }
            }
            $i = $j + 1
            continue
        }
        if ($c -eq "`r") { $col = 0; $i++; continue }
        if ($c -eq "`n") {
            $row++
            if ($row -ge $Rows) {
                for ($r2 = 0; $r2 -lt $Rows - 1; $r2++) { $grid[$r2] = $grid[$r2 + 1] }
                $grid[$Rows - 1] = [char[]]::new($Width)
                for ($k = 0; $k -lt $Width; $k++) { $grid[$Rows - 1][$k] = ' ' }
                $row = $Rows - 1
            }
            $col = 0
            $i++
            continue
        }
        if ([int]$c -lt 32) { $i++; continue }
        if ($col -ge $Width) { $col = 0; $row++; if ($row -ge $Rows) { $row = $Rows - 1 } }
        $grid[$row][$col] = $c
        $col++
        $i++
    }
    return @($grid | ForEach-Object { (-join $_).TrimEnd() })
}

# --- history walk (the "↑ only reaches the previous command" regression) ---

$h1 = [HuLineHistory]::new(); $h1.Add('ls -la'); $h1.Add('git status'); $h1.Add('Get-ChildItem C:\Windows')
$r = Drive @('UP','UP','UP','ENTER') $h1
Check 'up-walks-oldest' ($r.Line -eq 'ls -la') ("got=[{0}] want=[ls -la]" -f $r.Line)

$h2 = [HuLineHistory]::new(); $h2.Add('a1'); $h2.Add('b2'); $h2.Add('c3')
$r = Drive @('UP','UP','DOWN','ENTER') $h2
Check 'up-up-down' ($r.Line -eq 'c3') ("got=[{0}] want=[c3]" -f $r.Line)

$r = Drive @('UP','UP','DOWN','DOWN','DOWN','ENTER') $h2
Check 'down-past-newest-is-fresh' ($r.Line -eq '') ("got=[{0}] want=[]" -f $r.Line)

# ↑ with a non-empty buffer anchors a prefix search and then walks older matches
$h3 = [HuLineHistory]::new(); $h3.Add('git status'); $h3.Add('Get-ChildItem'); $h3.Add('git log')
$r = Drive @('g','i','t',' ','UP','UP','ENTER') $h3
Check 'up-prefix-anchored' ($r.Line -eq 'git status') ("got=[{0}] want=[git status]" -f $r.Line)

# --- completion menu ---

$h0 = [HuLineHistory]::new()

# Tab with multiple matches opens the menu (assert the selected row is drawn)
$r = Drive @('G','e','t','-','TAB','ESC','ENTER') $h0
$opened = ($r.Screen -match "`e\[7m")
Check 'menu-opens' $opened ("screen-has-reverse-video={0}" -f $opened)

# Esc cancels the menu and keeps the typed buffer
$r = Drive @('G','e','t','-','TAB','ESC','ENTER') $h0
Check 'menu-esc-keeps-buffer' ($r.Line -eq 'Get-') ("got=[{0}] want=[Get-]" -f $r.Line)

# Enter accepts the selected item (buffer becomes a real command, not 'Get-')
$r = Drive @('G','e','t','-','TAB','ENTER') $h0
$accepted = ($r.Line.Length -gt 4) -and $r.Line.StartsWith('Get')
Check 'menu-enter-accepts' $accepted ("got=[{0}]" -f $r.Line)

# Typing a character while the menu is open LIVE-UPDATES it: 'Get-x' matches
# nothing, so the menu disappears and Enter submits the raw buffer.
$r = Drive @('G','e','t','-','TAB','x','ENTER') $h0
Check 'menu-typing-refresh-hides' ($r.Line -eq 'Get-x') ("got=[{0}] want=[Get-x]" -f $r.Line)

# Backspace while the menu is open re-computes: 'Get' still matches many, so the
# menu stays alive and Enter still accepts a completion.
$r = Drive @('G','e','t','-','TAB','BS','ENTER') $h0
$alive = ($r.Line.Length -gt 3) -and $r.Line.StartsWith('Get')
Check 'menu-backspace-refreshes' $alive ("got=[{0}]" -f $r.Line)

# ... and the edit is ON SCREEN: after the backspace the rendered input row must
# read exactly 'Get'. The drive stops right there (the menu is torn down before
# Read-HuLine returns, and Enter would accept a completion), so the screen still
# holds the post-edit state. The menu used to repaint that row from a stale cache,
# leaving 'Get-' behind while the buffer had already changed.
$r = Drive @('G','e','t','-','TAB','BS') $h0 -AllowExhaustion
$screen = Get-ScreenRows $r.Screen 24 80
Check 'menu-backspace-repaints-line' ($screen[0] -eq 'Get') ("row0=[{0}]" -f $screen[0])

# --- command colouring (real resolver against this session's commands) ------
# ONE colour for everything that resolves (command / alias / external program —
# the commander's call), red for a name that resolves to nothing.
$r = Drive @('G','e','t','-','C','h','i','l','d','I','t','e','m','ENTER') $h0
Check 'command-known-is-green' ($r.Screen -match "`e\[32mGet-ChildItem") 'cmdlet coloured green'
$r = Drive @('c','d','ENTER') $h0
Check 'command-alias-is-green' ($r.Screen -match "`e\[32mcd") 'alias coloured the same green'
$r = Drive @('w','h','e','r','e','.','e','x','e','ENTER') $h0
Check 'command-application-is-green' ($r.Screen -match "`e\[32mwhere\.exe") 'external program coloured the same green'
$r = Drive @('z','z','z','q','ENTER') $h0
Check 'command-unknown-is-red' ($r.Screen -match "`e\[31mzzzq") 'unknown command coloured red'

# --- line editing keys ---

# Ctrl+L clears the screen and redraws prompt + current line (no data loss)
$r = Drive @('a','b','c','CTRL-L','ENTER') $h0
Check 'ctrl-l-clearscreen' (($r.Line -eq 'abc') -and ($r.Screen -match "`e\[2J")) ("got=[{0}] screen-has-clear={1}" -f $r.Line, ($r.Screen -match "`e\[2J"))

# --- accepting a completion must leave nothing on screen -------------------
# Minimal terminal model so "what is left on screen" is COMPUTED, not eyeballed:
# CSI cursor addressing (H/G), EL (K), ED (J), wrapping at a width, LF = CR+LF
# (Windows console behaviour) and scrolling. Modelling the WIDTH is the point —
# the reported "leftover characters after Enter" was a multi-line tooltip making
# a menu row wrap past the rows Clear() erases, which no escape-stream assertion
# could see.

$r = Drive @('G', 'e', 't', '-', 'TAB', 'ENTER') $h0
$final = Get-ScreenRows $r.Screen 24 80
$below = @($final[1..($final.Count - 1)] | Where-Object { $_ -ne '' })
Check 'menu-accept-leaves-no-leftovers' ($below.Count -eq 0) ("rows below input=[{0}]" -f ($below -join ' / '))

# The reporter's flow: open a TALL menu, backspace back, then type a suffix that
# matches nothing. The menu used to be redrawn shorter and shorter while only the
# last (short) row count got erased, so its lower rows stayed on screen. Nothing
# below the input line may survive.
$r = Drive @('G', 'e', 't', '-', 'TAB', 'BS', 'BS', 'BS', 'BS', 'BS', 'BS', 'w', 'i', 'n', 't', 's', 'p', 'ENTER') $h0
$final = Get-ScreenRows $r.Screen 24 80
$below = @($final[1..($final.Count - 1)] | Where-Object { $_ -ne '' })
Check 'menu-edit-then-nomatch-leaves-no-leftovers' ($below.Count -eq 0) ("line=[{0}] rows below input=[{1}]" -f $r.Line, ($below -join ' / '))

# --- wrapped input line and full-screen layout (terminal size injected) -----
# A line wider than the terminal wraps onto a second VISUAL row. The erase has to
# cover both rows, otherwise the wrapped tail survives — same family as the
# last-row bug. (TermCols/TermRows are the headless hooks for exactly this.)
$spec = @()
foreach ($ch in ('x' * 90).ToCharArray()) { $spec += [string]$ch }
$spec += 'ENTER'
$r = Drive $spec $h0 80 24
$final = Get-ScreenRows $r.Screen 24 80
$belowWrapped = @($final[2..($final.Count - 1)] | Where-Object { $_ -ne '' })
Check 'wrapped-line-fills-two-rows' (($final[0].Length -eq 80) -and ($final[1].Length -eq 10)) `
    ("row0={0} row1={1}" -f $final[0].Length, $final[1].Length)
Check 'wrapped-line-leaves-nothing-below' ($belowWrapped.Count -eq 0) ("rows below=[{0}]" -f ($belowWrapped -join ' / '))

# Same, but the line shrinks back to a single row first: the multi-row redraw must
# erase the second visual row it no longer needs (90 chars → 10 backspaces → 80).
$spec = @()
foreach ($ch in ('x' * 90).ToCharArray()) { $spec += [string]$ch }
foreach ($i in 1..10) { $spec += 'BS' }
$spec += 'ENTER'
$r = Drive $spec $h0 80 24
$final = Get-ScreenRows $r.Screen 24 80
$belowShort = @($final[1..($final.Count - 1)] | Where-Object { $_ -ne '' })
Check 'wrapped-line-shrinks-cleanly' (($final[0].Length -eq 80) -and ($belowShort.Count -eq 0)) `
    ("row0={0} rows below=[{1}]" -f $final[0].Length, ($belowShort -join ' / '))

# Input row pushed to the LAST row of a 4-row window (3-line prompt): the editor
# must scroll itself room for the menu instead of addressing rows that don't exist.
# The drive stops with the menu still up — it is torn down before Read-HuLine
# returns — so the screen can be inspected while it is visible.
$r = Drive @('G','e','t','-','TAB') $h0 80 4 ("a`nb`nPS> ") -AllowExhaustion
$final = Get-ScreenRows $r.Screen 4 80
$menuVisible = @($final | Where-Object { $_ -match 'Get-A' }).Count -gt 0
Check 'menu-in-tiny-window-scrolls-room' ($menuVisible -and ($final[0] -match 'Get-')) `
    ("screen=[{0}]" -f ($final -join ' / '))

# --- pasting must not repaint per character ---------------------------------
# A pasted command lands in the console input buffer as a burst (keys arriving in
# the same instant), so the editor can tell that more input is already waiting and
# do the expensive part — filesystem-backed path highlighting, the history scan, a
# full-line repaint — ONCE at the end. Repainting per key is what made a paste
# crawl across the screen like a piano run: 30 characters, 31 repaints.
$paste = 'Get-ChildItem -Path C:\Windows'
$spec = @()
foreach ($ch in $paste.ToCharArray()) { $spec += [string]$ch }
$spec += 'ENTER'
$r = Drive $spec $h0 80 24 -Pending queue
$paints = Count-Paints $r.Screen
# <= 3, not == 2: one scheduling hiccup wider than the 30 ms burst gap is allowed
# to split the burst. A regression to per-key repainting lands near 31.
Check 'paste-burst-paints-once' (($r.Line -eq $paste) -and ($paints -le 3)) `
    ("paints={0} of {1} chars; line=[{2}]" -f $paints, $paste.Length, $r.Line)

# The guard's safety valve. Coalescing is only safe while keys keep arriving in
# rapid succession, so the editor ALSO measures the gap between keys: a console
# that permanently reports "input pending" (the probe can lie) must not be able to
# starve the repaint and leave the line invisible while someone types at human
# speed. Same probe as above, 40 ms between keys → every key must reach the screen.
$spec = @()
foreach ($ch in 'abcde'.ToCharArray()) { $spec += [string]$ch }
$spec += 'ENTER'
$r = Drive $spec $h0 80 24 -Pending always -KeyDelayMs 40
$paints = Count-Paints $r.Screen
Check 'burst-guard-ignores-lying-probe' (($r.Line -eq 'abcde') -and ($paints -ge 5)) `
    ("paints={0} for 5 slow keys; line=[{1}]" -f $paints, $r.Line)

# --- summary ---
Write-Host ("SUMMARY failed={0}" -f $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
