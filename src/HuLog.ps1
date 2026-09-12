#Requires -Version 7.0
# HuLog.ps1 — 诊断日志。环境类故障（控制台码页、同名的两套类身份）从外部看不见，
# 只能把事实写下来：`ident` 是本份代码解析到的 RuntimeTypeHandle —— 两份模块同名不同
# handle 时一眼可辨；出错时记 FQID / 位置 / 调用栈。
# 路径：$HOME\.hu-line.log（`$env:HU_LINE_LOG` 改路径、设 0 关闭；超 1MB 轮转 .1）。
class HuLog {
    static [string]$Path = ''
    static [bool]$On = $false
    static [int]$MaxBytes = 1048576

    static [void] Init([string]$path) {
        try {
            $want = $path
            if ([string]::IsNullOrEmpty($want)) {
                $want = $env:HU_LINE_LOG
                if ($want -in @('0', 'off', 'false', 'no')) {
                    [HuLog]::Path = ''
                    [HuLog]::On = $false
                    return
                }
            }
            if ([string]::IsNullOrEmpty($want)) {
                $want = Join-Path ([System.Environment]::GetFolderPath('UserProfile')) '.hu-line.log'
            }
            [HuLog]::Path = $want
            [HuLog]::On = $true
            [HuLog]::Rotate()
        } catch {
            [HuLog]::On = $false
        }
    }

    static [void] Rotate() {
        try {
            # NOTE: never write `Get-Item -LiteralPath [HuLog]::Path` — in ARGUMENT
            # mode PowerShell does not evaluate `[Type]::Member`, it passes the
            # literal text ("Cannot find a provider with the name '[HuLog]'"), so
            # the probe silently fails and the log never rotates. Read into a
            # variable, or use .NET directly as below.
            $p = [HuLog]::Path
            if ([string]::IsNullOrEmpty($p)) { return }
            if (-not [System.IO.File]::Exists($p)) { return }
            if ([System.IO.FileInfo]::new($p).Length -le [HuLog]::MaxBytes) { return }
            $bak = $p + '.1'
            if ([System.IO.File]::Exists($bak)) { [System.IO.File]::Delete($bak) }
            [System.IO.File]::Move($p, $bak)
        } catch { }
    }

    static [void] Write([string]$level, [string]$tag, [string]$message) {
        if (-not [HuLog]::On) { return }
        try {
            $line = '{0} [{1,-5}] {2,-5} {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $level, $tag, $message
            [System.IO.File]::AppendAllText([HuLog]::Path, $line + [System.Environment]::NewLine,
                [System.Text.UTF8Encoding]::new($false))
        } catch { }   # logging must never break the editor
    }

    static [string] HandleOf([System.Type]$t) {
        try { return $t.TypeHandle.Value.ToString('X') } catch { return '?' }
    }

    # Fingerprint of the module classes THIS compiled code resolved.
    static [string] Identity() {
        try {
            return ('HuLineBuffer={0} HuCompletionApplier={1} HuRegion={2} HuStyle={3}' -f
                [HuLog]::HandleOf([HuLineBuffer]),
                [HuLog]::HandleOf([HuCompletionApplier]),
                [HuLog]::HandleOf([HuRegion]),
                [HuLog]::HandleOf([HuStyle]))
        } catch {
            return "identity unavailable: $($_.Exception.Message)"
        }
    }

    # One-line environment snapshot: code page, redirection, loaded module copies.
    static [string] Environment() {
        $enc = 'n/a'
        try { $enc = "$([Console]::OutputEncoding.WebName)/$([Console]::OutputEncoding.CodePage)" } catch { }
        $inRed = 'n/a'; $outRed = 'n/a'
        try { $inRed = [Console]::IsInputRedirected } catch { }
        try { $outRed = [Console]::IsOutputRedirected } catch { }
        $mods = @(Get-Module | Where-Object { $_.Name -like 'pwsh-hu-line*' } |
            ForEach-Object { $_.Name + '@' + $_.Path }) -join ' | '
        return "encoding=$enc inRedirected=$inRed outRedirected=$outRed modules=[$mods]"
    }

    # Full error dump: message, FQID, source position, script stack, inner chain.
    static [void] Error([string]$tag, [string]$context, $ErrorRecord) {
        if (-not [HuLog]::On) { return }
        try {
            [HuLog]::Write('error', $tag, ('{0}: {1}' -f $context, $ErrorRecord.Exception.Message))
            [HuLog]::Write('error', $tag, '  FQID : ' + $ErrorRecord.FullyQualifiedErrorId)
            [HuLog]::Write('error', $tag, '  AT   : ' + ($ErrorRecord.InvocationInfo.PositionMessage -replace "`r?`n", ' / '))
            [HuLog]::Write('error', $tag, '  STACK: ' + ($ErrorRecord.ScriptStackTrace -replace "`r?`n", ' / '))
            $inner = $ErrorRecord.Exception.InnerException
            $depth = 0
            while ($null -ne $inner -and $depth -lt 5) {
                [HuLog]::Write('error', $tag, ('  INNER{0}: {1}: {2}' -f $depth, $inner.GetType().FullName, $inner.Message))
                $inner = $inner.InnerException
                $depth++
            }
        } catch { }
    }
}
