#Requires -Version 7.0
# HuCommand.ps1 — command-name colouring (zsh-syntax-highlighting `command` /
# `unknown-token`): 能解析到的一律绿，找不到的红。
# 会话相关的判定（这名字是什么）由外部注入的 resolver 提供，所以本类保持纯粹、可单测。
class HuCommandHighlighter {
    [scriptblock]$Resolve
    $CommandStyle
    $UnknownStyle
    [System.Collections.Hashtable]$Cache

    HuCommandHighlighter([scriptblock]$resolver) {
        $this.Init($resolver, @{})
    }
    # 共享缓存重载：命令发现会扫 PATH，值得跨行记住。
    # 参数不叫 $cache —— 类成员大小写不敏感，会撞 $Cache 属性。
    HuCommandHighlighter([scriptblock]$resolver, $sharedCache) {
        if ($null -eq $sharedCache) { $sharedCache = @{} }
        $this.Init($resolver, $sharedCache)
    }

    hidden [void] Init([scriptblock]$resolver, $cacheStore) {
        $this.Resolve = $resolver
        $this.Cache = $cacheStore
        $this.CommandStyle = [HuStyle]::new($false, $false, 'green')
        $this.UnknownStyle = [HuStyle]::new($false, $false, 'red')
    }

    hidden [object] StyleFor([string]$kind) {
        if ($kind -eq 'unknown') { return $this.UnknownStyle }
        if ($kind -eq 'alias' -or $kind -eq 'application' -or $kind -eq 'command') { return $this.CommandStyle }
        return $null
    }

    hidden [string] KindOf([string]$name) {
        if ([string]::IsNullOrWhiteSpace($name)) { return '' }
        if ($this.Cache.ContainsKey($name)) { return [string]$this.Cache[$name] }
        $kind = ''
        try { $kind = [string](& $this.Resolve $name) } catch { $kind = '' }
        $this.Cache[$name] = $kind
        return $kind
    }

    # Command-name regions for $text. Half-open [Start, End) UTF-16 offsets, same
    # contract as HuPathHighlighter.GetRegions, so the renderer can merge both.
    [object] GetRegions([string]$text) {
        $regions = [System.Collections.Generic.List[object]]::new()
        if ([string]::IsNullOrEmpty($text)) { return $regions }
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        if ($null -eq $ast) { return $regions }

        $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($cmd in $cmds) {
            $els = $cmd.CommandElements
            if ($els.Count -eq 0) { continue }
            $el = $els[0]
            # only a literal name can be resolved; variables/expressions stay plain
            $sce = $el -as [System.Management.Automation.Language.StringConstantExpressionAst]
            if ($null -eq $sce) { continue }
            $name = $sce.Value
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name -eq '--%') { continue }                                   # stop-parsing marker
            if ([regex]::IsMatch($name, '[\$*?\[\]]')) { continue }             # expansion / wildcards: by design unknown
            $style = $this.StyleFor($this.KindOf($name))
            if ($null -eq $style) { continue }
            # [HuStyle]::IsEmpty guard: an all-default style would emit nothing, and
            # the class is disabled by setting its style to $null (checked above).
            $regions.Add([HuRegion]::new($sce.Extent.StartOffset, $sce.Extent.EndOffset, $style))
        }
        return $regions
    }
}
