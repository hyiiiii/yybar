mod core;
mod settings;
mod state;
mod tray_icon;

use std::sync::Mutex;
use std::time::{Duration, Instant};

use tauri::image::Image;
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, PhysicalPosition, PhysicalSize, Rect, WebviewWindow, WindowEvent};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt};

use crate::core::model::Snapshot;
use crate::settings::Settings;
use crate::state::AppState;

const TRAY_ID: &str = "yybar";
const PANEL: &str = "panel";
const PILL: &str = "pill";
/// 面板和托盘图标之间的间距（逻辑像素）
const PANEL_GAP: f64 = 10.0;

/// 托盘图标最近一次的位置（物理像素），面板贴着它弹出。
struct TrayAnchor(Mutex<Option<Rect>>);
/// 面板因失焦隐藏的时刻：点托盘图标会先让面板失焦，紧接着的这次点击不应再把它打开。
struct PanelHiddenAt(Mutex<Option<Instant>>);

// ---------- 托盘 ----------

pub fn update_tray(handle: &AppHandle) {
    let state = handle.state::<AppState>();
    let remaining = state.tightest_remaining();
    let Some(tray) = handle.tray_by_id(TRAY_ID) else { return };
    let rgba = tray_icon::render(remaining);
    let _ = tray.set_icon(Some(Image::new_owned(rgba, tray_icon::SIZE, tray_icon::SIZE)));
    let _ = tray.set_tooltip(Some(tooltip(&state.snapshot())));
}

fn tooltip(snap: &Snapshot) -> String {
    let mut lines = vec!["yybar".to_string()];
    for s in snap.services.iter().filter(|s| s.enabled) {
        let (Some(app), Some(q)) = (s.app, s.quota.as_ref()) else { continue };
        let mut parts = Vec::new();
        if let Some(w) = &q.five_hour {
            parts.push(format!("5H {:.0}%", w.remaining_percent()));
        }
        if let Some(w) = &q.weekly {
            parts.push(format!("周 {:.0}%", w.remaining_percent()));
        }
        if let Some(w) = &q.primary {
            parts.push(format!("{} {:.0}%", q.primary_label.as_deref().unwrap_or("周期"), w.remaining_percent()));
        }
        lines.push(format!("{} {}", app.display_name(), parts.join(" · ")));
    }
    lines.push(format!("今日 ${:.2}", snap.usage.today.cost_usd));
    // Windows 托盘提示最多 127 个字符
    lines.join("\n").chars().take(127).collect()
}

fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let settings = app.state::<AppState>().settings();
    let autostart = app.autolaunch().is_enabled().unwrap_or(false);
    let refresh = MenuItem::with_id(app, "refresh", "立即刷新", true, None::<&str>)?;
    let pill = CheckMenuItem::with_id(app, "pill", "显示悬浮条", true, settings.show_pill, None::<&str>)?;
    let auto = CheckMenuItem::with_id(app, "autostart", "开机启动", true, autostart, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "退出 yybar", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&refresh, &pill, &auto, &PredefinedMenuItem::separator(app)?, &quit])?;

    TrayIconBuilder::with_id(TRAY_ID)
        .icon(Image::new_owned(tray_icon::render(None), tray_icon::SIZE, tray_icon::SIZE))
        .tooltip("yybar")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(move |app, event| match event.id.as_ref() {
            "refresh" => refresh_now(app.clone()),
            "pill" => {
                let show = !app.state::<AppState>().settings().show_pill;
                let _ = pill.set_checked(show);
                set_pill_visible(app, show);
            }
            "autostart" => {
                let launcher = app.autolaunch();
                let enabled = launcher.is_enabled().unwrap_or(false);
                let _ = if enabled { launcher.disable() } else { launcher.enable() };
                let _ = auto.set_checked(launcher.is_enabled().unwrap_or(false));
            }
            "quit" => quit_app(app),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, rect, .. } = event {
                let app = tray.app_handle();
                *app.state::<TrayAnchor>().0.lock().unwrap() = Some(rect);
                toggle_panel(app);
            }
        })
        .build(app)?;
    Ok(())
}

// ---------- 弹出面板 ----------

fn toggle_panel(app: &AppHandle) {
    let Some(panel) = app.get_webview_window(PANEL) else { return };
    if panel.is_visible().unwrap_or(false) {
        let _ = panel.hide();
        return;
    }
    let just_hidden = app
        .state::<PanelHiddenAt>()
        .0
        .lock()
        .unwrap()
        .is_some_and(|t| t.elapsed() < Duration::from_millis(250));
    if just_hidden {
        return;
    }
    show_panel(app);
}

fn show_panel(app: &AppHandle) {
    let Some(panel) = app.get_webview_window(PANEL) else { return };
    place_panel(app, &panel);
    let _ = panel.show();
    let _ = panel.set_focus();
    refresh_now(app.clone());
}

/// 托盘在下方时面板出现在图标正上方，任务栏在上方 / 侧边时相应翻转，并限制在屏幕工作区内。
fn place_panel(app: &AppHandle, panel: &WebviewWindow) {
    let Ok(size) = panel.outer_size() else { return };
    let anchor = *app.state::<TrayAnchor>().0.lock().unwrap();
    let monitor = match anchor {
        Some(r) => {
            let p = r.position.to_physical::<f64>(1.0);
            panel.monitor_from_point(p.x, p.y).ok().flatten()
        }
        None => None,
    }
    .or_else(|| panel.primary_monitor().ok().flatten());
    let Some(monitor) = monitor else { return };
    let scale = monitor.scale_factor();
    let work = monitor.work_area();
    let (wx, wy) = (work.position.x as f64, work.position.y as f64);
    let (ww, wh) = (work.size.width as f64, work.size.height as f64);
    let (pw, ph) = (size.width as f64, size.height as f64);
    let gap = PANEL_GAP * scale;

    let (mut x, mut y) = match anchor {
        Some(r) => {
            let p = r.position.to_physical::<f64>(scale);
            let s = r.size.to_physical::<f64>(scale);
            let center_x = p.x + s.width / 2.0;
            let x = center_x - pw / 2.0;
            let y = if p.y > wy + wh / 2.0 { p.y - ph - gap } else { p.y + s.height + gap };
            (x, y)
        }
        // 没有托盘位置（比如被单实例唤起）：右下角
        None => (wx + ww - pw - gap, wy + wh - ph - gap),
    };
    x = x.clamp(wx + gap, (wx + ww - pw - gap).max(wx));
    y = y.clamp(wy + gap, (wy + wh - ph - gap).max(wy));
    let _ = panel.set_position(PhysicalPosition::new(x.round() as i32, y.round() as i32));
}

// ---------- 悬浮条 ----------

fn set_pill_visible(app: &AppHandle, show: bool) {
    {
        let state = app.state::<AppState>();
        let mut g = state.0.lock().unwrap();
        g.settings.show_pill = show;
        g.settings.save();
    }
    if let Some(pill) = app.get_webview_window(PILL) {
        if show {
            place_pill(app, &pill);
            let _ = pill.show();
        } else {
            let _ = pill.hide();
        }
    }
    state::publish(app);
}

fn place_pill(app: &AppHandle, pill: &WebviewWindow) {
    let saved = app.state::<AppState>().settings().pill_position;
    let Ok(size) = pill.outer_size() else { return };
    // 存的位置还落在某块屏幕上才用，否则（拔了副屏）回到主屏右下角
    if let Some((x, y)) = saved {
        if pill.monitor_from_point(x as f64 + 4.0, y as f64 + 4.0).ok().flatten().is_some() {
            let _ = pill.set_position(PhysicalPosition::new(x, y));
            return;
        }
    }
    let Some(monitor) = pill.primary_monitor().ok().flatten() else { return };
    let work = monitor.work_area();
    let gap = (12.0 * monitor.scale_factor()) as i32;
    let x = work.position.x + work.size.width as i32 - size.width as i32 - gap;
    let y = work.position.y + work.size.height as i32 - size.height as i32 - gap;
    let _ = pill.set_position(PhysicalPosition::new(x, y));
}

// ---------- 命令 ----------

fn refresh_now(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        state::refresh_quotas(&app, true).await;
    });
}

fn quit_app(app: &AppHandle) {
    let state = app.state::<AppState>();
    state.0.lock().unwrap().settings.save();
    app.exit(0);
}

#[tauri::command]
fn get_snapshot(state: tauri::State<AppState>) -> Snapshot {
    state.snapshot()
}

#[tauri::command]
fn refresh(app: AppHandle) {
    refresh_now(app);
}

#[tauri::command]
fn update_settings(app: AppHandle, settings: Settings) {
    let pill_changed;
    {
        let state = app.state::<AppState>();
        let mut g = state.0.lock().unwrap();
        pill_changed = g.settings.show_pill != settings.show_pill;
        // 悬浮条位置由拖动记录，前端传来的旧值不覆盖它
        let position = g.settings.pill_position;
        g.settings = Settings { pill_position: position, ..settings };
        g.settings.save();
        let current = g.settings.clone();
        for svc in g.services.iter_mut() {
            if let Some(a) = svc.app {
                svc.enabled = state::is_enabled(&current, a);
            }
        }
    }
    if pill_changed {
        let show = app.state::<AppState>().settings().show_pill;
        set_pill_visible(&app, show);
    } else {
        state::publish(&app);
    }
    refresh_now(app);
}

/// 前端量好内容高度后调用，让面板刚好包住内容，再重新贴到托盘旁边。
#[tauri::command]
fn fit_panel(app: AppHandle, height: f64) {
    let Some(panel) = app.get_webview_window(PANEL) else { return };
    let scale = panel.scale_factor().unwrap_or(1.0);
    let Ok(size) = panel.outer_size() else { return };
    let h = (height.clamp(120.0, 760.0) * scale).round() as u32;
    if size.height != h {
        let _ = panel.set_size(PhysicalSize::new(size.width, h));
        place_panel(&app, &panel);
    }
}

/// 悬浮条宽度随内容变化，右边缘不动。
#[tauri::command]
fn fit_pill(app: AppHandle, width: f64) {
    let Some(pill) = app.get_webview_window(PILL) else { return };
    let scale = pill.scale_factor().unwrap_or(1.0);
    let (Ok(size), Ok(pos)) = (pill.outer_size(), pill.outer_position()) else { return };
    let w = (width.clamp(80.0, 640.0) * scale).round() as u32;
    if size.width != w {
        let right = pos.x + size.width as i32;
        let _ = pill.set_size(PhysicalSize::new(w, size.height));
        let _ = pill.set_position(PhysicalPosition::new(right - w as i32, pos.y));
    }
}

#[tauri::command]
fn open_panel(app: AppHandle) {
    show_panel(&app);
}

#[tauri::command]
fn hide_panel(app: AppHandle) {
    if let Some(panel) = app.get_webview_window(PANEL) {
        let _ = panel.hide();
    }
}

#[tauri::command]
fn quit(app: AppHandle) {
    quit_app(&app);
}

#[tauri::command]
fn get_autostart(app: AppHandle) -> bool {
    app.autolaunch().is_enabled().unwrap_or(false)
}

#[tauri::command]
fn set_autostart(app: AppHandle, enabled: bool) -> bool {
    let launcher = app.autolaunch();
    let _ = if enabled { launcher.enable() } else { launcher.disable() };
    launcher.is_enabled().unwrap_or(false)
}

/// 面板是否用上了 Win11 的云母背景；不支持时前端改用不透明底色。
#[tauri::command]
fn backdrop(app: AppHandle) -> &'static str {
    let _ = &app;
    #[cfg(windows)]
    {
        if let Some(panel) = app.get_webview_window(PANEL) {
            if window_vibrancy::apply_mica(&panel, None).is_ok() {
                return "mica";
            }
        }
    }
    "none"
}

pub fn run() {
    let settings = Settings::load();
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| show_panel(app)))
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, None))
        .manage(AppState::new(settings))
        .manage(TrayAnchor(Mutex::new(None)))
        .manage(PanelHiddenAt(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![
            get_snapshot,
            refresh,
            update_settings,
            fit_panel,
            fit_pill,
            open_panel,
            hide_panel,
            quit,
            get_autostart,
            set_autostart,
            backdrop
        ])
        .setup(|app| {
            let handle = app.handle().clone();
            build_tray(&handle)?;
            if let Some(panel) = app.get_webview_window(PANEL) {
                let h = handle.clone();
                panel.on_window_event(move |event| {
                    if let WindowEvent::Focused(false) = event {
                        if let Some(p) = h.get_webview_window(PANEL) {
                            if p.is_visible().unwrap_or(false) {
                                let _ = p.hide();
                                *h.state::<PanelHiddenAt>().0.lock().unwrap() = Some(Instant::now());
                            }
                        }
                    }
                });
            }
            if let Some(pill) = app.get_webview_window(PILL) {
                let h = handle.clone();
                pill.on_window_event(move |event| {
                    if let WindowEvent::Moved(pos) = event {
                        let state = h.state::<AppState>();
                        let mut g = state.0.lock().unwrap();
                        g.settings.pill_position = Some((pos.x, pos.y));
                        g.settings_dirty = true;
                    }
                });
                if handle.state::<AppState>().settings().show_pill {
                    place_pill(&handle, &pill);
                    let _ = pill.show();
                }
            }
            state::spawn_loops(handle);
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building yybar")
        .run(|app, event| {
            // 关掉所有窗口也不退出：托盘常驻
            if let tauri::RunEvent::ExitRequested { api, code: None, .. } = event {
                api.prevent_exit();
            }
            let _ = app;
        });
}
