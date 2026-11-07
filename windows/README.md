# yybar for Windows

Tauri 2（Rust + React）实现的 Windows 版，流程和界面对照 Mac 版。功能、模块对照和与 Mac 版的差别见 [docs/Windows版.md](../docs/Windows版.md)。

## 下载

在 GitHub 仓库的 Actions →「Windows 客户端」里打开最近一次成功的运行，下载 `yybar-windows-installer`，解压后运行 `yybar_x.y.z_x64-setup.exe`（装到当前用户，不需要管理员权限）。安装包没有代码签名，第一次运行 SmartScreen 会拦一下，点「更多信息 → 仍要运行」。

## 本地开发

需要 Node 22、Rust stable，Windows 上还需要 WebView2（Win11 自带）和 MSVC 生成工具。

```powershell
cd windows
npm install
npm run tauri dev      # 开发模式
npm run tauri build    # 打安装包，产物在 src-tauri/target/release/bundle/
```

只调界面时可以 `npm run dev`，用浏览器打开 `http://localhost:5173/main.html`（主窗口）、`/popover.html`（额度弹出窗口）、`/floating.html`（悬浮窗）、`/onboarding.html`（引导）；不在 Tauri 里时显示演示数据（`src/shared/demo.ts`）。

测试：`cd src-tauri/core && cargo test`（核心逻辑，Linux / macOS 上也能跑）；`cd src-tauri && cargo test --workspace`（Windows 上，含托盘图标绘制）。在非 Windows 机器上检查整个程序能否编译：`rustup target add x86_64-pc-windows-msvc`，然后 `cargo check --target x86_64-pc-windows-msvc`。

## 目录

```
popover.html / main.html / floating.html / onboarding.html   四个窗口的入口
src/
  shared/      共享：后台接口（api.ts）、类型、文案（l10n.ts）、格式化、设计组件（design.tsx、base.css）
  popover/     托盘额度弹出窗口
  main/        主窗口：侧边栏、统计（stats/）、设置（settings/，含添加账号对话框）、bar（bar/）
  floating/    桌面悬浮窗
  onboarding/  首次启动引导
src-tauri/
  src/         程序外壳：全局状态与刷新（app_state.rs）、调度（scheduler.rs）、托盘（tray.rs、tray_render.rs）、
               窗口（windows.rs）、前端命令（commands.rs）、其他账号（accounts.rs）、连接网站与上传（web.rs）
  core/        核心逻辑（不依赖 Tauri）：凭据、额度接口、token 续期、服务状态、日志扫描、价格、存储、
               其他账号（accounts/）、网站上传（web.rs）
```
