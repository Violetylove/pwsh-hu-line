# AGENTS.md

本文件给 AI 代理与协作者：仓库约定、命令与踩坑清单。
修改代码前请通读；新行为必须配套测试。

## 项目一句话

`pwsh-hu-line` — PowerShell 行编辑器，形态是**进程内 PowerShell/.NET 模块 +
$PROFILE 启动即接管交互循环**（`Enter-HuLineRepl`）。特性：zsh 风格的已存在路径实时
下划线、命令名着色、fish 式历史建议、Tab 补全菜单、前缀/增量历史搜索。
**只做 pwsh，不做跨 shell**（2026-09-12 定案）。

## 硬约束

### 类与类型

- 类方法**不得调用模块函数**（PowerShell 类作用域限制）；跨类依赖只允许类→类的 static
  调用（如 `[HuWidth]::Of(...)`）。
- **模块类不能出现在函数参数、类方法的参数或属性类型里**：类类型身份按模块加载绑定，
  模块类对外不可见、且两份模块实例的同名类互不相容。外部调用报 `Unable to find type`；
  两份实例共存时报 `Cannot convert the HuLineBuffer value of type HuLineBuffer to type
  HuLineBuffer` 或 `Cannot find an overload for Add and the argument count: 1`。
  所以——导出函数涉及模块类的参数（如 `Read-HuLine` 的 `$History`）、`src/` 里所有类方法
  的参数与属性，**一律不写类型**，只做鸭子类型访问；region 容器用 `List[object]` 而**不是**
  `List[HuRegion]`（后者是强类型容器，塞不进另一份的 HuRegion）。
  回归驱动：`tests/e2e-identity.ps1`（真加载两份模块跑全链路）。
- 类方法返回类型：**不写 = void**（不能 return 值）；`[string]` 会把 `$null` 强转成 `''`；
  需要可空返回用 `[object]`（如 `HuLineHistory.Previous`）。
- **类方法不支持可选参数/默认值**：`Render(a,b,c,d,[string]$e = '')` 报 "argument count"
  ——调用方必须传全参数（渲染器因此第 5 参必传，无建议传 `''`）。
- **类成员名与方法参数名大小写不敏感地冲突**：有 `$Cache` 属性时参数不能叫 `$cache`
  （`Cannot assign property, use '$this.Cache'`），改叫 `$cacheStore` 之类。
- **`$home` 撞只读自动变量 `$HOME`**，赋值即抛异常；局部变量用 `$homeDir`。
- 跨文件类引用（如 `HuLine.ps1` 用 `HuCore.ps1` 的类）**必须按依赖顺序 dot-source**，
  psm1 已保证。单独用 `Parser::ParseFile` 检查 `HuLine.ps1` 会误报 "Unable to find type"，
  属预期，不是语法错误（正确自检方式见下）。

### 热重载与模块身份

- **热重载不支持**：`Import-Module -Force` 换不掉进程里旧的类对象（`Get-Module` 会同时
  列出两个路径），之后按键就报 class 转换错误。**改完代码要验收，请退出 pwsh 重开**，
  不要在原进程里重跑 `demo.ps1`（它检测到已加载本模块就 `exit 1`）。
- `Enter-HuLineRepl` 接管前有三道自检（多实例 / 源文件在加载后被改 / **整条按键流水线
  冒烟**：`GetRegions` + `Render` + `Apply`），命中即提示"完全退出 pwsh 重开"并回落原生
  提示符；编辑循环连续失败 2 次也会 `break` 回落，避免"每键都炸"看起来像闪烁。

### 控制台与终端

- **无控制台句柄时连 Console 属性的读取都抛**："句柄无效"来自
  `[Console]::TreatControlCAsInput` / `CursorVisible` / `CursorTop`（读写都一样）。
  `-KeySource` 测试模式下必须全部跳过，并把 `[Console]::Out` 换成 `-OutWriter`。
- **输出编码：控制台输出码页不是 UTF-8 时 `[Console]::Out` 会静默改写字符**。中文 Windows
  的码页是 CP936，`❯`(U+276F)、Nerd Font 私用区字形、emoji 全被写成 `?`（实测
  `[Console]::Out.Write('❯')` → `U+003F`；`Write-Host` 走宿主 UTF-16 路径无损）。
  **渲染前必须 `[HuConsoleEncoding]::BeginUtf8()` 临时把码页切到 UTF-8**（该 setter 同时调
  `SetConsoleOutputCP`），并在**返回该行之前 `End()` 还原**——命令要在原码页下运行，否则
  本机中文工具吐出的 GBK 字节会变乱码。回归 `tests/e2e-console.ps1` **必须跑在
  `conhost.exe --headless` 下**（管道会把待测的编码器换掉，复现不了这个 bug）。
- **终端没有"最后一行之下"：画任何东西之前先腾行**。重绘与菜单全用绝对行号
  （`ESC[<row>;1H`），而往屏幕末行之外写会**滚动屏幕**，让行号与实际内容错位。同一个根因的
  两种症状：输入行落在末行时**每键都闪**、**补全菜单一闪即隐**。做法：`$ensureRoom(need)`
  （配合 `HuLayout` 的纯函数 `RowsBelow/Deficit/Offscreen/MaxRows`）先把光标停到末行、发 N 个
  换行让整屏上滚，再**把 `$layout` 的行号同步减 N**；写提示符前 `$ensureRoom 0`（保证输入行
  在屏内），`$drawMenu` 前 `$ensureRoom $menuMaxRows`（按窗口高度收敛）。行号账本必须在
  **hashtable**（`$layout`）里——scriptblock 写不了外层局部变量。无控制台（测试环境）时
  `WindowHeight=0`，整套逻辑跳过，行为不变。
- **`String.IndexOf(string)` 是区域性比较，会「忽略」控制字符**：拿它去找带 `ESC` 的标记
  （如 `` "`e[1;1H`e[2K" ``）会**晚一位命中**，把每个匹配点之后的首字符吃掉。凡是对渲染串/
  转义串做包含或定位，一律显式传 `[System.StringComparison]::Ordinal`，或用 char 重载
  （char 比较本身即 ordinal）。

### 编辑器层职责

- **快捷键属于编辑器层，不能委托**：pwsh 引擎能交的只是补全/解析/历史数据，键位绑定属于
  "画行的那一层"。我们接手了循环 ⇒ PSReadLine 的整张键位表失效（Ctrl+L/U/Z… 都得自己实现）。
  新增绑定请配套 `tests/e2e-loop.ps1` 场景。
- **接管必须认得"启动态"**：`$PROFILE` 对每个 pwsh 进程都生效，而 `pwsh -File x.ps1` /
  `pwsh -Command ...` 的 stdin 仍是**真控制台**（`IsInputRedirected` 拦不住），无条件接管会把
  脚本吞掉——脚本一行都跑不到，进程停在提示符等按键。做法：
  `[HuLaunch]::ScriptedFlags([Environment]::GetCommandLineArgs())` 命中
  `-File`/`-Command`/`-c`/`-EncodedCommand`/`-e`/`-ec`/`-NonInteractive` 就不接管；这道判定
  放在其它自检**之后**，好让"多实例/过期/编码"这些诊断保住优先级。显式调用者（`demo.ps1`，
  它自己就是 `-File` 启的）传 `-Force`。真控制台回归：`tests/e2e-console.ps1` 的
  `scripted-launch-is-not-swallowed`。
- **`& scriptblock` 不能给外层局部变量赋值**（已实测）：共享可变状态必须放进 **hashtable**
  并改成员（`$state.X = ...` 会透传），否则 helper 之间的状态写入会静默丢失。
- **粘贴必须合并重绘，而且判据不能只信探测**：粘贴是一串"同一瞬间到达"的按键，逐键重绘会把
  整行重画 N 次（每次还要跑文件系统路径高亮 + 历史扫描 + 补全重算），用户看到的就是从左往右
  像弹钢琴一样刷出来（实测 30 字符 = 31 次重绘）。做法：`$repaint`/`$refreshMenu` 在爆发期内只
  置脏（`$pending` hashtable），由循环顶部的 `$settle` 在爆发结束时补画一次。判据要**两个条件
  同时成立**：`[Console]::KeyAvailable` 说有输入在等，**且**距上一个按键 < 30ms
  （`$pending.GapMs`）。只信探测会出事——终端可能永远报 pending，那打字时整行就不再刷新；
  加上间隔条件后，按键重复（~31ms）和慢速输入都照常逐键上屏。**回车分支要单独补画**：粘贴
  可能以回车收尾，那时最后一次重绘还在延迟里。回归：`tests/e2e-loop.ps1` 的
  `paste-burst-paints-once`（30 字符 ≤3 次重绘）与 `burst-guard-ignores-lying-probe`（探测永远
  为真 + 每键间隔 40ms，每键都必须上屏）。

### 渲染与高亮

- Region 为**半开区间** `[Start, End)`，UTF-16 char 偏移（与 PS AST Extent 一致）。
- SGR 用**定向重置**：下划线 `ESC[24m`、加粗 `ESC[22m`、前景 `ESC[39m`；**禁止 `ESC[0m`**
  （会连带清掉其它属性）。
- **prompt 拼接禁止用 `Out-String`**（它会给多段输出注入换行，把单行提示符变多行），用
  `-join ''`。多行提示符本身已支持：提示符只画一次，重绘只碰输入行
  （`HuWidth.LineCount/LineTail` + 绝对定位）。
- 路径高亮语义对照 zsh-syntax-highlighting（`path`/`path_prefix`）：末尾词的 `path_prefix`
  用 **glob 匹配**（父目录存在且确有以其开头的条目）才下划线；与 zsh 的偏差（`$` 全跳过、
  `~user/` 不支持）记在**代码注释 + README 两处**。
- **命令着色（`src/HuCommand.ps1`）= 路径下划线的姊妹层**：同一个 region 通道、同一套定向
  SGR，渲染器按边界切段取并集，所以两层可叠加（`./x.ps1` 既着色又下划线）。配色（已拍板，
  能解析到的统一一色）：命令 / 别名 / 外部程序一律 **green(32)**，未知 **red(31)**；把某个
  style 设成 `$null` 即关闭该类。resolver 仍返回具体 kind（alias/application/command/
  unknown）且逐键缓存——粒度留着，将来想细分或做诊断时不必改结构，但**不要**因此再加配色。
  **会话相关的部分必须注入**：`HuCommandHighlighter` 只吃一个 resolver
  （`{ param($name) -> 'alias'|'application'|'command'|'unknown' }`），这样类本体是纯的、能用
  假 resolver 单测；resolver 在 psm1 里用
  `$ExecutionContext.SessionState.InvokeCommand.GetCommand($name, [CommandTypes]::All)`，结果
  按名字缓存到 **`$script:` 作用域**（命令发现会扫 PATH / 触发模块行为，不能每键重来）。
  解析器事实：**前导引号不是命令名**（是解析错误，尾部 token 反而成了命令）；`& 'name'` 才是
  带引号命令名的形态，且 extent **含引号**；只给 `CommandElements[0]` 着色（参数不是命令）。

### 补全菜单

- **菜单行必须严格等于一个终端行**：补全 tooltip 是**多行**的（`Get-Alias` 有四行），直接塞进
  `Draw` 会让该行换行/折行，落在 `Clear()` 擦除范围之外的部分就留在屏幕上（即"回车采纳补全后
  残留渲染字符"）。做法：把 `\r\n\t` 压成空格，再按**终端宽度**截断（`HuMenuRenderer.Width`，
  编辑器用 `[Console]::WindowWidth` 设置，默认 80）。屏幕级回归：
  `tests/e2e-loop.ps1` 的 `menu-accept-leaves-no-leftovers`。
- **擦除必须按"高水位"，不是"上一次绘制"**：`Draw` 会补擦上一次更长绘制的尾巴，`Clear` 擦
  `max(RowsUsed, RowsDrawn)`（`RowsDrawn` = 自上次 `Clear` 以来画过的最大行数）并双双归零。
  只擦上一次的行数会留下残影。
- **菜单契约：编辑实时重匹配**——打字收窄、退格放宽、无匹配则收起（`$refreshMenu`）。它之所以
  安全，**全靠上面那条高水位擦除**；改这块时两件事必须一起看。

### 语言与脚本陷阱

- **参数模式下 `[Type]::Member` 不会被求值**：`Test-Path [System.IO.Path]::GetTempPath()` 会把
  `[System.IO.Path]::GetTempPath()` 当成**字面文本**传进去（报
  `Cannot find a provider with the name '[System.IO.Path]::GetTempPath()'`），而且这是
  **非终止错误**——`try/catch` 抓不到，只在控制台刷一条，功能静默失效。要么先赋值给变量
  （`$p = [System.IO.Path]::GetTempPath()`），要么纯 .NET。测试用 `$Error.Clear()` +
  `Assert-Equal $Error.Count 0` 兜住这类静默错误。
- **PowerShell 没有 C 风格注释**：`catch { /* ... */ }` 能解析通过，但 `/*` 是**命令名**，只在
  那个分支真被执行时才炸（"The term '/*' is not recognized"），还会把 catch 里原本要处理的异常
  吃掉。`tests/Lint.Tests.ps1` 用真实 parser 扫全仓库的 CommandAst 名兜底。

### 测试与验收

- **测试零依赖**（`tests/run-tests.ps1`，不引入 Pester）：这是主动选择——少一层依赖和版本漂移。
  旧结论"PowerShell Gallery 不可达"**已作废**（实测 `Find-PSResource` 正常，api/v2 直连与走
  localhost:10000 代理都是 200），发布到 Gallery 这条路是通的。`run-tests.ps1` 是唯一验收入口，
  改动后必跑。
- 编辑循环 E2E 入口 `tests/e2e-loop.ps1`：`-KeySource` 喂按键序列 + `-OutWriter` 抓渲染文本 +
  可注入终端尺寸。**键源耗尽必须 `throw`**，否则主循环空转导致测试挂死。
- **断言要看得见"屏幕上画了什么"**：`Get-ScreenRows` 把渲染流喂进内置终端模型（含折行/滚动）
  算出屏幕内容，`Count-Paints` 数输入行被重画了几次。「buffer 变了但没重绘」「粘贴逐键重绘」
  这类 bug 只有屏幕级断言抓得到（只查返回值必漏）。
- 新行为 = 新测试：宽度、缓冲、高亮 span、渲染串、光标列都要有断言。

## 目录结构

```
pwsh-hu-line.psd1/.psm1   模块入口：Read-HuLine（行编辑器）、Enter-HuLineRepl（REPL 宿主）、
                          Get-HuRegions（调试导出）
src/HuCore.ps1            HuStyle / HuRegion / HuWidth / HuLayout / HuConsoleEncoding / HuLaunch
                          （无依赖，先加载）
src/HuHistory.ps1         HuLineHistory（会话历史：导航/去重/存取/搜索）
src/HuLine.ps1            HuLineBuffer / HuRegionRenderer / HuPathHighlighter
src/HuMenu.ps1            HuCompletion / HuCompletionApplier / HuMenuRenderer（Tab 补全菜单）
src/HuCommand.ps1         HuCommandHighlighter（命令名着色：能解析到的绿 / 未知红）
Install-PwshHuLine.ps1    安装：拷贝到模块目录 + 标记块接线 $PROFILE（可 -Uninstall）
demo.ps1                  交互演示（= 调用 Enter-HuLineRepl）
tests/run-tests.ps1       零依赖测试运行器（唯一验收入口）
tests/*.Tests.ps1         单测，按 src/ 分文件：Core（宽度/布局/编码/启动态）、History、Line（缓冲/
                          渲染/高亮）、Menu、Command、Lint（真实 parser 语法兜底）
tests/e2e-loop.ps1        编辑循环 E2E（-KeySource 按键队列 + 内置终端模型 + 可注入终端尺寸）
tests/e2e-console.ps1     真实控制台编码回归（必须由 conhost --headless 拉起）
tests/e2e-identity.ps1    两份模块实例共存时的全链路回归（类身份错配）
tests/e2e-install.ps1     部署端到端（拷贝/接线/幂等/卸载，跑在 TEMP 路径上）
```

## 常用命令

```powershell
# 交互演示
pwsh -NoProfile -File demo.ps1

# 安装到 $PSModulePath + $PROFILE 启动即接管（新开 pwsh 生效）
pwsh -NoProfile -File Install-PwshHuLine.ps1

# 全部测试（唯一验收入口，改动后必跑）
pwsh -NoProfile -File tests/run-tests.ps1

# 语法自检（先加载依赖，再 ParseFile，避免跨文件类引用误报）
pwsh -NoProfile -Command "& { . ./src/HuCore.ps1; . ./src/HuLine.ps1; $t=$null;$e=$null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'src/HuLine.ps1'),[ref]$t,[ref]$e) | Out-Null; if($e){$e | ForEach-Object Message} else {'OK'} }"
```

## 代码约定

- 文件按依赖顺序加载：`HuCore` → `History` → `Line` → `Menu` → `Command`（psm1 已保证）。
- 渲染层数据流：编辑 → `GetRegions(text)` → `Render(prompt, buffer, cursor, regions)`
  → 输出 `ESC[2K` + 渲染串 + `ESC[<col>G`；行号/折行/腾行由 `HuLayout` 负责。
- 注释只写结论和反直觉处（1–4 行），不写排查过程；行为偏差记在代码注释 + README，
  坑的完整清单只维护在本文件。
