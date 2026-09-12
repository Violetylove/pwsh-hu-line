# pwsh-hu-line

> 给 pwsh 用的行编辑器：启动即接管交互循环，补上 zsh 风格的高亮与补全。

## 特性

- **路径下划线** —— 已存在的路径、或真实存在的前缀，实时带下划线（`cd C:\Wi` ✓）
- **命令着色** —— 能解析到的命令/别名/程序显示绿色，找不到的显示红色
- **Tab 补全菜单** —— 单匹配直接补，多匹配开菜单，边打边筛
- **历史** —— `↑` 前缀搜索、`Ctrl+R` 增量搜索、fish 式行内建议（`→` 采纳）
- **prompt 继承** —— 每行调用你的 `prompt` 函数，starship / oh-my-posh 直接可用

## 安装

```powershell
pwsh -NoProfile -File Install-PwshHuLine.ps1              # 装模块 + 往 $PROFILE 写入启动接管
pwsh -NoProfile -File Install-PwshHuLine.ps1 -Uninstall   # 卸载（只摘掉自己写的那段）
```

装完**新开**一个 pwsh 窗口生效。可选参数：`-ModuleRoot`、`-ProfilePath`、`-SkipProfile`、`-Quiet`；
不想安装也可以先跑 `pwsh -NoProfile -File demo.ps1`。

## 使用

接管后在提示符里照常输入，另外：

| 按键 | 作用 |
|---|---|
| `Tab` / `Shift+Tab` | 补全；菜单打开时切换选中项 |
| `↑` / `↓` | 历史；已输入前缀时按前缀搜索 |
| `→` / `Ctrl+F` | 采纳行内历史建议 |
| `Ctrl+R` | 增量搜索历史 |
| `Esc` | 关闭补全菜单 |
| `Ctrl+L` | 清屏 |
| `Ctrl+C` | 放弃当前行 |

输入 `stock` 回原生 PSReadLine 提示符，`exit` 退出 pwsh。历史存在 `~\.hu-line_history`。

## 注意事项

- 已知限制：不认 PSDrive（`HKLM:\`）的实时下划线；含 `$` 的 token 跳过；`~user/` 不支持；
  没有 `Ctrl+U/K/W` 这类编辑键
- 改过源码后请**退出 pwsh 重开**：带类的模块不能在活着的进程里热重载

## 致谢

高亮与补全的语义参照 [zsh-syntax-highlighting](https://github.com/zsh-users/zsh-syntax-highlighting)
的 `path` / `path_prefix` / `command` / `unknown-token`。

## 许可

MIT © Violetylove
