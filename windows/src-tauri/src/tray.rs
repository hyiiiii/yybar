//! 任务栏托盘（对应 Mac 菜单栏 `StatusItemController`）。
//!
//! - 每个勾选了「托盘」（Mac 的「菜单栏」列）的服务一个图标，顺序 Codex → Claude → Grok → Antigravity；
//!   一个都没勾时保留一个 yybar 图标，避免托盘完全消失。
//! - 左键：弹出额度浮窗（再点一次或点别处收起）。右键：立即刷新 / 打开统计 / 设置… / 退出 yybar。
//! - 悬停提示：服务名、5H / WK 剩余、今日花费。
//! - 使用中（会话日志 30 秒内有写入）数字和 logo 交替呼吸；等待审批时保持显示 logo；额度用完的服务不呼吸。

use std::collections::{BTreeSet, HashMap};
use std::sync::Mutex;
use std::time::Instant;

use tauri::image::Image;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, Rect};

use yybar_core::storage::settings::MenuBarWindow;
use yybar_core::usage::activity::ActivitySnapshot;
use yybar_core::{now_secs, tr, UsageApp};

use crate::app_state::{self, AppState};
use crate::tray_render;

const PLACEHOLDER: &str = "tray-yybar";
const BREATH_PERIOD: f32 = 1.6;

#[derive(Default)]
pub struct TrayState {
    /// 图标 id → 上次画的 (剩余整数, 呼吸相位档)，没变就不重画。
    drawn: Mutex<HashMap<String, (Option<i32>, u8)>>,
    tooltips: Mutex<HashMap<String, String>>,
    /// 最近一次点击的托盘图标位置（浮窗贴着它弹出）。
    pub anchor: Mutex<Option<Rect>>,
    ticker_running: Mutex<bool>,
    last_activity: Mutex<ActivitySnapshot>,
    started: Mutex<Option<Instant>>,
    language: Mutex<Option<bool>>,
}

fn tray_id(app: UsageApp) -> String {
    format!("tray-{}", app.key())
}

fn build_menu(handle: &AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    let refresh = MenuItem::with_id(handle, "refresh", tr("Refresh now", "立即刷新"), true, None::<&str>)?;
    let stats = MenuItem::with_id(handle, "stats", tr("Open Statistics", "打开统计"), true, None::<&str>)?;
    let settings = MenuItem::with_id(handle, "settings", tr("Settings…", "设置…"), true, None::<&str>)?;
    let quit = MenuItem::with_id(handle, "quit", tr("Quit yybar", "退出 yybar"), true, None::<&str>)?;
    Menu::with_items(handle, &[&refresh, &stats, &settings, &PredefinedMenuItem::separator(handle)?, &quit])
}

fn on_menu(handle: &AppHandle, id: &str) {
    match id {
        "refresh" => {
            let h = handle.clone();
            tauri::async_runtime::spawn(async move { app_state::refresh_now(&h).await });
        }
        "stats" => crate::windows::open_main(handle, Some("overview")),
        "settings" => crate::windows::open_main(handle, Some("services")),
        "quit" => crate::quit(handle),
        _ => {}
    }
}

fn create_icon(handle: &AppHandle, id: &str, image: Image<'static>) {
    let Ok(menu) = build_menu(handle) else { return };
    let result = TrayIconBuilder::with_id(id)
        .icon(image)
        .tooltip("yybar")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| on_menu(app, event.id.as_ref()))
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, rect, .. } = event {
                let app = tray.app_handle();
                *app.state::<TrayState>().anchor.lock().unwrap() = Some(rect);
                crate::windows::toggle_popover(app);
            }
        })
        .build(handle);
    if let Err(e) = result {
        log::warn!("tray icon {id}: {e}");
    }
}

fn placeholder_image() -> Image<'static> {
    Image::from_bytes(include_bytes!("../icons/32x32.png")).expect("tray placeholder icon")
}

/// 托盘上显示的那个数：Grok 取周期额度；其他按设置 5H / WK / 都显示（取剩余更少的那个）。
fn headline(snapshot: &yybar_core::quota::QuotaSnapshot, choice: MenuBarWindow) -> Option<f64> {
    if snapshot.app.has_single_period() {
        return snapshot.primary.as_ref().or(snapshot.weekly.as_ref()).map(|w| w.remaining_percent());
    }
    let five = snapshot.five_hour.as_ref().map(|w| w.remaining_percent());
    let week = snapshot.weekly.as_ref().map(|w| w.remaining_percent());
    match choice {
        MenuBarWindow::FiveHour => five.or(week),
        MenuBarWindow::Weekly => week.or(five),
        MenuBarWindow::Both => match (five, week) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        },
    }
}

fn tooltip(app: UsageApp, snapshot: Option<&yybar_core::quota::QuotaSnapshot>, today_cost: Option<f64>) -> String {
    let mut lines = vec![app.display_name().to_string()];
    if let Some(s) = snapshot {
        let mut parts = Vec::new();
        if app.has_single_period() {
            if let Some(w) = s.primary.as_ref() {
                parts.push(format!("WK {:.0}%", w.remaining_percent()));
            }
        } else if let Some(pools) = &s.pools {
            for p in pools {
                let five = p.five_hour.as_ref().map(|w| format!("5H {:.0}%", w.remaining_percent()));
                let week = p.weekly.as_ref().map(|w| format!("WK {:.0}%", w.remaining_percent()));
                let v: Vec<String> = [five, week].into_iter().flatten().collect();
                if !v.is_empty() {
                    lines.push(format!("{} {}", p.label, v.join(" · ")));
                }
            }
        } else {
            if let Some(w) = s.five_hour.as_ref() {
                parts.push(format!("5H {:.0}%", w.remaining_percent()));
            }
            if let Some(w) = s.weekly.as_ref() {
                parts.push(format!("WK {:.0}%", w.remaining_percent()));
            }
        }
        if !parts.is_empty() {
            lines.push(parts.join(" · "));
        }
    } else {
        lines.push(tr("Waiting for data", "等待数据"));
    }
    if let Some(cost) = today_cost {
        lines.push(format!("{} ${cost:.2}", tr("Today", "今日")));
    }
    // Windows 托盘提示最多 127 个字符
    lines.join("\n").chars().take(127).collect()
}

/// 状态变了（额度、设置、使用中）时调用：增删图标、重画数字。
pub fn update(handle: &AppHandle) {
    let tray = handle.state::<TrayState>();
    let state = handle.state::<AppState>();
    let (settings, entries) = {
        let g = state.inner.lock().unwrap();
        let entries: Vec<(UsageApp, Option<yybar_core::quota::QuotaSnapshot>)> = UsageApp::ALL
            .iter()
            .filter(|a| g.settings.tray_shows(**a) && !g.is_removed(**a))
            .map(|a| (*a, g.quota(*a)))
            .collect();
        (g.settings.clone(), entries)
    };
    // 语言变了：菜单文字要换，全部重建。
    let chinese = yybar_core::l10n::is_chinese();
    {
        let mut lang = tray.language.lock().unwrap();
        if lang.is_some_and(|l| l != chinese) {
            for id in tray.drawn.lock().unwrap().keys().cloned().collect::<Vec<_>>() {
                let _ = handle.remove_tray_by_id(&id);
            }
            tray.drawn.lock().unwrap().clear();
            tray.tooltips.lock().unwrap().clear();
        }
        *lang = Some(chinese);
    }

    let wanted: Vec<String> = if entries.is_empty() { vec![PLACEHOLDER.into()] } else { entries.iter().map(|(a, _)| tray_id(*a)).collect() };
    // 删掉不要的
    {
        let mut drawn = tray.drawn.lock().unwrap();
        let stale: Vec<String> = drawn.keys().filter(|k| !wanted.contains(k)).cloned().collect();
        for id in stale {
            let _ = handle.remove_tray_by_id(&id);
            drawn.remove(&id);
            tray.tooltips.lock().unwrap().remove(&id);
        }
    }
    if entries.is_empty() {
        let mut drawn = tray.drawn.lock().unwrap();
        if !drawn.contains_key(PLACEHOLDER) {
            create_icon(handle, PLACEHOLDER, placeholder_image());
            drawn.insert(PLACEHOLDER.into(), (None, 0));
            if let Some(t) = handle.tray_by_id(PLACEHOLDER) {
                let _ = t.set_tooltip(Some("yybar"));
            }
        }
        return;
    }

    let activity = state.activity.snapshot();
    let now = now_secs();
    let elapsed = tray.started.lock().unwrap().get_or_insert_with(Instant::now).elapsed().as_secs_f32();
    let breath = (1.0 - (std::f32::consts::TAU * elapsed / BREATH_PERIOD).cos()) / 2.0;
    let today = today_costs(&state);
    let mut breathing = false;
    for (app, snapshot) in &entries {
        let id = tray_id(*app);
        let remaining = snapshot.as_ref().and_then(|s| headline(s, settings.menu_bar_window));
        let exhausted = snapshot.as_ref().is_some_and(|s| s.is_exhausted(now));
        let phase = if settings.menu_bar_hold_color_while_waiting && activity.waiting.contains(app) {
            1.0
        } else if settings.menu_bar_breathe_when_active && activity.active.contains(app) && !exhausted {
            breathing = true;
            breath
        } else {
            0.0
        };
        let key = (remaining.map(|r| r.round() as i32), (phase * 12.0).round() as u8);
        let mut drawn = tray.drawn.lock().unwrap();
        let exists = drawn.contains_key(&id);
        if !exists || drawn.get(&id) != Some(&key) {
            let image = Image::new_owned(tray_render::render(*app, remaining, phase), tray_render::SIZE, tray_render::SIZE);
            if exists {
                if let Some(t) = handle.tray_by_id(&id) {
                    let _ = t.set_icon(Some(image));
                }
            } else {
                create_icon(handle, &id, image);
            }
            drawn.insert(id.clone(), key);
        }
        drop(drawn);
        let tip = tooltip(*app, snapshot.as_ref(), today.get(app).copied());
        let mut tips = tray.tooltips.lock().unwrap();
        if tips.get(&id) != Some(&tip) {
            if let Some(t) = handle.tray_by_id(&id) {
                let _ = t.set_tooltip(Some(&tip));
            }
            tips.insert(id, tip);
        }
    }
    if breathing || state.activity.needs_ticking() {
        ensure_ticker(handle);
    }
}

/// 今日花费（只算有价格的部分；Grok 费用来自日志）。
fn today_costs(state: &AppState) -> HashMap<UsageApp, f64> {
    let today = chrono::Local::now().date_naive();
    let mut out = HashMap::new();
    for b in state.usage.lock().unwrap().buckets().iter().filter(|b| b.day == today) {
        *out.entry(b.app).or_insert(0.0) += b.cost_usd;
    }
    out
}

/// 日志写入（监听线程）→ 立即重画，并在有活动时保持节拍。
pub fn activity_changed(handle: &AppHandle) {
    let h = handle.clone();
    let _ = handle.run_on_main_thread(move || {
        update(&h);
        publish_if_activity_changed(&h);
    });
}

fn publish_if_activity_changed(handle: &AppHandle) {
    let snap = handle.state::<AppState>().activity.snapshot();
    let tray = handle.state::<TrayState>();
    let mut last = tray.last_activity.lock().unwrap();
    if *last != snap {
        *last = snap;
        drop(last);
        app_state::publish(handle);
    }
}

/// 有服务在呼吸时每 100 毫秒重画一次；只需要等「使用中」过期时每秒检查一次；都没有就停。
fn ensure_ticker(handle: &AppHandle) {
    let tray = handle.state::<TrayState>();
    let mut running = tray.ticker_running.lock().unwrap();
    if *running {
        return;
    }
    *running = true;
    let h = handle.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            let (breathing, needs) = {
                let state = h.state::<AppState>();
                let settings = state.settings();
                let snap = state.activity.snapshot();
                let shown: BTreeSet<UsageApp> = UsageApp::ALL.into_iter().filter(|a| settings.tray_shows(*a)).collect();
                (settings.menu_bar_breathe_when_active && snap.active.iter().any(|a| shown.contains(a)), state.activity.needs_ticking())
            };
            if !breathing && !needs {
                let h2 = h.clone();
                let _ = h.run_on_main_thread(move || {
                    update(&h2);
                    publish_if_activity_changed(&h2);
                });
                *h.state::<TrayState>().ticker_running.lock().unwrap() = false;
                return;
            }
            let h2 = h.clone();
            let _ = h.run_on_main_thread(move || {
                update(&h2);
                publish_if_activity_changed(&h2);
            });
            tokio::time::sleep(std::time::Duration::from_millis(if breathing { 100 } else { 1000 })).await;
        }
    });
}
