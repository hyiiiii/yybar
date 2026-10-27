//! 窗口管理（对应 Mac `WindowCoordinator` + `FloatingPanelController`）。
//!
//! - `popover`：点托盘图标弹出的额度浮窗（320 宽，高度随内容），贴着图标弹出，失焦或 Esc 收起。
//! - `main`：主窗口（统计 / 设置共用侧边栏）。关窗即销毁释放内存，再打开时回到关窗前的部分（界面选择存在 AppState）。
//! - `floating`：桌面悬浮窗，置顶、不抢焦点、可拖动；拖到离屏幕边 20 像素内自动吸附；位置记住，屏幕外时回到右上角。
//! - `onboarding`：首次启动的 4 步引导。
//!
//! Windows 上 WebView2 在同步命令或事件回调（托盘菜单、单实例唤起等）里新建窗口会卡死（窗口框出来了、页面一直白屏），
//! 所以新建主窗口 / 引导 / 悬浮窗一律交给后台任务做（`build_later`），调用方从哪里调都安全。

use std::collections::HashSet;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindow, WebviewWindowBuilder, WindowEvent};

use yybar_core::storage::settings::DockEdge;
use yybar_core::tr;

use crate::app_state::AppState;
use crate::tray::TrayState;

pub const POPOVER: &str = "popover";
pub const MAIN: &str = "main";
pub const FLOATING: &str = "floating";
pub const ONBOARDING: &str = "onboarding";

const POPOVER_GAP: f64 = 10.0;
const SNAP_THRESHOLD: f64 = 20.0;
/// 悬浮窗拖出屏幕左 / 右边缘超过窗口宽度的三分之一（至少这么多逻辑像素）时收起成贴边窄条。
/// 默认位置离右边只有 16 像素，阈值太小时轻轻碰一下就会收起来。
const COLLAPSE_OVERHANG: f64 = 40.0;
/// 拖完收起的窄条，离屏幕左 / 右边不超过这么远（逻辑像素）就重新贴边，拖得更远就在那里展开
const REDOCK_DISTANCE: f64 = 60.0;

/// 左键还按着（拖动还没结束）。
fn left_button_down() -> bool {
    #[cfg(windows)]
    {
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
        // 最高位为 1 表示按着
        (unsafe { GetAsyncKeyState(VK_LBUTTON as i32) } as u16 & 0x8000) != 0
    }
    #[cfg(not(windows))]
    {
        false
    }
}
const FLOATING_MARGIN: f64 = 16.0;

#[derive(Default)]
pub struct WindowState {
    /// 浮窗因失焦收起的时刻：点托盘图标会先让浮窗失焦，紧接着的这次点击不应再把它打开。
    popover_hidden_at: Mutex<Option<Instant>>,
    /// 悬浮窗拖动结束检测（最后一次移动的时刻）
    floating_moved_at: Mutex<Option<Instant>>,
    /// 主窗口要打开的部分（窗口还没建好时先记下，页面加载后来取）
    pub pending_tab: Mutex<Option<String>>,
    /// 正在后台新建的窗口（连点两下不会建出两个）
    building: Mutex<HashSet<&'static str>>,
}

/// 在后台任务里新建窗口（见文件头：避免 WebView2 在同步命令 / 事件回调里卡死）。同一个窗口正在建时忽略。
fn build_later(app: &AppHandle, label: &'static str, build: impl FnOnce(&AppHandle) + Send + 'static) {
    if !app.state::<WindowState>().building.lock().unwrap().insert(label) {
        return;
    }
    let h = app.clone();
    tauri::async_runtime::spawn(async move {
        if h.get_webview_window(label).is_none() {
            build(&h);
        }
        h.state::<WindowState>().building.lock().unwrap().remove(label);
    });
}

// ---------- 弹出浮窗 ----------

pub fn create_popover(app: &AppHandle) -> tauri::Result<()> {
    let window = WebviewWindowBuilder::new(app, POPOVER, WebviewUrl::App("popover.html".into()))
        .title("yybar")
        .inner_size(320.0, 360.0)
        .visible(false)
        .decorations(false)
        .transparent(true)
        .resizable(false)
        .skip_taskbar(true)
        .always_on_top(true)
        .shadow(true)
        .build()?;
    let h = app.clone();
    window.on_window_event(move |event| {
        if let WindowEvent::Focused(false) = event {
            if let Some(p) = h.get_webview_window(POPOVER) {
                if p.is_visible().unwrap_or(false) {
                    let _ = p.hide();
                    *h.state::<WindowState>().popover_hidden_at.lock().unwrap() = Some(Instant::now());
                }
            }
        }
    });
    apply_backdrop(&window);
    Ok(())
}

pub fn toggle_popover(app: &AppHandle) {
    let Some(popover) = app.get_webview_window(POPOVER) else { return };
    if popover.is_visible().unwrap_or(false) {
        let _ = popover.hide();
        return;
    }
    let just_hidden = app
        .state::<WindowState>()
        .popover_hidden_at
        .lock()
        .unwrap()
        .is_some_and(|t| t.elapsed() < Duration::from_millis(250));
    if just_hidden {
        return;
    }
    place_popover(app, &popover);
    let _ = popover.show();
    let _ = popover.set_focus();
    let _ = popover.emit("popover-shown", ());
}

pub fn hide_popover(app: &AppHandle) {
    if let Some(p) = app.get_webview_window(POPOVER) {
        let _ = p.hide();
    }
}

/// 托盘在下方时浮窗出现在图标正上方，任务栏在上方 / 侧边时相应翻转，并限制在屏幕工作区内。
fn place_popover(app: &AppHandle, popover: &WebviewWindow) {
    let Ok(size) = popover.outer_size() else { return };
    let anchor = *app.state::<TrayState>().anchor.lock().unwrap();
    let monitor = anchor
        .and_then(|r| {
            let p = r.position.to_physical::<f64>(1.0);
            popover.monitor_from_point(p.x, p.y).ok().flatten()
        })
        .or_else(|| popover.primary_monitor().ok().flatten());
    let Some(monitor) = monitor else { return };
    let scale = monitor.scale_factor();
    let work = monitor.work_area();
    let (wx, wy, ww, wh) = (work.position.x as f64, work.position.y as f64, work.size.width as f64, work.size.height as f64);
    let (pw, ph) = (size.width as f64, size.height as f64);
    let gap = POPOVER_GAP * scale;
    let (mut x, mut y) = match anchor {
        Some(r) => {
            let p = r.position.to_physical::<f64>(scale);
            let s = r.size.to_physical::<f64>(scale);
            let x = p.x + s.width / 2.0 - pw / 2.0;
            let y = if p.y > wy + wh / 2.0 { p.y - ph - gap } else { p.y + s.height + gap };
            (x, y)
        }
        None => (wx + ww - pw - gap, wy + wh - ph - gap),
    };
    x = x.clamp(wx + gap, (wx + ww - pw - gap).max(wx));
    y = y.clamp(wy + gap, (wy + wh - ph - gap).max(wy));
    let _ = popover.set_position(PhysicalPosition::new(x.round() as i32, y.round() as i32));
}

/// 前端量好内容高度后调用：浮窗刚好包住内容，并重新贴到托盘旁。
pub fn fit_popover(app: &AppHandle, height: f64) {
    let Some(p) = app.get_webview_window(POPOVER) else { return };
    let scale = p.scale_factor().unwrap_or(1.0);
    let Ok(size) = p.outer_size() else { return };
    let h = (height.clamp(120.0, 900.0) * scale).round() as u32;
    let w = (320.0 * scale).round() as u32;
    if size.height != h || size.width != w {
        let _ = p.set_size(PhysicalSize::new(w, h));
        if p.is_visible().unwrap_or(false) {
            place_popover(app, &p);
        }
    }
}

// ---------- 主窗口 ----------

/// 打开主窗口并定位到某部分（overview / quota / models / activity / services / display / refresh / general）。
pub fn open_main(app: &AppHandle, tab: Option<&str>) {
    hide_popover(app);
    if let Some(w) = app.get_webview_window(MAIN) {
        if let Some(tab) = tab {
            let _ = w.emit("navigate", tab);
        }
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
        return;
    }
    *app.state::<WindowState>().pending_tab.lock().unwrap() = tab.map(str::to_string);
    build_later(app, MAIN, |app| {
        let result = WebviewWindowBuilder::new(app, MAIN, WebviewUrl::App("main.html".into()))
            .title("yybar")
            .inner_size(1080.0, 720.0)
            .min_inner_size(760.0, 560.0)
            .center()
            .visible(true)
            .build();
        match result {
            Ok(w) => {
                let _ = w.set_zoom(app.state::<AppState>().settings().text_size.scale());
                let _ = w.set_focus();
            }
            Err(e) => log::warn!("open main window: {e}"),
        }
    });
}

// ---------- 引导 ----------

/// 设置 · 通用 · 字体大小：按倍数缩放主窗口网页（同浏览器缩放，布局跟着变）。
pub fn apply_text_size(app: &AppHandle) {
    if let Some(w) = app.get_webview_window(MAIN) {
        let _ = w.set_zoom(app.state::<AppState>().settings().text_size.scale());
    }
}

pub fn open_onboarding(app: &AppHandle) {
    if let Some(w) = app.get_webview_window(ONBOARDING) {
        let _ = w.show();
        let _ = w.set_focus();
        return;
    }
    build_later(app, ONBOARDING, |app| {
        let result = WebviewWindowBuilder::new(app, ONBOARDING, WebviewUrl::App("onboarding.html".into()))
            .title(tr("Welcome to yybar", "欢迎使用 yybar"))
            .inner_size(620.0, 520.0)
            .resizable(false)
            .maximizable(false)
            .minimizable(false)
            .center()
            .build();
        if let Err(e) = result {
            log::warn!("open onboarding: {e}");
        }
    });
}

pub fn close_onboarding(app: &AppHandle) {
    if let Some(w) = app.get_webview_window(ONBOARDING) {
        let _ = w.close();
    }
}

// ---------- 悬浮窗 ----------

/// 按设置显示 / 隐藏悬浮窗（对应 Mac `FloatingPanelController.sync()`）。
pub fn sync_floating(app: &AppHandle) {
    let enabled = app.state::<AppState>().settings().floating_enabled;
    match (enabled, app.get_webview_window(FLOATING)) {
        (true, Some(w)) => {
            let _ = w.show();
        }
        (true, None) => build_later(app, FLOATING, |app| {
            // 排队期间用户可能又关掉了悬浮窗
            if !app.state::<AppState>().settings().floating_enabled {
                return;
            }
            if let Err(e) = create_floating(app) {
                log::warn!("floating window: {e}");
            }
        }),
        (false, Some(w)) => {
            let _ = w.close();
        }
        (false, None) => {}
    }
}

fn create_floating(app: &AppHandle) -> tauri::Result<()> {
    let window = WebviewWindowBuilder::new(app, FLOATING, WebviewUrl::App("floating.html".into()))
        .title(tr("yybar floating window", "yybar 悬浮窗"))
        .inner_size(180.0, 60.0)
        .visible(false)
        .decorations(false)
        .transparent(true)
        .resizable(false)
        .skip_taskbar(true)
        .always_on_top(true)
        .shadow(false)
        .focused(false)
        .focusable(false)
        .build()?;
    place_floating(app, &window);
    let _ = window.show();
    let h = app.clone();
    window.on_window_event(move |event| {
        if let WindowEvent::Moved(_) = event {
            let started = Instant::now();
            *h.state::<WindowState>().floating_moved_at.lock().unwrap() = Some(started);
            let h2 = h.clone();
            // 拖动结束（250 毫秒没有新的移动，并且左键已经松开）后吸附 / 收起并记住位置。
            // 只看停顿的话，拖到一半停一下就会在手底下收起来。
            tauri::async_runtime::spawn(async move {
                tokio::time::sleep(Duration::from_millis(250)).await;
                while left_button_down() {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
                if *h2.state::<WindowState>().floating_moved_at.lock().unwrap() == Some(started) {
                    let h3 = h2.clone();
                    let _ = h2.run_on_main_thread(move || snap_and_persist(&h3));
                }
            });
        }
    });
    Ok(())
}

/// 存的位置还在某块屏幕上才用，否则回到主屏右上角。
fn place_floating(app: &AppHandle, window: &WebviewWindow) {
    let saved = app.state::<AppState>().settings().floating_position;
    if let Some((x, y)) = saved {
        if window.monitor_from_point(x as f64 + 8.0, y as f64 + 8.0).ok().flatten().is_some() {
            let _ = window.set_position(PhysicalPosition::new(x, y));
            return;
        }
    }
    let Some(monitor) = window.primary_monitor().ok().flatten() else { return };
    let work = monitor.work_area();
    let size = window.outer_size().unwrap_or(PhysicalSize::new(180, 60));
    let margin = (FLOATING_MARGIN * monitor.scale_factor()) as i32;
    let x = work.position.x + work.size.width as i32 - size.width as i32 - margin;
    let y = work.position.y + margin;
    let _ = window.set_position(PhysicalPosition::new(x, y));
}

/// 拖动结束：拖出屏幕左 / 右边缘超过 COLLAPSE_OVERHANG 时收起成贴边窄条（像微信通话小窗）；
/// 已收起时只能贴着左 / 右边上下移动（松手时靠近哪边贴哪边）；其余情况离屏幕边 20 像素内吸附。
fn snap_and_persist(app: &AppHandle) {
    let Some(w) = app.get_webview_window(FLOATING) else { return };
    let (Ok(pos), Ok(size)) = (w.outer_position(), w.outer_size()) else { return };
    let monitor = w
        .monitor_from_point(pos.x as f64 + size.width as f64 / 2.0, pos.y as f64 + size.height as f64 / 2.0)
        .ok()
        .flatten()
        .or_else(|| w.current_monitor().ok().flatten());
    let docked = app.state::<AppState>().settings().floating_dock;
    let mut dock = docked;
    let (mut x, mut y) = (pos.x, pos.y);
    if let Some(m) = monitor {
        let work = m.work_area();
        let t = (SNAP_THRESHOLD * m.scale_factor()) as i32;
        let overhang = (COLLAPSE_OVERHANG * m.scale_factor()).max(size.width as f64 / 3.0) as i32;
        let redock = (REDOCK_DISTANCE * m.scale_factor()) as i32;
        let (left, top) = (work.position.x, work.position.y);
        let work_right = left + work.size.width as i32;
        let right = work_right - size.width as i32;
        let bottom = top + work.size.height as i32 - size.height as i32;
        let center = x + size.width as i32 / 2;
        // 那一边接着另一块屏幕时是在换屏，不收
        let screen = m.position();
        let screen_right = screen.x + m.size().width as i32;
        let mid_y = (y + size.height as i32 / 2) as f64;
        let neighbor = |px: i32| w.monitor_from_point(px as f64, mid_y).ok().flatten().is_some_and(|n| n.position() != m.position());
        if docked.is_some() {
            // 拖动收起的窄条：放回屏幕边附近继续收着，拖远了就在那里展开
            dock = if center - left < redock {
                Some(DockEdge::Left)
            } else if work_right - center < redock {
                Some(DockEdge::Right)
            } else {
                None
            };
        } else if x < left - overhang && !neighbor(screen.x - 1) {
            dock = Some(DockEdge::Left);
        } else if x + size.width as i32 > work_right + overhang && !neighbor(screen_right + 1) {
            dock = Some(DockEdge::Right);
        }
        match dock {
            // 收起后窗口会按窄条重新量尺寸（fit_floating 贴边），这里先贴边、限制在屏幕上下之间
            Some(DockEdge::Left) => x = left,
            Some(DockEdge::Right) => x = right,
            // 窄条拖离了屏幕边：就地展开（展开后 fit_floating 按内容量尺寸）
            None if docked.is_some() => {}
            None => {
                if (x - left).abs() < t {
                    x = left;
                } else if (right - x).abs() < t {
                    x = right;
                }
            }
        }
        if dock.is_some() {
            y = y.clamp(top, bottom.max(top));
        } else if (y - top).abs() < t {
            y = top;
        } else if (bottom - y).abs() < t {
            y = bottom;
        }
        if (x, y) != (pos.x, pos.y) {
            *app.state::<WindowState>().floating_moved_at.lock().unwrap() = None;
            let _ = w.set_position(PhysicalPosition::new(x, y));
        }
    }
    {
        let state = app.state::<AppState>();
        let mut g = state.inner.lock().unwrap();
        g.settings.floating_position = Some((x, y));
        g.settings.floating_dock = dock;
        g.settings.save();
    }
    if dock != docked {
        crate::app_state::publish(app);
    }
}

/// 点收起的窄条：展开回原来的悬浮窗，仍贴着那条边（fit_floating 按贴边方向长）。
pub fn expand_floating(app: &AppHandle) {
    {
        let state = app.state::<AppState>();
        let mut g = state.inner.lock().unwrap();
        if g.settings.floating_dock.is_none() {
            return;
        }
        g.settings.floating_dock = None;
        g.settings.save();
    }
    crate::app_state::publish(app);
}

/// 悬浮窗大小跟随内容：收起时贴住那条边；展开时贴着屏幕左边就保持左边不动，否则保持右上角不动（默认贴在屏幕右上角）。
pub fn fit_floating(app: &AppHandle, width: f64, height: f64) {
    let Some(w) = app.get_webview_window(FLOATING) else { return };
    let scale = w.scale_factor().unwrap_or(1.0);
    let (Ok(size), Ok(pos)) = (w.outer_size(), w.outer_position()) else { return };
    let nw = (width.clamp(24.0, 640.0) * scale).round() as u32;
    let nh = (height.clamp(28.0, 600.0) * scale).round() as u32;
    if size.width == nw && size.height == nh {
        return;
    }
    let dock = app.state::<AppState>().settings().floating_dock;
    let work = w
        .monitor_from_point(pos.x as f64 + size.width as f64 / 2.0, pos.y as f64 + size.height as f64 / 2.0)
        .ok()
        .flatten()
        .or_else(|| w.current_monitor().ok().flatten())
        .map(|m| *m.work_area());
    let right = pos.x + size.width as i32;
    let x = match (dock, work) {
        (Some(DockEdge::Left), Some(a)) => a.position.x,
        (Some(DockEdge::Right), Some(a)) => a.position.x + a.size.width as i32 - nw as i32,
        (None, Some(a)) if pos.x <= a.position.x => pos.x,
        _ => right - nw as i32,
    };
    *app.state::<WindowState>().floating_moved_at.lock().unwrap() = None;
    let _ = w.set_size(PhysicalSize::new(nw, nh));
    let _ = w.set_position(PhysicalPosition::new(x, pos.y));
}

// ---------- 材质 ----------

/// Win11 用云母 / 亚克力背景，Win10 上退回不透明底色（前端按返回值决定）。
pub fn apply_backdrop(window: &WebviewWindow) -> &'static str {
    #[cfg(windows)]
    {
        if window_vibrancy::apply_mica(window, None).is_ok() {
            return "mica";
        }
        if window_vibrancy::apply_acrylic(window, None).is_ok() {
            return "acrylic";
        }
    }
    let _ = window;
    "none"
}
