# yybar Windows 版

> 2026-10-24 重做：流程、界面、数据规则全部对照 Mac 版重新实现（取代第一版的「托盘面板 + 悬浮条」）。
> 2026-10-26 补齐：其他账号（添加 / 切换本机 CLI 账号）、bar 页（连接 GitHub、上传用量）、界面过渡动画。
> 代码在仓库的 `windows/` 目录，和 Mac 版（Swift）完全独立；技术栈 Tauri 2：后台 Rust，界面 React，借系统自带的 WebView2 显示。
> 与 Mac 版不一致时，以 Mac 版的[产品需求](产品需求.md)为准，再按下文「和 Mac 版的差别」处理。

## 1. 模块对照

| Mac 版 | Windows 版 | 说明 |
|---|---|---|
| `Core/Credentials/*` | `src-tauri/core/src/credentials/` | 读 Codex / Claude Code / Grok 的本机登录；续费日推算 |
| `Core/Quota/*QuotaClient` | `core/src/quota/{codex,claude,grok,google}.rs` | 同一套接口与解析；agy 走 `agy -p /usage --output-format json` |
| `CodexTokenRefresher` / `ClaudeTokenRefresher` | `core/src/quota/{codex,claude}_refresh.rs` | 续期并原子写回原凭据文件；Claude 的「被动优先」五步照搬 |
| `ServiceStatusClient` | `core/src/quota/status.rs` | OpenAI / Anthropic Statuspage 组件、xAI RSS、Google incidents |
| `Core/Usage/*Scanner`、`JSONLLineReader` | `core/src/usage/{codex,claude,grok,agy,jsonl}.rs` | 流式按行读 + 关键词粗筛；Codex `.jsonl.zst` 用内置纯 Rust 解码 |
| `Pricing.swift` | `core/src/usage/pricing.rs` | 价格表、归一化、长上下文加价、自定义价格、指纹（改价格时两边一起改） |
| `UsageAggregator` / `UsageService` | `core/src/usage/{aggregator,service}.rs` | 增量扫描、全量重建保留已删日志的历史（`merge_preserving_history`） |
| `UsageActivityMonitor` | `core/src/usage/activity.rs` | 日志 30 秒内有写入 = 使用中；未完成工具调用 + 3 秒无写入 = 等待审批 |
| `Core/Storage/*` | `core/src/storage/` | 设置、额度缓存、今日额度变化、扫描进度 / 汇总 |
| `AppState` / `Scheduler` | `src-tauri/src/{app_state,scheduler}.rs` | 刷新协调、60 秒最小间隔、429 退避 10 分钟、失败保留快照 |
| `MenuBarLabel` / `StatusItemController` | `src-tauri/src/{tray,tray_render}.rs` | 每个服务一个托盘图标（见 §2） |
| `MenuBarPopoverView` | `src/popover/` | 左键托盘图标弹出的额度窗口 |
| `MainWindowRootView` + `StatsView` + `SettingsRootView` | `src/main/` | 侧边栏 + 统计 / 设置两个大页 |
| `FloatingPanelController` + `FloatingContentView` | `src-tauri/src/windows.rs` + `src/floating/` | 桌面悬浮窗 |
| `OnboardingView` | `src/onboarding/` | 首次启动 4 步引导 |
| `ExtraAccount` / `CLILoginSession` / `CLIAccountSwitch`、`AppState` 的其他账号部分 | `core/src/accounts/{mod,login,paste,profile,switch}.rs` + `src-tauri/src/accounts.rs` | 其他账号的存储、浏览器登录、粘贴导入、切换本机 CLI（见 §2.6） |
| `AddAccountSheet` / `ImportedCodexAccountsView` | `src/main/settings/{AddAccountDialog,SettingsView}.tsx` | 添加账号对话框、服务页里的其他账号行 |
| `YYBarWebAccount` | `core/src/web.rs` + `src-tauri/src/web.rs` | 连接 GitHub、上传用量、每天 12:00 自动上传（见 §2.7） |
| `BarView` | `src/main/bar/` | 像素小酒馆 + 上传卡片 |
| `DesignSystem.swift` / `L10n.swift` | `src/shared/{design.tsx,base.css,l10n.ts,format.ts}` | 状态色、识别色、tile、进度条、`tr(en, zh)` |

`core` 是不依赖 Tauri 的独立 crate，`cargo test` 在 Linux / macOS 上也能跑。

开发注意：Windows 上 WebView2 在同步命令或事件回调（托盘菜单、单实例唤起等）里新建窗口会卡死（窗口框出来、页面一直白屏）。新建窗口一律走 `windows.rs` 的 `build_later`（后台任务里建），会间接建窗口的前端命令写成 `async`。

开发注意：托盘图标的 set_icon / set_tooltip / 增删图标在后台线程调用时，Tauri 会把活交给主线程并原地等它做完。拿着锁这样等、主线程又在等同一把锁就会互等卡死（2026-10-27 修过：开着久了、CLI 一直在用、托盘图标呼吸时整个程序卡住，只能重开）。所以托盘只在主线程重画（`tray::update` 会转到主线程），调用托盘 / 窗口接口时不拿任何锁。

## 2. 界面

### 2.1 托盘（对应 Mac 菜单栏）

Windows 任务栏不能常驻文字，所以**每个勾选了「任务栏」的服务一个托盘图标**，顺序 Codex → Claude → Grok → Antigravity。只显示本机 CLI 登录着的（agy 为装了 CLI）和勾选了的其他账号；「任务栏」默认不勾，在引导或设置 · 服务里勾选：

- 图标是该服务的 tile（Codex 白底、Claude 桃橙、Grok 黑、Antigravity 白底彩虹 logo），中间写剩余百分比（系统 Segoe UI 字体），底部一条细进度条按 4 档状态色（剩余 >50% 灰、20%~50% 黄、<20% 橙、=0 红）。还没有数据时显示 logo。
- 显示哪个窗口：设置 · 显示 · 任务栏「额度周期」5H / WK / 取较低者（Mac 的「两者都显示」在一个小图标里放不下，改为取剩余较少的那个）；Grok 始终是计费周期。
- 使用中呼吸：会话日志 30 秒内有写入时，图标在数字和 logo 之间交替淡入淡出（1.6 秒一周期）；等待审批时一直显示 logo（最多 30 分钟）；额度用完的服务不呼吸；Antigravity 没有可区分两池的日志，额度刷新发现剩余减少时呼吸到下次刷新之后。
- 悬停提示：服务名、5H / WK 剩余（Antigravity 按池）、今日花费。
- 左键：弹出额度窗口；右键菜单：立即刷新 / 打开统计 / 设置… / 退出 yybar。
- 其他账号勾了「任务栏」也各有一个图标，排在同一服务本机账号的后面；不呼吸（日志分不出是哪个账号在用），悬停提示里带账号名。
- 一个都没有时保留一个 yybar 图标，避免托盘完全消失。
- Windows 11 会把新托盘图标收进「^」溢出区，引导页提示用户拖到任务栏上。

### 2.2 额度弹出窗口（对应 Mac `MenuBarPopoverView`）

320 宽、高度随内容，贴着点击的托盘图标弹出（任务栏在上 / 侧边时翻转），失焦或 Esc 收起，Ctrl+R 刷新。顶部 yybar + 统计 / 设置 / bar；中间是托盘上显示的每个服务和其他账号（一个账号都没有时提示去设置 · 服务添加；图标、名称、套餐、官方状态点，5H / WK 行按窗口实际长度写 5H / 1D / WK / MO，Antigravity 按池写成「Gemini 5H」），刷新失败时名称旁橙色小警告（悬停看原因）；底部刷新按钮 +「x 前更新」，右边今日花费 / Token。Win11 上用云母背景，Win10 退回不透明底色。

### 2.3 主窗口（对应 Mac 主窗口）

普通窗口，最小 760×560，设置页内容限宽 640 并在内容区水平居中，内容区白底、卡片 0.5px 描边（同 Mac）；分段选择器和 Mac 原生的一样：等宽分段、选中项蓝底白字、未选中的分段之间有细竖线。左侧 150 宽侧边栏（右上角是显示 / 隐藏侧边栏按钮，对应 Mac 标题栏上的同一个按钮；隐藏后按钮留在内容区左上角）：统计（概览 / 额度变化 / 模型明细 / Token 活动）、设置（服务 / 显示 / 刷新 / 通用）、bar，左下角上次刷新时间 + 刷新按钮（连上 GitHub 后上面多一行头像 + @用户名）。统计、设置各是一个大页，点侧边栏平滑滚动到对应部分，手动滚动时高亮跟随。Ctrl+R 刷新、Ctrl+1 统计、Ctrl+, 设置、Ctrl+Shift+S 显示 / 隐藏侧边栏。关窗即销毁（释放内存），再打开时回到关窗前的部分；时间范围、服务筛选、排序等选择保留到退出 App。

- **概览**：时间范围 今天 / 昨日 / 7 天 / 30 天 / 全部 / 自定义 + 服务筛选（全部 + 本机登录着、有其他账号或留有本地用量记录的服务，按钮上是官方状态圆点；工具栏和下面内容左对齐，一行放不下时服务筛选换到第二行）。3 张 KPI（估算费用、Tokens 不含缓存读取、缓存读取；Tokens 卡可合并成「全部 Tokens」），多日和上一同长度区间比较、单日和对比基准（昨日 / 7 天 / 30 天 / 全部）比较；多日是每日用量堆叠柱 + 日均虚线（费用 / Tokens），单日是「今天 / 昨日」每个服务当天 vs 基准的横条，今天旁有按热力档位烧的火苗；当前额度 2 列，只列本机登录着的账号。
- **额度变化**：今天各账号 5H / WK 剩余的阶梯线（只记变化点，延伸到现在），悬停看各账号剩余；账号列表可收起、逐个开关曲线、展开变动记录表。Grok 只在 WK 下；Antigravity 两池各一条。
- **模型明细**：可排序表格，未知定价显示 —，用量最多的模型带小火苗，Codex / Grok 的缓存写入显示 —。
- **Token 活动**：最近 53 周热力图（每天 / 每周 / 累计），累计 Token、峰值、最长 / 当前连续天数；「全部」用暖色四档，单个服务用识别色。
- **服务**：只列本机 CLI 登录着的服务（没登录的不显示「未识别」行），一个都没有时显示「还没有账号…」提示和「添加账号…」。每个服务一行：绿点（本机 CLI 正在使用）、tile、套餐标签（按档次着色）、续费日（Codex 取登录令牌、Claude 按订阅开始日推算）、邮箱；启用 / 任务栏 / 悬浮窗三列（任务栏、悬浮窗默认不勾）；「查看额度」浮层（5H | WK 两块并列、今日 / 本周花费、更新时间）；删除（只是不再显示和刷新，CLI 换账号后自动重新出现，可恢复）。每个服务的本机行下面接着列它的其他账号（左侧圆钮切换本机 CLI，切换中转圈），列表下方「添加账号…」，切换结果在下方提示 8 秒后淡出（见 §2.6）。
- **显示**：任务栏额度周期、使用中图标呼吸、等待审批保持 logo；重置时间显示（剩余时长 / 具体时间，悬停切换另一种）、服务状态圆点；显示悬浮窗。
- **刷新**：额度刷新、日志扫描间隔（1 / 2 / 3 / 5 / 10 分钟，默认 2 分钟，改了立即生效）；「也统计 WSL」（Windows 独有，见 §3）；上次刷新 + 立即刷新；本地用量扫描状态。
- **通用**：语言（跟随系统 / 中文 / English）、字体大小（小 / 标准 / 大 / 特大，按 0.9 / 1 / 1.1 / 1.2 倍缩放整个主窗口，同浏览器缩放）、开机自动启动、版本；模型价格（Codex / Claude Code / Antigravity 模型，每百万 Token 美元，回车或离开输入框保存，历史费用按新价格重算）。

### 2.4 悬浮窗

置顶、不抢焦点、不占任务栏按钮；每行 18px tile + 4px 进度条 + 剩余百分比（状态色），Grok 显示周期额度、其余 5H。只显示本机登录着的服务（「悬浮窗」默认不勾），勾了「悬浮窗」的其他账号也各占一行，都没有时写「没有要显示的账号」；同一服务有多行时 tile 右边加小号账号名。按住拖动，拖到离屏幕边 20 像素内自动吸附，位置记住（屏幕外时回到主屏右上角）；双击打开统计。松开鼠标时超出屏幕左 / 右边缘窗口宽度的 1/3 以上（至少 40 像素）、那一边又没有别的屏幕时收起成贴边窄条（30 宽、贴边一侧直角，每行小图标 + 剩余百分比）；单击窄条展开；拖动窄条松手时离屏幕边 60 像素内重新贴边，更远就地展开；收起状态重启后保持（同 Mac）。

### 2.5 引导

首次启动弹出 620×520 窗口：欢迎 → 检测到的账号（凭据位置、只读说明）→ 选择任务栏图标（只列检测到的服务，默认不勾）/ 悬浮窗 / 开机启动 → 完成（可直接打开统计）。

### 2.6 其他账号（对应 Mac `ExtraAccount` + `AddAccountSheet`）

除本机 CLI 正在用的账号外，可以再加 Codex / Claude Code / Grok / Google（一个 Google 账号同时对应 Gemini、Antigravity 两份额度）账号，只看额度，也能把本机 CLI 切换过去。

- **添加**：设置 · 服务 ·「添加账号…」，三步对话框：选服务商 → 选方式 → 登录。
  - 在浏览器中登录（推荐，需本机装了对应 CLI；除了 PATH，还会找注册表里的用户 / 系统 PATH、npm / pnpm / Volta / Scoop / WinGet / nvm / fnm / Bun 的目录，Codex 还会用 VS Code / Cursor / Windsurf 里 Codex 插件自带的 codex.exe；启动 CLI 时把这些目录补进 PATH，npm 装的 `.cmd` 能找到 node）：在独立目录里跑官方登录命令，不影响本机已登录的账号——`CODEX_HOME=<目录> codex login`、`CLAUDE_CONFIG_DIR=<目录> claude auth login --claudeai`（浏览器授权后把授权码粘回对话框）、`GROK_HOME=<目录> grok login --oauth`。可重新打开登录页、换个账号登录；取消时删掉目录。
  - 粘贴凭据：粘贴另一台电脑上的 `auth.json`（Codex，可用 JSON 数组一次粘几个）、`.credentials.json`（Claude，邮箱和套餐用 `api/oauth/profile` 补）、`auth.json`（Grok，只认 xAI 自己的账号）。
  - Google：弹出一个控制台窗口，在独立目录（`GEMINI_CLI_HOME`）里运行 agy；agy 提示登录成功后输入 `/exit`，回对话框点「完成添加」，检查约 15 秒。
  - 和本机 CLI 是同一个账号时拒绝添加；同一账号再加一次只换凭据，别名、开关、添加时间保留。
- **刷新**：和本机账号一起刷新，令牌续期后写回它自己的目录；登录失效时行上显示橙色警告「这个账号的登录已失效，请重新添加」。服务页每行有启用 / 任务栏 / 悬浮窗开关和「查看额度」，删除时连同目录一起删。
- **切换本机 CLI**（Codex / Claude / Grok；Google 不支持）：把该账号的凭据写进本机 CLI 的文件——Codex `auth.json` 的 tokens，Claude `.credentials.json` 的 `claudeAiOauth` 和 `.claude.json` 的 `oauthAccount`（`.claude.json` 解析不了时拒绝写），Grok `auth.json` 里 xAI 的那条记录。写之前原文件备份到 `switch-backups\`（只留最近一次），原来的本机账号自动存成其他账号，额度快照跟着带过去。已在运行的 CLI 会话要重启才生效。
- 启动时清理没有记录对应的账号目录（添加到一半退出留下的）。

### 2.7 bar（对应 Mac `BarView` + `YYBarWebAccount`）

侧边栏和额度弹出窗口都能进。上半是像素小酒馆（招牌跑马灯、门口招呼的小人，12 帧 / 秒），点它在浏览器打开网站的德州大厅；下半是上传卡片。

- **连接 GitHub**：「连接 GitHub…」在浏览器打开网站的 `/connect?state=…`，授权后网站跳回 `yybar://connect?token=…&state=…`（安装时注册的协议，`tauri-plugin-deep-link`；App 已在运行时由单实例插件把链接转给它），state 对得上才保存。连上后显示头像、@用户名、「断开」。
- **上传**：只传 Codex / Claude / Grok / Antigravity 今天以前的整天 (天, 服务, 模型) 汇总，按 (天, 服务) 记账，传过的不重传，每批最多 100 天；连接时先从网站拉一次已传记录。「待上传」显示还没传的天数和按本机价格估的花费（实际以网站价格表为准）。一键上传每天一次。
- **自动上传**：打开后每天本地 12:00 上传；那时 App 没开或还没扫完日志，就在下次扫描完成后补传。
- 文案、网站地址与 Mac 版一致。

### 2.8 过渡动画

对照 Mac 版的 SwiftUI 动画：数字变化时逐位滚动（KPI、单日对比、Token 活动汇总、额度变化的指标）；切换费用 / Tokens 时柱子高度和日均线平滑过渡；额度变化的账号列表、变动记录展开收起；侧边栏滑入滑出；统计 / 设置 / bar 之间切换时淡入；添加账号对话框步骤间左右滑动；新加的账号行淡入。

## 3. 数据来源

- **凭据**：`%USERPROFILE%\.codex\auth.json`（`CODEX_HOME`）、`%USERPROFILE%\.claude\.credentials.json`（`CLAUDE_CONFIG_DIR`；邮箱和订阅开始日从 `.claude.json` 补）、`%USERPROFILE%\.grok\auth.json`（只认 xAI 自己的账号）。Windows 上 Claude Code 不用钥匙串，所以没有 Mac 的钥匙串授权提示。
- **token 续期**：Codex 剩余不到 5 分钟、Claude 不到 30 秒时续期并原子写回原文件（Claude 先重读文件、礼让刚写入的新 token、invalid_grant 软恢复）；Grok 将过期或 401 时调用本机 `grok models`（只读）续期。
- **额度**：Codex `chatgpt.com/backend-api/wham/usage`，Claude `api.anthropic.com/api/oauth/usage`，Grok `cli-chat-proxy.grok.com/v1/billing`（订阅等级取 `/v1/settings`，6 小时一次），Antigravity `agy -p /usage --output-format json`（定时刷新至少间隔 100 秒）。走系统代理设置。
- **本地用量**：`.codex/sessions` + `archived_sessions`（含 `.jsonl.zst`）、`.claude/projects`（以及 Claude 桌面 App Cowork 会话 `%APPDATA%\Claude\local-agent-mode-sessions`）、`.grok/sessions/**/updates.jsonl`、`.gemini/antigravity-cli/conversations/*.db`（用系统自带的 `winsqlite3.dll` 只读复制出来的副本）。
- **WSL**：打开「也统计 WSL」时，凭据和日志也从正在运行的发行版的 `/home/*`、`/root` 读取（`\\wsl.localhost\`），没在运行的发行版不碰，避免把它们拉起来。本机找到的凭据优先。
- **服务状态**：OpenAI / Anthropic Statuspage 的 CLI 相关组件、xAI 状态 RSS、Google incidents（Gemini），5 分钟一次。

## 4. 本地文件

| 路径 | 内容 |
|---|---|
| `%APPDATA%\yybar\settings.json` | 全部设置（字段名同 Mac `yybar.settings.*`）、悬浮窗位置、引导标记 |
| `%APPDATA%\yybar\quota-cache.json` | 额度快照（启动先读它，界面立刻有数） |
| `%APPDATA%\yybar\quota-history-today.json` | 今日额度变化（只留当天） |
| `%APPDATA%\yybar\usage-rollup.json` | (天, 服务, 模型) 聚合 |
| `%APPDATA%\yybar\custom-model-prices.json` | 自定义模型价格 |
| `%APPDATA%\yybar\other-accounts.json` | 其他账号列表（别名、邮箱、套餐、开关、凭据目录名；不含令牌） |
| `%APPDATA%\yybar\accounts\<服务>\<uuid>\` | 每个其他账号一个目录，放 CLI 原样格式的凭据（Codex `auth.json`、Claude `.credentials.json` + `.claude.json`、Grok `auth.json`；Google 整个目录当 `GEMINI_CLI_HOME`） |
| `%APPDATA%\yybar\switch-backups\` | 切换本机 CLI 账号前的原文件备份（只留最近一次） |
| `%APPDATA%\yybar\web-account.json` | 网站连接：上传令牌、GitHub 用户名 / 昵称 / 头像地址 |
| `%APPDATA%\yybar\web-uploads-<用户名>.json` | 上传账本：传过的 (天, 服务)、上次上传时间、今天是否手动 / 自动传过 |
| `%LOCALAPPDATA%\yybar\scan-state.json` | 每个日志文件的扫描进度；价格指纹变化时全量重扫 |

## 5. 和 Mac 版的差别

| Mac 版功能 | Windows 版 | 原因 |
|---|---|---|
| 菜单栏一段文字里放多个服务 | 每个服务一个托盘图标；「两者都显示」改为取较低者 | 任务栏只能放方形小图标 |
| 本机没登录的服务显示「未识别」行，菜单栏 / 悬浮窗默认勾选 | 没登录的服务不列出、不进托盘 / 悬浮窗；任务栏、悬浮窗默认不勾 | 2026-10-27 按需求调整：没有账号时什么都不显示，由用户添加 |
| Grok Bot 额度与用量 | 没有 | 读不到：依赖 macOS 钥匙串里的「Grok Bot Safe Storage」解密 App 登录 |
| Gemini App 额度、回答次数 | 没有 | 依赖 Chrome 的 Cookie 解密，Windows 版 Chrome 用了绑定应用的加密（app-bound encryption），外部程序无法解开 |
| 其他账号令牌存在本用户私有文件 | 存在 `%APPDATA%\yybar\accounts\` 下按 CLI 原样格式的目录 | 直接复用 CLI 的登录命令和凭据读取、续期代码 |
| Codex 其他账号拖动排序 | 没有 | 按添加顺序排 |
| 用 hook 驱动呼吸 | 暂未做 | 只用日志监听判断使用中 / 等待审批 |
| Claude 委托 CLI 代办刷新、`claude /usage` 兜底 | 没有 | 续期失败时提示在终端运行 `claude` |
| Claude 云端 Projects 用量 | 暂未做 | 要改用量扫描流程（按 message id 扣回本地重复部分），接口是 beta，先不移植 |

## 6. 构建

见 [`windows/README.md`](../windows/README.md)。推送改动到 `windows/`（或 `Resources/Logos/`）后，GitHub Actions（`.github/workflows/windows.yml`）在 Windows 机器上跑 `cargo test --workspace`、构建界面并打出安装包（NSIS `.exe` 和 `.msi`），在该次运行的 Artifacts 里下载。
