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
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
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
/// 悬浮窗松手时离屏幕上 / 下边缘小于这么多（逻辑像素）就吸附过去
const SNAP_THRESHOLD: f64 = 20.0;
/// 悬浮窗松手时离屏幕左 / 右边缘不到这么远（逻辑像素，或已经伸出边外）就收起成贴边窄条（像微信通话小窗）
const DOCK_DISTANCE: f64 = 24.0;
/// 拖完收起的窄条，离屏幕左 / 右边不超过这么远（逻辑像素）就重新贴边，拖得更远就在那里展开
const REDOCK_DISTANCE: f64 = 60.0;
/// 收起的窄条宽度（逻辑像素，和 floating.css 的 .hud.collapsed 一致）
const TAB_WIDTH: f64 = 30.0;
/// 滑入 / 滑出屏幕边的动画：帧数 × 每帧间隔 ≈ 220 毫秒
const SLIDE_FRAMES: u32 = 14;
const SLIDE_FRAME_MS: u64 = 16;

/// 按下后移动超过这么多（逻辑像素）才算拖动（和 Mac FloatingMouseView 一样）
const DRAG_THRESHOLD: f64 = 3.0;

/// 一次改完窗口的位置和尺寸（物理像素）。分成 set_size + set_position 两步时，中间那一帧窗口可能整个在屏幕外
/// （比如收在左边：先缩成窄条宽，那时还在「只露一条」的位置），看着就是闪一下。
fn set_frame(w: &WebviewWindow, x: i32, y: i32, width: u32, height: u32) {
    #[cfg(windows)]
    {
        use windows_sys::Win32::UI::WindowsAndMessaging::{SetWindowPos, SWP_NOACTIVATE, SWP_NOZORDER};
        if let Ok(hwnd) = w.hwnd() {
            unsafe { SetWindowPos(hwnd.0 as _, std::ptr::null_mut(), x, y, width as i32, height as i32, SWP_NOZORDER | SWP_NOACTIVATE) };
            return;
        }
    }
    let _ = w.set_size(PhysicalSize::new(width, height));
    let _ = w.set_position(PhysicalPosition::new(x, y));
}

/// 左键还按着。只在 Windows 上查得到；其他平台（开发时）一律当按着，松手只靠前端报。
fn left_button_down() -> bool {
    #[cfg(windows)]
    {
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
        // 最高位为 1 表示按着
        (unsafe { GetAsyncKeyState(VK_LBUTTON as i32) } as u16 & 0x8000) != 0
    }
    #[cfg(not(windows))]
    {
        true
    }
}
const FLOATING_MARGIN: f64 = 16.0;

#[derive(Default)]
pub struct WindowState {
    /// 浮窗因失焦收起的时刻：点托盘图标会先让浮窗失焦，紧接着的这次点击不应再把它打开。
    popover_hidden_at: Mutex<Option<Instant>>,
    /// 主窗口要打开的部分（窗口还没建好时先记下，页面加载后来取）
    pub pending_tab: Mutex<Option<String>>,
    /// 正在后台新建的窗口（连点两下不会建出两个）
    building: Mutex<HashSet<&'static str>>,
    /// 刚点了展开：等前端换成展开的内容、量好尺寸后（fit_floating），从这条边滑出来
    floating_slide_out: Mutex<Option<DockEdge>>,
    /// 悬浮窗正在滑入 / 滑出（期间按下不理）
    floating_sliding: AtomicBool,
    /// 悬浮窗上按着的这一下（松手时取走）
    floating_press: Mutex<Option<FloatingPress>>,
    floating_press_seq: AtomicU64,
    /// 上次展开时的窗口尺寸：点窄条展开时先把窗口摆成这个尺寸、放在只露一条的位置，再换内容、滑出来，
    /// 不等前端量尺寸（换内容和挪窗口分两步时，中间会有一两帧对不上，看着像闪一下）
    floating_expanded_size: Mutex<Option<PhysicalSize<u32>>>,
    /// 滑动中前端报上来的尺寸：滑完再用（滑动时改尺寸、位置会和动画打架）
    floating_pending_fit: Mutex<Option<(f64, f64)>>,
    /// 还不知道展开尺寸时（收着重启过）从左边拉出窄条就地展开：下一次量尺寸往右长（保持左边不动）
    floating_grow_right: AtomicBool,
}

/// 按下悬浮窗时的鼠标和窗口位置（物理像素），和这一下有没有拖动过。
struct FloatingPress {
    id: u64,
    cursor: PhysicalPosition<f64>,
    origin: PhysicalPosition<i32>,
    dragging: bool,
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

/// 前端在悬浮窗（展开的或收起的窄条）上按下左键：记下鼠标和窗口位置（物理像素），之后按着的时候每帧跟一次鼠标，
/// 移动超过 3 像素才算拖动、窗口跟着鼠标走（可以推出屏幕边）——对应 Mac `FloatingMouseView`。
/// 不再交给系统拖、松手后再看位置：那样分不清单击和拖动，动画中再按一下还会被当成拖动、又收回去。
/// 跟鼠标靠后台每帧查一次光标，不靠网页的 mousemove（窗口跟着光标动时可能收不到）。
/// 松手：前端报上来（floating_release），或后台看到左键已经松开（在窗口外松手等），先到的算。
/// 滑入 / 滑出动画进行中按下的不理（对应 Mac 的 `animating`）。
pub fn floating_press(app: &AppHandle) {
    let ws = app.state::<WindowState>();
    let id = ws.floating_press_seq.fetch_add(1, Ordering::SeqCst) + 1;
    {
        let mut press = ws.floating_press.lock().unwrap();
        *press = None;
        if ws.floating_sliding.load(Ordering::SeqCst) {
            return;
        }
        let Some(w) = app.get_webview_window(FLOATING) else { return };
        let (Ok(cursor), Ok(origin)) = (app.cursor_position(), w.outer_position()) else { return };
        *press = Some(FloatingPress { id, cursor, origin, dragging: false });
    }
    let h = app.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_millis(SLIDE_FRAME_MS)).await;
            let pressing = h.state::<WindowState>().floating_press.lock().unwrap().as_ref().is_some_and(|p| p.id == id);
            if !pressing {
                break;
            }
            let h2 = h.clone();
            let _ = h.run_on_main_thread(move || {
                if left_button_down() {
                    let ws = h2.state::<WindowState>();
                    let mut press = ws.floating_press.lock().unwrap();
                    if let Some(press) = press.as_mut().filter(|p| p.id == id) {
                        follow_cursor(&h2, press);
                    }
                } else {
                    finish_press(&h2, Some(id));
                }
            });
        }
    });
}

fn follow_cursor(app: &AppHandle, press: &mut FloatingPress) {
    let (Some(w), Ok(cursor)) = (app.get_webview_window(FLOATING), app.cursor_position()) else { return };
    let (dx, dy) = (cursor.x - press.cursor.x, cursor.y - press.cursor.y);
    if !press.dragging {
        if dx.hypot(dy) < DRAG_THRESHOLD * w.scale_factor().unwrap_or(1.0) {
            return;
        }
        press.dragging = true;
    }
    let _ = w.set_position(PhysicalPosition::new(press.origin.x + dx.round() as i32, press.origin.y + dy.round() as i32));
}

/// 前端报松手。
pub fn floating_release(app: &AppHandle) {
    finish_press(app, None);
}

/// 松手（对应 Mac `FloatingPanelController.mouseReleased`）：拖动过 → 吸附 / 收起 / 贴回边 / 就地展开（snap_and_persist）；
/// 没拖动 → 收起的窄条上就是单击，从边上滑出展开（展开时单击什么也不做）。`only` 给了就只收这一次按下。
fn finish_press(app: &AppHandle, only: Option<u64>) {
    let ws = app.state::<WindowState>();
    let press = {
        let mut slot = ws.floating_press.lock().unwrap();
        if only.is_some_and(|id| slot.as_ref().map(|p| p.id) != Some(id)) {
            return;
        }
        slot.take()
    };
    let Some(press) = press else { return };
    if ws.floating_sliding.load(Ordering::SeqCst) {
        return;
    }
    // 不在这里再跟一次光标：处理松手时光标可能已经移走了，窗口会被带过去（最多差一帧，看不出来）
    if press.dragging {
        snap_and_persist(app);
    } else {
        expand_floating(app);
    }
}

/// 悬浮窗滑动到 to_x（保持 y），每帧在主线程挪一次窗口；动完在主线程执行 then。
fn slide_floating(app: &AppHandle, from_x: i32, to_x: i32, y: i32, then: Option<Box<dyn FnOnce(&AppHandle) + Send>>) {
    let ws = app.state::<WindowState>();
    ws.floating_sliding.store(true, Ordering::SeqCst);
    let h = app.clone();
    tauri::async_runtime::spawn(async move {
        for i in 1..=SLIDE_FRAMES {
            let t = i as f64 / SLIDE_FRAMES as f64;
            let eased = t * t * (3.0 - 2.0 * t);
            let x = from_x + ((to_x - from_x) as f64 * eased).round() as i32;
            let h2 = h.clone();
            let _ = h.run_on_main_thread(move || {
                if let Some(w) = h2.get_webview_window(FLOATING) {
                    let _ = w.set_position(PhysicalPosition::new(x, y));
                }
            });
            tokio::time::sleep(Duration::from_millis(SLIDE_FRAME_MS)).await;
        }
        h.state::<WindowState>().floating_sliding.store(false, Ordering::SeqCst);
        let pending = h.state::<WindowState>().floating_pending_fit.lock().unwrap().take();
        if let Some((width, height)) = pending {
            let h2 = h.clone();
            let _ = h.run_on_main_thread(move || fit_floating(&h2, width, height));
        }
        if let Some(then) = then {
            let h2 = h.clone();
            let _ = h.run_on_main_thread(move || then(&h2));
        }
    });
}

fn save_floating(app: &AppHandle, position: (i32, i32), dock: Option<DockEdge>) -> bool {
    let state = app.state::<AppState>();
    let mut g = state.inner.lock().unwrap();
    let changed = g.settings.floating_dock != dock;
    g.settings.floating_position = Some(position);
    g.settings.floating_dock = dock;
    g.settings.save();
    changed
}

/// 拖动结束：
/// - 展开时：离屏幕左 / 右边不到 24 像素或伸出边外 → 整块滑进屏幕边、换成窄条（那一边接着另一块屏幕时只贴边）；
///   离上 / 下边 20 像素内吸附。
/// - 收起时：放回屏幕边附近 → 滑回去贴好；拖远了就地展开。
fn snap_and_persist(app: &AppHandle) {
    let Some(w) = app.get_webview_window(FLOATING) else { return };
    let (Ok(pos), Ok(size)) = (w.outer_position(), w.outer_size()) else { return };
    let Some(m) = w
        .monitor_from_point(pos.x as f64 + size.width as f64 / 2.0, pos.y as f64 + size.height as f64 / 2.0)
        .ok()
        .flatten()
        .or_else(|| w.current_monitor().ok().flatten())
    else {
        return;
    };
    let docked = app.state::<AppState>().settings().floating_dock;
    let scale = m.scale_factor();
    let work = m.work_area();
    let (left, top) = (work.position.x, work.position.y);
    let work_right = left + work.size.width as i32;
    let bottom = top + work.size.height as i32 - size.height as i32;
    let width = size.width as i32;
    let tab = (TAB_WIDTH * scale).round() as i32;
    let y = pos.y.clamp(top, bottom.max(top));

    if docked.is_some() {
        let redock = (REDOCK_DISTANCE * scale) as i32;
        let center = pos.x + width / 2;
        let edge = if center - left < redock {
            Some(DockEdge::Left)
        } else if work_right - center < redock {
            Some(DockEdge::Right)
        } else {
            None
        };
        match edge {
            Some(edge) => {
                // 放回屏幕边：滑回去贴好
                let to = if edge == DockEdge::Left { left } else { work_right - width };
                save_floating(app, (to, y), Some(edge));
                slide_floating(app, pos.x, to, y, None);
            }
            None => {
                // 拖离了屏幕边：就地展开。先摆成上次展开的尺寸（再由 fit_floating 按内容微调），整块留在屏幕里：
                // 从左边拉出来的往右长，从右边拉出来的往左长（以前一律保持右边不动，从左边拉出来的会伸出屏幕、也不再收进去）
                let known = *app.state::<WindowState>().floating_expanded_size.lock().unwrap();
                if known.is_none() && docked == Some(DockEdge::Left) {
                    app.state::<WindowState>().floating_grow_right.store(true, Ordering::SeqCst);
                }
                let full = known.unwrap_or(size);
                let x = if docked == Some(DockEdge::Left) { pos.x } else { pos.x + width - full.width as i32 };
                let x = x.clamp(left, (work_right - full.width as i32).max(left));
                let y = pos.y.clamp(top, (top + work.size.height as i32 - full.height as i32).max(top));
                set_frame(&w, x, y, full.width, full.height);
                save_floating(app, (x, y), None);
                crate::app_state::publish(app);
            }
        }
        return;
    }

    let dock_distance = (DOCK_DISTANCE * scale) as i32;
    let screen = m.position();
    let screen_right = screen.x + m.size().width as i32;
    let mid_y = (pos.y + size.height as i32 / 2) as f64;
    let neighbor = |px: i32| w.monitor_from_point(px as f64, mid_y).ok().flatten().is_some_and(|n| n.position() != m.position());
    let near_left = pos.x < left + dock_distance;
    let near_right = pos.x + width > work_right - dock_distance;
    let mut x = pos.x;
    if near_left || near_right {
        let edge = if near_left && near_right {
            if pos.x + width / 2 < left + work.size.width as i32 / 2 { DockEdge::Left } else { DockEdge::Right }
        } else if near_left {
            DockEdge::Left
        } else {
            DockEdge::Right
        };
        let has_neighbor = if edge == DockEdge::Left { neighbor(screen.x - 1) } else { neighbor(screen_right + 1) };
        if !has_neighbor {
            *app.state::<WindowState>().floating_expanded_size.lock().unwrap() = Some(size);
            // 整块滑进屏幕边，只露出一条，再换成窄条（fit_floating 把窄条贴在同一位置）
            let tucked = if edge == DockEdge::Left { left - width + tab } else { work_right - tab };
            let edge_pos = if edge == DockEdge::Left { left } else { work_right - tab };
            slide_floating(
                app,
                pos.x,
                tucked,
                y,
                Some(Box::new(move |app: &AppHandle| {
                    if save_floating(app, (edge_pos, y), Some(edge)) {
                        crate::app_state::publish(app);
                    }
                })),
            );
            return;
        }
        x = if edge == DockEdge::Left { left } else { work_right - width };
    }
    let t = (SNAP_THRESHOLD * scale) as i32;
    let snapped_y = if (pos.y - top).abs() < t {
        top
    } else if (bottom - pos.y).abs() < t {
        bottom
    } else {
        y
    };
    save_floating(app, (x, snapped_y), None);
    if (x, snapped_y) != (pos.x, pos.y) {
        let _ = w.set_position(PhysicalPosition::new(x, snapped_y));
    }
}

/// 点收起的窄条：换回展开的内容，从那条边滑出来。
/// 量过展开的尺寸时：先把窗口摆成那个尺寸、放在只露一条的位置（这时还是窄条的内容，窄条贴着露出来的那一侧），
/// 再换内容，下一帧开始滑。没量过（收着重启过）就等 fit_floating 量到尺寸再滑。
pub fn expand_floating(app: &AppHandle) {
    let edge = {
        let state = app.state::<AppState>();
        let mut g = state.inner.lock().unwrap();
        let Some(edge) = g.settings.floating_dock else { return };
        g.settings.floating_dock = None;
        g.settings.save();
        edge
    };
    let ws = app.state::<WindowState>();
    let size = *ws.floating_expanded_size.lock().unwrap();
    let w = app.get_webview_window(FLOATING);
    let placed = (|| {
        let (size, w) = (size?, w.as_ref()?);
        let (pos, cur) = (w.outer_position().ok()?, w.outer_size().ok()?);
        let m = w
            .monitor_from_point(pos.x as f64 + cur.width as f64 / 2.0, pos.y as f64 + cur.height as f64 / 2.0)
            .ok()
            .flatten()
            .or_else(|| w.current_monitor().ok().flatten())?;
        let a = m.work_area();
        let tab = (TAB_WIDTH * m.scale_factor()).round() as i32;
        let (left, right) = (a.position.x, a.position.x + a.size.width as i32);
        let (from, to) = if edge == DockEdge::Left { (left - size.width as i32 + tab, left) } else { (right - tab, right - size.width as i32) };
        set_frame(w, from, pos.y, size.width, size.height);
        Some((from, to, pos.y))
    })();
    match placed {
        Some((from, to, y)) => {
            // 动画从现在就算开始：按下不理、前端报的尺寸滑完再用
            ws.floating_sliding.store(true, Ordering::SeqCst);
            crate::app_state::publish(app);
            let h = app.clone();
            tauri::async_runtime::spawn(async move {
                tokio::time::sleep(Duration::from_millis(40)).await;
                let h2 = h.clone();
                let _ = h.run_on_main_thread(move || {
                    slide_floating(&h2, from, to, y, Some(Box::new(move |app: &AppHandle| {
                        save_floating(app, (to, y), None);
                    })));
                });
            });
        }
        None => {
            *ws.floating_slide_out.lock().unwrap() = Some(edge);
            crate::app_state::publish(app);
        }
    }
}

/// 悬浮窗大小跟随内容：收起时贴住那条边；刚点了展开时先摆在「只露出一条」的位置再滑出来；
/// 其余展开时贴着屏幕左边就保持左边不动，否则保持右上角不动（默认贴在屏幕右上角）。
pub fn fit_floating(app: &AppHandle, width: f64, height: f64) {
    let Some(w) = app.get_webview_window(FLOATING) else { return };
    let ws = app.state::<WindowState>();
    if ws.floating_sliding.load(Ordering::SeqCst) {
        *ws.floating_pending_fit.lock().unwrap() = Some((width, height));
        return;
    }
    let scale = w.scale_factor().unwrap_or(1.0);
    let (Ok(size), Ok(pos)) = (w.outer_size(), w.outer_position()) else { return };
    let nw = (width.clamp(24.0, 640.0) * scale).round() as u32;
    let nh = (height.clamp(28.0, 600.0) * scale).round() as u32;
    if size.width == nw && size.height == nh {
        return;
    }
    let dock = app.state::<AppState>().settings().floating_dock;
    if dock.is_none() && nw as f64 > (TAB_WIDTH + 10.0) * scale {
        *ws.floating_expanded_size.lock().unwrap() = Some(PhysicalSize::new(nw, nh));
    }
    let work = w
        .monitor_from_point(pos.x as f64 + size.width as f64 / 2.0, pos.y as f64 + size.height as f64 / 2.0)
        .ok()
        .flatten()
        .or_else(|| w.current_monitor().ok().flatten())
        .map(|m| *m.work_area());
    // 刚点了展开：内容已经换成展开的（比窄条宽）才开始滑
    let slide = if dock.is_none() && nw as f64 > (TAB_WIDTH + 10.0) * scale {
        app.state::<WindowState>().floating_slide_out.lock().unwrap().take()
    } else {
        None
    };
    if let (Some(edge), Some(a)) = (slide, work) {
        let tab = (TAB_WIDTH * scale).round() as i32;
        let (left, right) = (a.position.x, a.position.x + a.size.width as i32);
        let (from, to) = if edge == DockEdge::Left { (left - nw as i32 + tab, left) } else { (right - tab, right - nw as i32) };
        set_frame(&w, from, pos.y, nw, nh);
        slide_floating(
            app,
            from,
            to,
            pos.y,
            Some(Box::new(move |app: &AppHandle| {
                save_floating(app, (to, pos.y), None);
            })),
        );
        return;
    }
    let right = pos.x + size.width as i32;
    let x = match (dock, work) {
        (Some(DockEdge::Left), Some(a)) => a.position.x,
        (Some(DockEdge::Right), Some(a)) => a.position.x + a.size.width as i32 - nw as i32,
        // 展开时整块留在屏幕里（贴着左边就保持左边不动，否则保持右边不动）
        (None, Some(a)) => {
            let grow_right = ws.floating_grow_right.swap(false, Ordering::SeqCst);
            let x = if pos.x <= a.position.x || grow_right { pos.x } else { right - nw as i32 };
            x.clamp(a.position.x, (a.position.x + a.size.width as i32 - nw as i32).max(a.position.x))
        }
        _ => right - nw as i32,
    };
    set_frame(&w, x, pos.y, nw, nh);
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
