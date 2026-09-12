#Requires -Version 7.0
# HuLine.ps1 — the line-edit model. Depends on HuCore.ps1 (HuStyle/HuRegion/HuWidth).

# Plain-text input buffer with a cursor (UTF-16 char offsets).
class HuLineBuffer {
    [string]$Text = ''
    [int]$Cursor = 0

    [void] Insert([string]$s) {
        if ($s.Length -eq 0) { return }
        $this.Text = $this.Text.Substring(0, $this.Cursor) + $s + $this.Text.Substring($this.Cursor)
        $this.Cursor += $s.Length
    }

    [void] Backspace() {
        if ($this.Cursor -le 0) { return }
        $this.Text = $this.Text.Remove($this.Cursor - 1, 1)
        $this.Cursor--
    }

    [void] Delete() {
        if ($this.Cursor -ge $this.Text.Length) { return }
        $this.Text = $this.Text.Remove($this.Cursor, 1)
    }

    [void] MoveLeft() { if ($this.Cursor -gt 0) { $this.Cursor-- } }
    [void] MoveRight() { if ($this.Cursor -lt $this.Text.Length) { $this.Cursor++ } }
    [void] Home() { $this.Cursor = 0 }
    [void] End() { $this.Cursor = $this.Text.Length }

    # Replace the whole buffer (history navigation); cursor to end.
    [void] SetText([string]$t) { $this.Text = $t; $this.Cursor = $t.Length }
}

# 渲染 prompt + buffer（+ 可选 fish 建议）：buffer 保持纯文本，region 是独立列表
# （zsh region_highlight 风格）；SGR 零宽，光标列按可见宽度算（含 CJK、prompt 里的 ANSI）。
# 返回 @{ Text; CursorColumn }。
class HuRegionRenderer {
    [System.Collections.Hashtable] Render([string]$prompt, [string]$buffer, [int]$cursor, $regions, [string]$suggestion) {
        if ($null -eq $regions) { $regions = @() }
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append($prompt)

        # Splits: every region boundary plus buffer ends. Runs between adjacent
        # cuts are uniform; the style of a run is the union of covering regions.
        $points = [System.Collections.Generic.SortedSet[int]]::new()
        [void]$points.Add(0)
        [void]$points.Add($buffer.Length)
        foreach ($r in $regions) { [void]$points.Add($r.Start); [void]$points.Add($r.End) }
        $cuts = @($points)

        $current = [HuStyle]::new()
        for ($i = 0; $i -lt $cuts.Count - 1; $i++) {
            $s = [Math]::Max(0, $cuts[$i])
            $e = [Math]::Min($buffer.Length, $cuts[$i + 1])
            if ($e -le $s) { continue }
            $style = [HuStyle]::new()
            foreach ($r in $regions) {
                if ($r.Start -le $s -and $r.End -ge $e) { $style = [HuStyle]::Merge($style, $r.Style) }
            }
            if (-not [HuStyle]::Same($style, $current)) {
                if (-not [HuStyle]::IsEmpty($current)) { [void]$sb.Append("`e[" + $current.ToSgrOff() + 'm') }
                if (-not [HuStyle]::IsEmpty($style)) { [void]$sb.Append("`e[" + $style.ToSgrOn() + 'm') }
                $current = $style
            }
            [void]$sb.Append($buffer.Substring($s, $e - $s))
        }
        if (-not [HuStyle]::IsEmpty($current)) { [void]$sb.Append("`e[" + $current.ToSgrOff() + 'm') }

        # fish-style suggestion: dim remainder after the buffer.
        if ($suggestion -and $suggestion.Length -gt $buffer.Length -and $suggestion.StartsWith($buffer, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$sb.Append("`e[2m" + $suggestion.Substring($buffer.Length) + "`e[22m")
        }

        $cursorCol = [HuWidth]::OfAnsi($prompt) + [HuWidth]::Of($buffer.Substring(0, $cursor)) + 1
        return @{ Text = $sb.ToString(); CursorColumn = $cursorCol }
    }
}

# 把输入文本变成"已存在路径"的下划线 region（zsh-syntax-highlighting 的
# `path`/`path_prefix`）：用真 PowerShell parser 取参数与重定向目标，存在性用
# File/Directory.Exists 判定；末尾词再做一次 glob 前缀检查。
class HuPathHighlighter {
    [string]$LocationProviderPath = ''
    # 不带类型：类身份按模块加载绑定，带类型会拒绝另一份模块造的 HuStyle。
    $PathStyle
    $PrefixStyle

    HuPathHighlighter() {
        $this.PathStyle = [HuStyle]::new($true, $false, '')
        $this.PrefixStyle = [HuStyle]::new($true, $false, '')
    }
    HuPathHighlighter([string]$locationProviderPath) {
        $this.LocationProviderPath = $locationProviderPath
        $this.PathStyle = [HuStyle]::new($true, $false, '')
        $this.PrefixStyle = [HuStyle]::new($true, $false, '')
    }

    # Returns [object] on purpose: a [HuRegion[]] return type converts the list
    # into THIS module load's HuRegion, which fails when the regions were built
    # by another copy of the module (tests/e2e-identity.ps1).
    [object] GetRegions([string]$text) {
        $regions = [System.Collections.Generic.List[object]]::new()
        if ([string]::IsNullOrEmpty($text)) { return @($regions) }
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        if ($null -eq $ast) { return @($regions) }

        # 1) command elements. For `& ...` the first element IS the target path;
        #    for plain commands the name is only checked when it looks like a path.
        $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($cmd in $cmds) {
            $els = $cmd.CommandElements
            $isCallOp = ($cmd.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand)
            $stopParsing = $false
            for ($i = 0; $i -lt $els.Count; $i++) {
                $el = $els[$i]
                if ($el -is [System.Management.Automation.Language.CommandParameterAst]) { continue }
                $sce = $el -as [System.Management.Automation.Language.StringConstantExpressionAst]
                if ($null -eq $sce) { continue }
                if ($stopParsing) { continue }
                if ($sce.Value -eq '--%') { $stopParsing = $true; continue }
                $isCommandName = ($i -eq 0 -and -not $isCallOp)
                if ($isCommandName -and -not $this.LooksLikePath($sce.Value)) { continue }
                $this.AddPathCandidate($regions, $sce.Value, $sce.Extent.StartOffset, $sce.Extent.EndOffset)
            }
        }

        # 2) redirection targets: Get-ChildItem x > out.txt
        $redirs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.RedirectionAst] }, $true)
        foreach ($r in $redirs) {
            $sce = $r.Location -as [System.Management.Automation.Language.StringConstantExpressionAst]
            if ($null -eq $sce) { continue }
            $this.AddPathCandidate($regions, $sce.Value, $sce.Extent.StartOffset, $sce.Extent.EndOffset)
        }

        # 3) zsh-style path_prefix on the trailing token
        $this.AddTrailingPrefix($regions, $text)

        return @($regions)
    }

    hidden [bool] LooksLikePath([string]$value) {
        return ([regex]::IsMatch($value, '[/\\]') -or $value.StartsWith('~') -or $value.StartsWith('.'))
    }

    hidden [void] AddPathCandidate($regions, [string]$value, [int]$start, [int]$end) {
        if ($value.Length -eq 0 -or $end -le $start) { return }
        if ([regex]::IsMatch($value, '[*?\[\]]')) { return }   # wildcards: not a literal path
        if ([regex]::IsMatch($value, '\$')) { return }         # variable expansion: v1 skips
        $full = $this.ResolvePath($value)
        if ([string]::IsNullOrEmpty($full)) { return }
        if ([System.IO.File]::Exists($full) -or [System.IO.Directory]::Exists($full)) {
            $regions.Add([HuRegion]::new($start, $end, $this.PathStyle))
        }
    }

    # Returns the full OS path for $value, or '' when it cannot be resolved.
    hidden [string] ResolvePath([string]$value) {
        try {
            if ($value.IndexOf([char]0) -ge 0) { return '' }
            $p = $value
            if ($p.StartsWith('~')) {
                # NOTE: never name a local `$home` — it collides with the
                # read-only automatic $HOME variable (case-insensitive).
                $homeDir = [System.Environment]::GetFolderPath('UserProfile')
                if ($p -eq '~') { $p = $homeDir }
                elseif ($p.StartsWith('~/') -or $p.StartsWith('~\')) { $p = $homeDir + $p.Substring(1) }
                else { return '' }   # ~user/... not supported in v1
            }
            if ([System.IO.Path]::IsPathRooted($p)) { return [System.IO.Path]::GetFullPath($p) }
            if ($this.LocationProviderPath) { return [System.IO.Path]::GetFullPath($p, $this.LocationProviderPath) }
            return ''
        } catch { return '' }
    }

    # zsh `path_prefix` (glob semantics): the last word of the buffer (no
    # trailing whitespace) is underlined when the path exists OR when its
    # parent directory exists and contains an entry starting with the typed
    # fragment — i.e. "is what I typed so far a correct prefix". This is the
    # live correctness hint the feature is about.
    hidden [void] AddTrailingPrefix($regions, [string]$text) {
        if ($text.Length -eq 0) { return }
        if ([regex]::IsMatch($text, '\s$')) { return }          # word must end the buffer
        $m = [regex]::Match($text, '(\S+)$')
        if (-not $m.Success) { return }
        $token = $m.Groups[1].Value
        $start = $m.Groups[1].Index
        $end = $start + $token.Length
        # naive last-word regex knows nothing about parsing: skip inside
        # comments or after --% (the parser already guards AST candidates).
        # IndexOf(string) is CULTURE-sensitive: it treats control characters as
        # ignorable and can therefore match at the wrong index — always pass
        # Ordinal when scanning text that may hold escapes.
        $hashIdx = $text.IndexOf('#', [System.StringComparison]::Ordinal)
        if ($hashIdx -ge 0 -and $hashIdx -lt $start) { return }
        $stopIdx = $text.IndexOf('--%', [System.StringComparison]::Ordinal)
        if ($stopIdx -ge 0 -and $stopIdx -lt $start) { return }
        if ($token.StartsWith("'") -or $token.StartsWith('"')) { return }   # unclosed quote
        if ([regex]::IsMatch($token, '[*?\[\]]')) { return }                # wildcards
        if ([regex]::IsMatch($token, '\$')) { return }                      # variable expansion
        $full = $this.ResolvePath($token)
        if ([string]::IsNullOrEmpty($full)) { return }
        if ([System.IO.File]::Exists($full) -or [System.IO.Directory]::Exists($full)) { return }  # AST already handled
        # prefix of an existing entry in the parent directory (native glob,
        # case-insensitive on Windows, stops at the first match)
        $parent = [System.IO.Path]::GetDirectoryName($full)
        $lastComp = [System.IO.Path]::GetFileName($full)
        if ([string]::IsNullOrEmpty($parent) -or [string]::IsNullOrEmpty($lastComp)) { return }
        if (-not [System.IO.Directory]::Exists($parent)) { return }
        try {
            $first = [System.IO.Directory]::EnumerateFileSystemEntries($parent, $lastComp + '*') | Select-Object -First 1
            if ($null -ne $first) {
                $regions.Add([HuRegion]::new($start, $end, $this.PrefixStyle))
            }
        } catch {
            # enumeration errors → no underline
        }
    }
}
