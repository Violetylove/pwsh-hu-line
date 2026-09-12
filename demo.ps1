#Requires -Version 7.0
# Interactive demo: launches the hu-line REPL host (the same thing $PROFILE
# integration runs at pwsh startup). Run:  pwsh -NoProfile -File demo.ps1
param(
    [string]$ModulePath = (Join-Path $PSScriptRoot 'pwsh-hu-line.psd1'),
    [string]$HistoryPath = ''
)

# A pwsh process CANNOT hot-reload a module that defines PowerShell classes:
# Import-Module -Force swaps the module but the class objects of the previous
# revision stay in the process, and the editor then throws on every keystroke —
# which the user sees as "the input line flickers and Tab does nothing".
# Refuse early instead of starting a broken editor.
$already = @(Get-Module | Where-Object { $_.Name -like 'pwsh-hu-line*' })
if ($already.Count -gt 0) {
    Write-Warning 'demo.ps1 cannot be run twice in the same pwsh process (module already loaded).'
    Write-Warning ('Already loaded: ' + (($already | ForEach-Object { $_.Name + ' @ ' + $_.Path }) -join ' | '))
    Write-Warning 'Close this pwsh window and start a NEW one, then run demo.ps1 again.'
    Write-Warning 'PowerShell classes cannot be hot-reloaded; Remove-Module is not enough either.'
    exit 1
}

Import-Module $ModulePath -Force

Write-Host 'hu-line REPL — 输入命令回车执行；↑/↓ 历史；Ctrl+C 取消当前行；' -ForegroundColor DarkGray
Write-Host 'exit/quit 退出 pwsh；stock/native 回落原生 PSReadLine 提示符。' -ForegroundColor DarkGray
Write-Host '已存在的路径及其真实前缀会实时显示下划线。' -ForegroundColor DarkGray

if ($HistoryPath) { Enter-HuLineRepl -HistoryPath $HistoryPath }
else { Enter-HuLineRepl }
