# scratch/buf-probe.ps1 — 在真实控制台里逐条验证「哪种写出路径能保住非 CP936 字符」。
# 原理：写出后用 $Host.UI.RawUI.GetBufferContents 把屏幕缓冲区的字符读回来。
# 必须跑在有真实控制台的进程里：conhost.exe --headless pwsh -NoProfile -File scratch/buf-probe.ps1
$L = [System.Collections.Generic.List[string]]::new()
function A([string]$s) { [void]$L.Add($s) }

function Cell([int]$y) {
    $r = [System.Management.Automation.Host.Rectangle]::new(0, $y, 0, $y)
    $c = $Host.UI.RawUI.GetBufferContents($r)
    return $c[0, 0].Character
}

function TryWrite([string]$Name, [scriptblock]$Writer, [string]$Text, [int]$Y) {
    [Console]::SetCursorPosition(0, $Y)
    & $Writer $Text
    $got = Cell $Y
    $code = if ($got.Length -gt 0) { [int][char]$got[0] } else { -1 }
    A ("{0,-20} U+{1:X4} -> [{2}] U+{3:X4}" -f $Name, [int][char]$Text[0], $got, $code)
}

$paths = [ordered]@{
    'Console.Out.Write' = { param($s) [Console]::Out.Write($s); [Console]::Out.Flush() }
    'Console.Write'     = { param($s) [Console]::Write($s) }
    'Host.UI.Write'     = { param($s) $Host.UI.Write($s) }
    'Write-Host'        = { param($s) Write-Host $s -NoNewline }
    'PSHostRawUI'       = { param($s) $Host.UI.RawUI.WindowTitle = $Host.UI.RawUI.WindowTitle }
}

foreach ($encName in @('as-is', 'utf8')) {
    if ($encName -eq 'utf8') { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 }
    A "=== encoding=$([Console]::OutputEncoding.WebName)/CP$([Console]::OutputEncoding.CodePage) redirected=$([Console]::IsOutputRedirected) ==="
    $y = 3
    foreach ($cp in @(0x4E2D, 0x276F)) {          # 中 (CP936 可编码) / ❯ (CP936 不可编码)
        foreach ($k in $paths.Keys) {
            TryWrite $k $paths[$k] ([string][char]$cp) $y
            $y++
        }
    }
    A ''
}

[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936)
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'buf-probe.txt'), ($L -join "`r`n"), [System.Text.UTF8Encoding]::new($false))
