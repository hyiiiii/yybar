<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="yybar">
</p>

<h1 align="center">yybar</h1>

<p align="center">
  <b>一眼看清 Codex、Claude Code、Grok、Gemini 还剩多少额度，本机用了多少 Token、花了多少钱。</b>
</p>

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-14+-blue.svg">
  <img alt="Windows" src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4.svg">
  <img alt="Xcode" src="https://img.shields.io/badge/Xcode-26+-orange.svg">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-lightgrey.svg">
</p>

<p align="center">中文 · <a href="#english">English</a></p>

<p align="center">
  <img src="docs/Screenshots/menubar-breathing.gif" width="360" alt="菜单栏：正在干活的 CLI 图标会呼吸">
  <br>
  <sub>菜单栏：每个服务一个图标 + 剩余额度，正在干活的 CLI 图标会以自身颜色呼吸</sub>
</p>

yybar 是一个常驻菜单栏的小工具（不占 Dock），基于 [nanvon/cc-bar](https://github.com/nanvon/cc-bar) 二次开发。不用打开终端，随时看到各家 AI 编码工具的剩余额度、重置时间和本机用量；还可以把每天的用量传到 yybar 网站，换成筹码去打德州。

Windows 版在 [`windows/`](windows/) 目录，用 Tauri 2 按 Mac 版的流程和界面重做（每个服务一个托盘图标 + 额度弹出窗口 + 统计 / 设置主窗口 + 悬浮窗 + 首次引导），两边功能同步更新，差别见 [docs/Windows版.md](docs/Windows版.md#5-和-mac-版的差别)。

## 支持的服务

| 服务 | 额度 | 本机用量统计 | 说明 |
|---|---|---|---|
| **Codex** | 5 小时 / 每周 | ✓（含压缩过的 `.jsonl.zst` 旧会话） | 读 `codex login` 的登录 |
| **Claude Code** | 5 小时 / 每周 | ✓（含 Claude 桌面 App Cowork 会话） | 读 `claude` 的登录；Mac 可选同步 Claude 云端 Projects 用量 |
| **Grok** | 当前计费周期 | ✓ | 读 `grok login` 的登录 |
| **Grok Bot** | 每周 | ✓（按天、按模型） | 仅 Mac：读 Grok Bot 桌面 App 的登录 |
| **Gemini App** | 5 小时 / 每周 | 回答次数 | 仅 Mac：复用 Chrome 当前 Google 账号 |
| **Antigravity（agy）** | Gemini、Claude·GPT 两个池子，各有 5 小时 / 每周 | ✓ | 读本机 agy CLI |

菜单栏、弹出窗口、悬浮窗和统计里的顺序始终是 Codex → Claude → Grok → Grok Bot → Gemini → agy。

## 功能

### 菜单栏 / 任务栏

- 每个服务一个 logo + 剩余百分比，可选显示 5 小时窗口、周窗口或两者都显示（Windows 每个服务一个托盘图标，「两者」取较低者）
- **使用中呼吸**：哪个 CLI 正在干活，哪个图标就在自身颜色和原色之间呼吸；CLI 在等你批准工具调用时图标保持高亮、不闪烁，不用切到终端也知道谁在等你（见上面的动图）
- **用 hook 驱动呼吸**（Mac，可选）：为 Codex、Claude Code、Grok、agy 安装 yybar 的 hook，提问、调用工具、请求审批、回答结束时图标即时响应；不改动已有的 hook，关闭后只移除 yybar 添加的部分
- 什么都不显示时保留 yybar 的两张扑克牌图标，菜单栏不会空掉
- 右键菜单：立即刷新 ⌘R / 打开统计 / 设置… ⌘, / 退出

### 额度弹出窗口

左键点菜单栏图标（Windows 点托盘图标）弹出：

- 顶部 **统计 / 设置 / 悬浮窗 / bar** 四个按钮：「悬浮窗」直接切换悬浮窗样式，「bar」直接在浏览器打开 yybar 网站
- 菜单栏上的每个账号：服务图标、名称、套餐标签、官方服务状态圆点，下面 5H / WK 的剩余额度条、百分比和重置倒计时；刷新失败时名称旁一个小警告，悬停看原因
- 底部刷新按钮、上次更新时间，以及今日花费 / Token

### 桌面悬浮窗

<p align="center">
  <img src="docs/Screenshots/floating-window.gif" width="500" alt="悬浮窗：贴边收起、滑出、拖动，右键切换简略 / 详细">
  <br>
  <sub>贴在屏幕边上收成窄条，单击或拖出来；右键菜单切换简略 / 详细</sub>
</p>

- 置顶、不抢焦点、不占任务栏；显示哪些账号在 设置 · 服务 的「悬浮窗」列中勾选
- 三种样式（设置 · 悬浮窗、弹出窗口的「悬浮窗」按钮、悬浮窗右键菜单都能切换）：
  - **简略**（默认）：每个账号显示进度条和百分比
  - **详细**：每个账号显示 5H / WK 和重置时间
  - **隐藏**：关闭悬浮窗，勾选保留
- 按住拖动，靠近屏幕上下边自动吸附，位置会记住
- 拖到屏幕左 / 右边会整块滑进去，收成贴边的窄条（只留图标和百分比）；单击窄条从边上滑出，或像拉抽屉一样把它拖出来
- 右键菜单：统计 / 设置 / bar，以及切换样式
- Windows 版带看门狗：悬浮窗被最小化、跑到屏幕外或网页无响应时自动恢复

### 统计

- 时间范围：今天 / 昨日 / 7 天 / 30 天 / 全部 / 自定义，可按服务筛选；筛选按钮上带官方服务状态圆点
- **概览**：估算费用、Token、缓存读取三张卡片和环比；每日用量柱图（费用 / Tokens 切换、日均线）；「今天」可对比昨日 / 7 日均 / 30 日均 / 全部日均，今天用得越多，标题旁的火苗烧得越旺；当前各服务额度一览
- **额度变化**：今天各账号 5H / WK 剩余额度的变化曲线和每次变动记录
- **模型明细**：按模型列出输入 / 输出 / 缓存读取 / 缓存写入 / 费用，可排序，用量最多的模型带一团小火苗
- **Token 活动**：最近 53 周的热力图，累计总量、单日峰值、最长和当前连续使用天数
- **模型价格**：内置各家官方价，可自己填写或覆盖；改完后历史费用按新价格重算
- 数据全部来自本机 CLI 会话日志，增量扫描；还可以添加其他 Codex 目录（`CODEX_HOME` 指向别处时），用户目录下的 `.codex-*` 会自动识别；Windows 版可选同时统计正在运行的 WSL 发行版

### 多账号

- 自动识别本机 CLI 的登录，绿点标出 CLI 正在使用的账号
- 添加其他账号：在浏览器中登录（调用官方 CLI，用独立目录，不影响本机登录），或粘贴凭据（支持 cc-switch 导出的多账号 JSON）
- 一键把本机 CLI 切换到另一个账号，原账号自动保留，随时切回
- 每个账号显示套餐（如 ChatGPT Plus / Pro 20x、Claude Pro / Max / Ultra、SuperGrok，按档次着色）和下次续费日，3 天内续费橙色提醒
- 每个账号单独选择是否显示在菜单栏、悬浮窗；每行「查看额度」浮层看完整额度

### 刷新

- 额度和日志扫描各自后台循环，默认每 2 分钟（1–10 分钟可调），改了立即生效
- 同一服务两次刷新至少间隔 60 秒；遇到限流（429）自动退避 10 分钟，手动刷新也不绕过
- 网络失败时保留上次的数据；登录快过期时自动续期，登录失效时提示重新登录
- 显示 OpenAI / Anthropic / xAI / Cursor / Google 官方状态页的当前状态
- **Claude 云端 Projects**（Mac，可选）：用本机 Claude Code 账号同步 Claude 桌面端「项目」的用量，和本机重复的消息自动扣除

### bar 与 yybar 网站

主窗口侧边栏的 **bar** 是一间像素风小酒馆，点进去就是 [yybar 网站](https://yybar-web.hyi030618.workers.dev)：

- **上传用量换筹码**：用 GitHub 连接后，把今天以前已经过完的天按「天 × 服务 × 模型」的汇总传到网站，花费 $1 换 1 筹码；每天可一键上传一次，也可开启每天 0:30 自动上传；同一天同一服务只算一份，后来补到的用量下次上传时补齐
- **网站**：Token 燃烧榜和财富榜、多人德州扑克（也有机器人桌）、用筹码买牌背牌面和道具的商场、成就（连续使用、Token 里程碑、订阅等），个人主页按 App 统计页的样子展示用量和订阅

### 其他

- 首次启动引导：列出识别到的账号，一次性勾选菜单栏和悬浮窗
- 中英双语（跟随系统 / 中文 / English）、字体大小可调、开机自动启动
- 主窗口侧边栏可隐藏（⌃⌘S），统计 ⌘1、设置 ⌘,、刷新 ⌘R
- 省资源：Mac 后台常驻约 25 MB 内存、CPU 约 0.1%，动画交给系统图层播放

## 安装

### macOS

暂未提供签名公证过的安装包，需要从源码构建。

要求：

- macOS 14 Sonoma 或更新版本，Xcode 26 或更新版本
- 已在终端登录过要看的 CLI：`codex login`、`claude`、`grok login`
- 可选：`brew install zstd`（统计 Codex 压缩过的旧会话需要）

```bash
git clone https://github.com/hyiiiii/yybar.git
cd yybar
scripts/make_signing_cert.sh    # 只需一次：在登录钥匙串里创建本机自签代码签名证书
scripts/build_and_install.sh    # 构建 Release 并安装到 /Applications/yybar.app
```

固定的自签证书让每次构建的签名身份保持一致；不创建证书也能安装，脚本会改用 ad-hoc 签名。以后更新时 `git pull` 后再运行一次 `scripts/build_and_install.sh` 即可，设置和统计数据不受影响。

### Windows

在仓库的 Actions →「Windows 客户端」里打开最近一次成功的运行，下载 `yybar-windows-installer`，解压后运行 `yybar_x.y.z_x64-setup.exe`（装到当前用户，不需要管理员权限）。安装包没有代码签名，第一次运行时 SmartScreen 会拦截，点「更多信息 → 仍要运行」。需要 WebView2（Windows 11 自带）。从源码构建见 [windows/README.md](windows/README.md)。

首次启动会弹出引导窗口，列出识别到的账号并做几项基本设置。

## 常见问题

**Claude Code 显示小警告，提示登录已失效？**
Claude Code 的登录过期后会清空本机保存的令牌。在终端运行 `claude`，按提示输入 `/login` 重新登录，回到 yybar 点刷新即可。

**统计里少了 Codex 的旧会话？**
Codex 会把旧会话压缩成 `.jsonl.zst`，Mac 上需要本机有 `zstd` 命令（`brew install zstd`），装好后下一次扫描会自动补上。

**模型显示「未定价」，费用是「—」？**
新模型还没有内置价格。到 设置 · 通用 · 模型价格 填写，历史费用会按新价格重算。

**切换账号后 CLI 还在用旧账号？**
已经在运行的 CLI 会话需要重启才会使用新账号。

**Codex / Grok 的缓存写入为什么是「—」？**
这两家的日志不单独记录缓存写入，无法统计，不是漏算。

**Windows 上上传失败，提示连接超时？**
yybar 网站在 Cloudflare Workers 上，部分网络需要代理。在代理软件中开启「系统代理」或 TUN / 全局模式后重试即可，yybar 会自动使用新的代理设置，不用重开。

**Grok Bot / Gemini App 如何显示额度？**
Grok Bot 需要已登录桌面 App。Gemini 需要 Chrome 当前个人资料登录与 Gemini App 相同的 Google 账号，并能打开 gemini.google.com。首次可能需要在 macOS 钥匙串窗口允许 yybar 读取对应的 Safe Storage 条目。两项都不发送推理请求。Gemini 额外读取近期会话的回答次数和模型名，不保存正文或会话 ID，没有 token / 费用明细。Google 要求网页验证时保留上次额度并暂停请求 10 分钟。

**额度在掉，统计里却没有对应的用量？**
本机 CLI 和 Claude 桌面 App 的 Cowork 会话从日志统计；Claude 桌面端的「项目」可在 设置 · 刷新 · Claude 云端项目 开启同步。普通 claude.ai 网页 / App 对话没有可读取的用量数据，暂不支持。

## 数据与隐私

- 本地用量只读会话日志里的 token 数、模型和时间，不读对话内容：`~/.codex/sessions`、`~/.codex/archived_sessions`、`~/.claude/projects`（以及 Claude 桌面 App Cowork 会话的日志）、`~/.grok/sessions`、agy 的会话库。
- Gemini App 只读取 Chrome 的 Google 会话 Cookie（`__Secure-1PSID` / `__Secure-1PSIDTS`）；解密密钥与 Cookie 仅驻留内存，仅发送至 `https://gemini.google.com`。不读取其他网站数据。
- 网络请求只发往各服务自己的接口（查询额度、云端用量与近期模型元数据、续期登录）和官方状态页。
- **yybar 网站是可选的**：只有用 GitHub 连接后才会上传，自动上传默认关闭。上传的是按「天 × 服务 × 模型」汇总的 token 数和花费，以及各账号的套餐（账号只传摘要，不传邮箱）；不含对话内容和任何密钥。网站上的令牌可在「我的」页撤销，App 里「断开」删除本机令牌。
- 本地数据位置：
  - Mac：`~/Library/Application Support/yybar/`（额度缓存、用量汇总、其他账号的 token，只有本用户可读）、`~/Library/Caches/yybar/`（日志扫描进度）
  - Windows：`%APPDATA%\yybar\`（设置、缓存、用量汇总、其他账号凭据）、`%LOCALAPPDATA%\yybar\`（日志扫描进度）
- 卸载：Mac 删除 `/Applications/yybar.app` 和上面两个目录；Windows 在「设置 → 应用」里卸载，再删除上面两个目录。

## 开发

Mac：用 Xcode 打开 `yybar.xcodeproj`，scheme 选 `yybar` 运行。

| 目录 | 内容 |
|---|---|
| `MenuBar/` | 菜单栏图标、额度弹出窗口 |
| `Main/` | 主窗口：统计、设置、bar |
| `Floating/` | 桌面悬浮窗 |
| `Settings/` | 设置页、添加账号、模型价格 |
| `Onboarding/` | 首次启动引导 |
| `Core/` | 凭据、额度请求、刷新调度、日志扫描、本地存储、网站上传 |
| `Tests/` | 日志扫描回归测试 |
| `scripts/` | 构建安装、签名证书、生成 App 图标 |
| `windows/` | Windows 版（Tauri 2：Rust 后台 + React 界面），见 [windows/README.md](windows/README.md) |
| `web/` | yybar 网站：GitHub 登录、用量上传、排行榜、德州、商场、成就（Cloudflare Workers + D1），见 [web/README.md](web/README.md) |

产品需求、技术实现、设计风格、界面布局等文档见 [docs/](docs/README.md)。

## 致谢

- [cc-bar](https://github.com/nanvon/cc-bar) —— yybar 的起点
- [cc-switch](https://github.com/farion1231/cc-switch) —— 多 Provider 账号切换器，启发了多账号管理与导入流程
- [cockpit-tools](https://github.com/jlcodes99/cockpit-tools) —— 多平台 AI 编码助手仪表盘，在额度与刷新策略上提供了参考
- [CodexBar](https://github.com/steipete/CodexBar) —— macOS 菜单栏 AI 用量监控，在菜单栏交互与本地解析思路上多有借鉴
- [TokenYou](https://github.com/diegoparras/tokenyou) / [Gemini-API](https://github.com/HanaokaYuzu/Gemini-API) —— Gemini Apps 网页额度协议参考

## 许可

[MIT](LICENSE)。Claude / Anthropic、Codex / ChatGPT / OpenAI、Grok / xAI、Gemini / Antigravity / Google、Cursor 是各自所有者的商标，yybar 与这些公司没有关联。

---

<a id="english"></a>

## English

yybar is a menu bar app for macOS (with a Windows version in [`windows/`](windows/)) that shows how much quota you have left on **Codex**, **Claude Code**, **Grok**, **Grok Bot**, **Gemini** and **Antigravity**, plus how many tokens you've used locally and what they cost.

- **Menu bar / taskbar**: each service's logo with its remaining 5-hour / weekly quota. An icon breathes in its own colour while that CLI is working and stays lit while it waits for your approval (optionally driven by CLI hooks on macOS).
- **Quota popup**: click the icon for every account's 5H / WK bars, reset countdowns, plan, service status and today's cost. Buttons at the top open Stats, Settings, a floating-window style picker, and the yybar website.
- **Floating HUD**: always on top without stealing focus; Compact, Detailed or Hidden. Drag it to a screen edge to tuck it into a slim strip, then click or pull it back out like a drawer.
- **Stats**: cost, tokens and cache reads by day, service and model; today vs. recent averages; today's quota changes; a 53-week token heatmap; editable model prices with history recalculation. Everything is read from local CLI session logs, including Codex's compressed `.jsonl.zst` sessions and extra `CODEX_HOME` folders.
- **Accounts**: detects your local CLI logins, adds extra accounts (browser sign-in or pasted credentials), shows plans and renewal dates, and switches the local CLI to another account in one click.
- **bar & website** (optional): connect with GitHub to upload daily per-model usage totals to the [yybar website](https://yybar-web.hyi030618.workers.dev) and turn spending into chips ($1 = 1 chip) for leaderboards, multiplayer Texas hold'em, a shop and achievements.
- Chinese / English UI, adjustable text size, launch at login, first-run onboarding. About 25 MB of memory and 0.1% CPU in the background on macOS.

**macOS — build from source** (macOS 14+, Xcode 26+; optional `brew install zstd`):

```bash
git clone https://github.com/hyiiiii/yybar.git
cd yybar
scripts/make_signing_cert.sh    # once: creates a local self-signed code signing certificate
scripts/build_and_install.sh    # builds Release and installs /Applications/yybar.app
```

**Windows**: download `yybar-windows-installer` from the latest successful "Windows 客户端" run under Actions and run the setup (per-user, no admin rights; unsigned, so SmartScreen asks once). See [windows/README.md](windows/README.md) to build it yourself.

**Privacy**: yybar reads only token counts, models and timestamps from local logs, never conversation content. It talks to each service's own quota and token-refresh endpoints and their status pages. Nothing is uploaded unless you connect the yybar website; then only daily usage totals and account plans (accounts as hashes, no emails) are sent, and auto upload is off by default.

Licensed under [MIT](LICENSE). Claude / Anthropic, Codex / ChatGPT / OpenAI, Grok / xAI, Gemini / Antigravity / Google and Cursor are trademarks of their respective owners; yybar is not affiliated with them.
