# scratch/ — 诊断探针

一次性排查用的脚本（可以随时重跑，**不是**验收测试——验收在 `tests/`）。
留着它们是因为每个都对应一类"只能靠读数、不能靠推理"的问题。

| 探针 | 回答什么问题 |
|---|---|
| `parser-probe.ps1` | PowerShell Parser 对各种输入给出什么 AST（裸词/引号/`&`/尾随不完整 token/`--%`/重定向）——高亮器的一切假设都来自它 |
| `quote-probe.ps1` | 带引号的命令名到底是什么形态（结论：**前导引号不是命令名**，是解析错误；`& 'name'` 才是，且 extent 含引号） |
| `buf-probe.ps1` | 各条写出路径 × 控制台码页的对照表（`[Console]::Out` 会把 `❯` 写成 `?`；`$Host.UI.Write` 无损）。需要真实控制台，用 `$Host.UI.RawUI.GetBufferContents` 读屏 |
| `screen-model.ps1` | 用终端模型（CSI/EL/折行/滚动）算出"最终屏幕上到底剩了什么"，验证菜单/折行不留残影 |

用法（示例）：

```powershell
pwsh -NoProfile -File scratch/parser-probe.ps1
pwsh -NoProfile -File scratch/quote-probe.ps1
conhost.exe --headless pwsh -NoProfile -File scratch/buf-probe.ps1   # 需要真实控制台
pwsh -NoProfile -File scratch/screen-model.ps1
```

> E2E 里已经内置了同样的终端模型（`tests/editor-loop.ps1` 的 `Get-ScreenRows`），
> 所以**回归**走 `tests/run-tests.ps1`；这里的探针用于人工排查与探索新问题。
