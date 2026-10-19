# yybar Windows 版

代码在仓库的 `windows/` 目录，和 Mac 版（Swift）完全独立。技术栈是 Tauri 2：后台逻辑用 Rust（`windows/src-tauri/`），界面是 React 网页（`windows/src/`），借用系统自带的 WebView2 显示。

## 显示形式

Win11 的任务栏不能像 Mac 菜单栏那样常驻显示文字，所以拆成三处：

| 形式 | 对应 Mac 版 | 说明 |
|---|---|---|
| 托盘图标 | 菜单栏图标 | 32×32 圆角方块，写着所有启用服务里**最紧张那一档**的剩余百分比，底色按四档状态色（剩余 >50% 灰、20%~50% 黄、<20% 橙、=0 红；没数据是灰底 `--`）。悬停显示各服务的 5H / 周额度和今日花费。右键菜单：立即刷新、显示悬浮条、开机启动、退出 |
| 弹出面板 | Popover | 左键点托盘图标弹出，贴在图标上方（任务栏在上方时在下方），失焦或按 Esc 隐藏。顺序 Codex → Claude → Grok；每个服务一块：5H 环（Grok 是当前周期）、本周额度条、今日 tokens / 今日花费 / 本周花费；底部是今日 / 本周 / 本月合计和近 30 天每日花费柱状图。Ctrl+R 刷新 |
| 悬浮条 | 悬浮窗 | 默认开启，置顶的胶囊条，显示每个服务最紧张那档的剩余比例和今日花费。按住拖动换位置（位置会记住），单击打开面板 |

面板里的齿轮是设置页：开关三个服务、悬浮条、开机启动、是否统计 WSL、重置时间显示为倒计时还是具体时刻、额度刷新间隔（1 / 2 / 3 / 5 / 10 分钟，默认 2 分钟）。

服务 tile 里只写名字缩写（Cx / Cl / G），不用官方 logo，避开商标问题。用了 Win11 云母背景，Win10 上退回不透明底色；深浅色跟随系统。

## 数据来源

和 Mac 版同一套接口和解析规则（对应 `Core/Quota/*`、`Core/Usage/*`）：

- 凭据：`%USERPROFILE%\.claude\.credentials.json`（或 `CLAUDE_CONFIG_DIR`）、`%USERPROFILE%\.codex\auth.json`（或 `CODEX_HOME`）、`%USERPROFILE%\.grok\auth.json`。Windows 本机找不到时，再找正在运行的 WSL 发行版里的同名文件。
- 只读凭据，不刷新也不回写 token，轮换交给各 CLI 自己；Claude token 过期时提示在终端运行一次 `claude`。
- 额度：Claude `api.anthropic.com/api/oauth/usage`，Codex `chatgpt.com/backend-api/wham/usage`，Grok `cli-chat-proxy.grok.com/v1/billing`。走系统代理设置。
- 本地用量：扫 `.claude/projects`、`.codex/sessions` + `archived_sessions`、`.grok/sessions/**/updates.jsonl`，每分钟增量扫一次。打开「统计 WSL」时也扫正在运行的发行版里 `/home/*` 和 `/root` 下的同名目录（通过 `\\wsl.localhost\`）；没在运行的发行版不碰，避免把它们拉起来。
- 价格表在 `windows/src-tauri/src/core/pricing.rs`，从 Mac 版 `Pricing.swift` 抄过来，改价时两边一起改。

## 刷新与容错

- 网络失败保留上次快照，只在服务块下方显示错误。
- 429 后该服务退避 10 分钟，手动刷新也遵守。
- 每次打开面板会触发一次刷新（同样受退避约束）。

## 本地文件

| 路径 | 内容 |
|---|---|
| `%APPDATA%\yybar\settings.json` | 设置、悬浮条位置 |
| `%LOCALAPPDATA%\yybar\scan-state.json` | 日志扫描进度和按天汇总；版本或价格表变化时自动重扫 |

## 和 Mac 版的差距（第一版没做）

主窗口统计图表、多账号、Codex 压缩归档（`.jsonl.zst`）、自定义模型价格、服务状态圆点、上传到 yybar 网站。

## 构建

见 `windows/README.md`。推送改动到 `windows/` 后 GitHub Actions（`.github/workflows/windows.yml`）会在 Windows 机器上跑测试并打出安装包（NSIS `.exe` 和 `.msi`），在该次运行的 Artifacts 里下载。
