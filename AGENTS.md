# AGENTS.md

本文件给 AI 代理与协作者：仓库约定、命令与踩坑清单。
修改代码前请通读；新行为必须配套测试。

## 项目一句话

`pwsh-hu-line` — PowerShell 行编辑器，形态是**进程内 PowerShell/.NET 模块 +
$PROFILE 启动即接管交互循环**（`Enter-HuLineRepl`）。首个特性是 zsh 风格的
"已存在路径实时下划线"，现在还包括命令着色、fish 式历史建议、Tab 补全菜单、
前缀/增量历史搜索。**只做 pwsh，不做跨 shell**（2026-09-12 定案）。

## 技术栈与硬约束

- PowerShell 7（.NET 10），无第三方依赖。
- PowerShell Gallery 在此环境不可达 → **测试必须零依赖**（`tests/run-tests.ps1`，
  不要引入 Pester）。
- 类方法**不得调用模块函数**（PowerShell 类作用域限制）；跨类依赖只允许
  类→类的 static 调用（如 `[HuWidth]::Of(...)`）。
- **模块类不能用作导出函数的参数类型**：外部调用时参数类型在调用方上下文解析，
  模块类对外不可见 → `Unable to find type`。导出函数涉及模块类的参数一律不写类型
  （如 `Read-HuLine` 的 `$History`）。函数体内引用模块类没问题。
- 类方法返回类型的坑：**不写返回类型 = void**（不能 return 值）；`[string]` 返回
  会把 `$null` 强转为 `''`。需要可空返回用 `[object]`（如 `HuLineHistory.Previous`）。
- **类方法不支持可选参数/默认值**：`Render(a,b,c,d,[string]$e = '')` 会报
  "argument count" 错误——调用方必须传全参数（渲染器因此第 5 参必传，无建议传 `''`）。
- **prompt 拼接禁止用 `Out-String`**：它会给多段输出注入换行，把单行提示符变多行。
  用 `-join ''`。多行提示符本身已支持：提示符只画一次，重绘只碰输入行
  （`HuWidth.LineCount/LineTail` + `ESC[<row>;1H` 绝对定位）。
- **快捷键属于编辑器层，不能委托**：pwsh 引擎可交的是补全/解析/历史数据；
  键位绑定属于"画行的那一层"。我们接手了循环 ⇒ PSReadLine 的整张键位表都失效
  （Ctrl+L/Ctrl+U/Ctrl+Z… 都得自己实现）。新增绑定请配套 `tests/editor-loop.ps1` 场景。
- **`& scriptblock` 不能给外层局部变量赋值**：`$sb = { $x = 'new' }; & $sb` 之后外层
  `$x` 不变（已实测）。共享可变状态必须放进 **hashtable** 并改成员（`$state.X = ...`
  会透传），否则 helper 之间的状态写入会静默丢失——这正是"↑ 只能看上一个命令"和
  "Tab 菜单不更新"两个 bug 的根因。
- **无控制台句柄时连 Console 属性的读取都抛**："句柄无效"来自
  `[Console]::TreatControlCAsInput` / `CursorVisible` / `CursorTop`（读写都一样）。
  测试钩子 `-KeySource` 模式下必须全部跳过，并把 `[Console]::Out` 换成
  `-OutWriter`（或内部 StringWriter）。
- **输出编码：控制台输出码页不是 UTF-8 时 `[Console]::Out` 会静默改写字符**。
  中文 Windows 的码页是 GB2312/CP936，starship 的 `❯`(U+276F)、Nerd Font 私用区
  字形、emoji 全会被写成 `?`（真实控制台实测，`scratch/buf-probe.ps1` 用
  `$Host.UI.RawUI.GetBufferContents` 读回屏幕缓冲区：`[Console]::Out.Write('❯')`
  → `U+003F`；`$Host.UI.Write` / `Write-Host` 走宿主 UTF-16 路径则无损；`中` 两条
  路径都正常）。**所以渲染前必须用 `[HuConsoleEncoding]::BeginUtf8()` 临时把码页
  切到 UTF-8**（该 setter 同时调 `SetConsoleOutputCP`，终端才按 UTF-8 解码），并在
  **返回该行之前 `End()` 还原**：命令要在原码页下运行，否则本机中文工具吐出的 GBK
  字节会变乱码。回归测试 `tests/console-encoding.ps1` **必须跑在 `conhost.exe
  --headless` 下**（管道会把待测的编码器换掉，复现不了这个 bug）。
- **`String.IndexOf(string)` 是区域性比较，会「忽略」控制字符**：拿它去找带 `ESC`
  的标记（如 `` "`e[1;1H`e[2K" ``）会**晚一位命中**，把每个匹配点之后的首字符吃掉。
  凡是对**渲染串/转义串**做包含或定位的地方，一律显式传
  `[System.StringComparison]::Ordinal`（`IndexOf`/`StartsWith`/`Contains`），或用
  char 重载（char 比较本身即 ordinal）。此坑在「退格后菜单不刷新」排查中暴露：
  测试助手提取屏幕 paint 时被削首字符，证据看起来像乱码。
- 编辑循环的 E2E 验收入口：`tests/editor-loop.ps1`（`-KeySource` 喂按键序列 +
  `-OutWriter` 抓渲染文本）。键源耗尽必须 **throw**，否则主循环空转导致测试挂死。
  **断言要看得见"屏幕上画了什么"**：`InputLinePaints` 返回输入行每一次重绘的文本；
  「buffer 变了但没重绘」这类 bug 只有屏幕级断言抓得到（只查返回值必漏——这正是
  "退格后菜单不刷新"漏网的原因）。
- **模块类不能用在类方法的参数与属性类型里**（"模块类不能用作导出函数参数类型"那条的
  延伸，已实测踩过）：PowerShell 的**类类型身份按模块加载绑定**，一旦会话里同时存在两份
  本模块（两个路径 / `demo.ps1` 的 `-Force` 重载 / 脚本作用域导入），A 份造出的对象就
  转不进 B 份的同名类型，运行时报
  `Cannot convert the HuLineBuffer value of type HuLineBuffer to type HuLineBuffer`
  或 `Cannot find an overload for Add and the argument count: 1`。
  **所以 `src/` 里所有类方法的参数、属性一律不写类型**，只做鸭子类型访问；
  region 容器用 `List[object]` 而**不是** `List[HuRegion]`——后者是强类型容器，塞不进
  另一份的 HuRegion。回归驱动：`tests/module-identity.ps1`（真加载两份模块跑全链路）。
  **热重载是不支持的**：`Import-Module -Force` 换不掉进程里旧的类对象（`Get-Module`
  会同时列出两个路径），之后按 Tab 就会报 `Cannot convert ... to type ...`。
  `Enter-HuLineRepl` 接管前有三道自检（多实例 / 源文件在加载后被改 / **整条按键流水线
  冒烟**：`GetRegions` + `Render` + `Apply`），命中即提示"完全退出 pwsh 重开"并回落原生
  提示符；编辑循环连续失败 2 次也会 `break` 回落，避免"每键都炸"看起来像闪烁。
  **`demo.ps1` 会拒绝二次启动**（进程里已加载本模块就 `exit 1`）。
  **改完代码要验收，请退出 pwsh 重开，不要在原进程里重跑 `demo.ps1`。**
- **诊断日志（`src/HuLog.ps1`）：现场故障先读日志，不要靠猜**。默认
  `$HOME\.hu-line.log`；`$env:HU_LINE_LOG=<path>` 改路径、`=0` 关闭；超 1MB 轮转 `.1`。
  关键行：`ident` = 本份代码解析到的类 `RuntimeTypeHandle`（**同名类两份 = 两个 handle**）；
  `env` = 输出码页 / 重定向 / 已加载模块；`guard` = 接管前自检结论
  （`copies`/`staleFiles`/`selfTest`）；`line` = 每条提交的命令；`error` = 带 FQID、出错
  位置、调用栈、InnerException 链的完整错误；`apply` 失败行额外打
  `buffer=<handle> applyBufferParam=<handle> identical=<bool>`，**一眼判定类身份是否错配**。
  用户报"莫名其妙"的问题时，先要这个文件（并确认他是否重启过 pwsh）。
- **参数模式下 `[Type]::Member` 不会被求值**：`Get-Item -LiteralPath [HuLog]::Path`
  会把 `[HuLog]::Path` 当成**字面文本**传进去（报 `Cannot find a provider with the name
  '[HuLog]'`），而且这是**非终止错误**——`try/catch` 抓不到，只在控制台刷一条，功能静默
  失效（HuLog 的日志轮转就这么废过）。要么先赋值给变量（`$p = [HuLog]::Path`），要么
  纯 .NET（`[System.IO.FileInfo]::new($p).Length`）。测试用 `$Error.Clear()` +
  `Assert-Equal $Error.Count 0` 兜住这类"静默的非终止错误"。
- **命令着色（`src/HuCommand.ps1`）= 路径下划线的姊妹层**：同一个 region 通道、同一套定向
  SGR，渲染器按边界切段取并集，所以两层可叠加（`./x.ps1` 既着色又下划线）。
  配色（司令拍板：**能解析到的统一一色**）：命令 / 别名 / 外部程序一律 **green(32)**，
  未知 **red(31)**；把某个 style 设成 `$null` 即关闭该类。resolver 仍返回具体 kind
  （alias/application/command/unknown）且逐键缓存——粒度留着，将来想细分或做诊断时
  不必改结构，但**不要**因此再加配色。
  **会话相关的部分必须注入**：`HuCommandHighlighter` 只吃一个 resolver
  （`{ param($name) -> 'alias'|'application'|'command'|'unknown' }`），这样类本体是纯的、
  能用假 resolver 单测；resolver 在 psm1 里用
  `$ExecutionContext.SessionState.InvokeCommand.GetCommand($name, [CommandTypes]::All)`，
  结果按名字缓存到 **`$script:` 作用域**（命令发现会扫 PATH / 触发模块行为，不能每键重来）。
  解析器事实（`scratch/quote-probe.ps1`）：**前导引号不是命令名**（是解析错误，尾部 token
  反而成了命令）；`& 'name'` 才是带引号命令名的形态，且 extent **含引号**；只给
  `CommandElements[0]` 着色（参数不是命令）。
- **类成员名与方法参数名大小写不敏感地冲突**：`class` 里有 `$Cache` 属性时，方法参数
  不能叫 `$cache`——会报 `Cannot assign property, use '$this.Cache'`。参数改叫
  `$cacheStore` 之类。
- **菜单行必须严格等于一个终端行**：PowerShell 的补全 tooltip 是**多行**的
  （`Get-Alias` 有四行），直接塞进 `Draw` 会让该行换行/折行，落在 `Clear()` 擦除范围
  之外的部分就留在屏幕上——这就是"回车采纳补全后残留渲染字符"。做法：把 `\r\n\t`
  压成空格，再按**终端宽度**截断（`HuMenuRenderer.Width`，编辑器用
  `[Console]::WindowWidth` 设置，默认 80）。屏幕级回归：`tests/editor-loop.ps1` 的
  `menu-accept-leaves-no-leftovers`（内置终端模型，含折行/滚动），探针
  `scratch/screen-model.ps1`。
- **菜单的擦除必须按"高水位"，不是"上一次绘制"**：`Draw` 会补擦上一次更长绘制的尾巴，
  `Clear` 擦 `max(RowsUsed, RowsDrawn)`（`RowsDrawn` = 自上次 Clear 以来画过的最大行数）
  并双双归零。只擦上一次的行数会留下残影（司令实测："下面两三行清了、之后的行残留"）。
- **菜单契约：编辑实时重匹配**（司令最终拍板）：打字收窄、退格放宽、无匹配则收起；
  `$refreshMenu` 就是干这个的。它之所以安全，**全靠上面那条高水位擦除**——先有"逐键重匹配"
  而没有"高水位"就会留残影（实测：`menu-edit-then-nomatch-leaves-no-leftovers` 在动态
  匹配下也必须是 `rows below input=[]`）。改这块时两件事必须一起看。
- **终端没有"最后一行之下"：画任何东西之前先腾行**。重绘与菜单全用**绝对行号**
  （`ESC[<row>;1H`），而往屏幕末行之外写会**滚动屏幕**，让行号与实际内容错位。症状有两种，
  同一个根因：输入行落在最后一行时**每键都闪**（每次重绘都滚动一行）、**补全菜单一闪即隐**
  （菜单要画在输入行下方，没有行可用）。做法：`$ensureRoom(need)`（`Read-HuLine` 内，配合
  `HuLayout` 的纯函数 `RowsBelow/Deficit/Offscreen/MaxRows`）先把光标停到末行、发 N 个换行
  让整屏上滚，再**把 `$layout` 的行号同步减 N**；写提示符前 `$ensureRoom 0`（保证输入行本身
  在屏内），`$drawMenu` 前 `$ensureRoom $menuMaxRows`，`$menuMaxRows` 按窗口高度收敛。
  行号账本必须在 **hashtable**（`$layout`）里——scriptblock 写不了外层局部变量。
  无控制台（测试环境）时 `WindowHeight=0`，整套逻辑跳过，行为不变。
- **PowerShell 没有 C 风格注释**：`catch { /* ... */ }` 能解析通过，但 `/*` 是**命令名**，
  只在那个分支真被执行时才炸（"The term '/*' is not recognized"），而且会把 catch 里
  原本要处理的异常吃掉。`tests/Lint.Tests.ps1` 用真实 parser 扫全仓库的 CommandAst 名兜底。
- **`$home` 命名陷阱**：PowerShell 变量名大小写不敏感，`$home` 撞只读自动变量
  `$HOME`，赋值即抛异常。局部变量用 `$homeDir` 之类，禁止 `$home`。
- 跨文件类引用：`HuLine.ps1` 依赖 `HuCore.ps1` 的类型，**必须按依赖顺序
  dot-source**（psm1 已保证）。单独 `Parser::ParseFile` 检查 `HuLine.ps1` 会
  误报 "Unable to find type"，属预期，不是语法错误。语法自检方式见下。
- Region 为**半开区间** `[Start, End)`，UTF-16 char 偏移（与 PS AST Extent 一致）。
- SGR 用**定向重置**：下划线 `ESC[24m`、加粗 `ESC[22m`、前景 `ESC[39m`，禁止用
  `ESC[0m`（会连带清掉其它属性）。

## 目录结构

```
pwsh-hu-line.psd1/.psm1   模块入口：Read-HuLine（行编辑器）、Enter-HuLineRepl（REPL 宿主）、
                          Get-HuRegions（调试导出）
src/HuCore.ps1            HuStyle / HuRegion / HuWidth / HuLayout / HuConsoleEncoding（无依赖，先加载）
src/HuHistory.ps1         HuLineHistory（会话历史：导航/去重/存取/搜索）
src/HuLine.ps1            HuLineBuffer / HuRegionRenderer / HuPathHighlighter
src/HuMenu.ps1            HuCompletion / HuCompletionApplier / HuMenuRenderer（Tab 补全菜单）
src/HuCommand.ps1         HuCommandHighlighter（命令名着色：能解析到的绿 / 未知红）
src/HuLog.ps1             HuLog（诊断日志：ident/guard/line/error）
Install-PwshHuLine.ps1    安装：拷贝到模块目录 + 标记块接线 $PROFILE（可 -Uninstall）
demo.ps1                  交互演示（= 调用 Enter-HuLineRepl）
tests/run-tests.ps1       零依赖测试运行器（唯一验收入口）
tests/*.Tests.ps1         宽度 / 缓冲 / 高亮器 / 渲染器 / 历史 / 菜单 / 命令着色 / 布局 / 编码 / 日志 / lint 单测
tests/editor-loop.ps1     编辑循环 E2E（-KeySource 按键队列 + 内置终端模型 + 可注入终端尺寸）
tests/module-identity.ps1 两份模块实例共存时的全链路回归（类身份错配）
tests/console-encoding.ps1 真实控制台编码回归（必须由 conhost --headless 拉起）
tests/install.ps1         部署端到端（拷贝/接线/幂等/卸载，跑在 TEMP 路径上）
scratch/parser-probe.ps1  PS Parser AST 探针（验证解析假设）
scratch/quote-probe.ps1   引号/`&` 命令名的解析形态探针
scratch/buf-probe.ps1     写出路径 × 控制台码页对照探针（读屏幕缓冲区验证编码无损）
scratch/screen-model.ps1  终端模型探针（CSI/EL/折行/滚动 → 算出最终屏幕，验证无残留）
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

## 编码约定

- 文件按依赖顺序加载：`HuCore.ps1` → `HuLine.ps1`。
- 高亮器语义对照 zsh-syntax-highlighting（`path`/`path_prefix`）；末尾词的
  `path_prefix` 用 **glob 匹配**（父目录存在且确有以其开头的条目）才下划线。
  与 zsh 的偏差（含 `$` 全跳过、`~user/` 不支持）记在**代码注释 + README 两处**。
- 渲染层数据流：编辑 → `GetRegions(text)` → `Render(prompt, buffer, cursor, regions)`
  → 输出 `ESC[2K` + 渲染串 + `ESC[<col>G`；行号/折行/腾行由 `HuLayout` 负责。
- 新行为 = 新测试：宽度、缓冲、高亮 span、渲染串、光标列都要有断言。
