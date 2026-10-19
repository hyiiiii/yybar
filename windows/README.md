# yybar for Windows

Tauri 2（Rust + React）实现的 Windows 托盘版。功能和界面说明见 [docs/Windows版.md](../docs/Windows版.md)。

## 下载

在 GitHub 仓库的 Actions → 「Windows 客户端」里打开最近一次成功的运行，下载 `yybar-windows-installer`，解压后运行 `yybar_x.y.z_x64-setup.exe`（装到当前用户，不需要管理员权限）。安装包没有代码签名，第一次运行 SmartScreen 会拦一下，点「更多信息 → 仍要运行」。

## 本地开发

需要 Node 22、Rust stable，Windows 上还需要 WebView2（Win11 自带）和 MSVC 生成工具。

```powershell
cd windows
npm install
npm run tauri dev      # 开发模式
npm run tauri build    # 打安装包，产物在 src-tauri/target/release/bundle/
```

只调界面时可以直接 `npm run dev` 用浏览器打开 `http://localhost:5173/`（面板）和 `/pill.html`（悬浮条），不在 Tauri 里时会显示演示数据（`src/demo.ts`）。

Rust 单元测试：`cd src-tauri && cargo test`（Linux / macOS 上也能跑）。

## 目录

```
src/                  界面（React）
  Panel.tsx           托盘弹出面板 + 设置页
  Pill.tsx            悬浮条
  api.ts              调后台命令、订阅 snapshot 事件
src-tauri/src/
  lib.rs              托盘、窗口、命令
  state.rs            全局状态和刷新调度
  tray_icon.rs        托盘图标绘制
  settings.rs         设置读写
  core/               凭据、额度接口、日志扫描、价格表
```
