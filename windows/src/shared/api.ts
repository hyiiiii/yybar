// 调后台命令、订阅 state / usage 事件。在浏览器里直接打开页面（不在 Tauri 里）时用演示数据，方便调样式。

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useEffect, useState } from "react";
import { demoState, demoUsage } from "./demo";
import { setChinese } from "./l10n";
import type { LoginView, ModelPrice, Provider, Settings, StateSnapshot, UsageApp, UsagePayload } from "./types";

export const inTauri = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

const call = <T,>(cmd: string, args?: Record<string, unknown>): Promise<T | undefined> =>
  inTauri ? invoke<T>(cmd, args) : Promise.resolve(undefined);

let demo: StateSnapshot | null = null;
const demoListeners = new Set<(s: StateSnapshot) => void>();

function applyDemoSettings(patch: Partial<Settings>) {
  if (!demo) return;
  demo = { ...demo, settings: { ...demo.settings, ...patch } };
  if (patch.appLanguage) demo.chinese = patch.appLanguage !== "en";
  demoListeners.forEach((l) => l(demo!));
}

function applyDemoOther(id: string, patch: Record<string, unknown>) {
  if (!demo) return;
  demo = { ...demo, others: demo.others.map((o) => (o.id === id ? { ...o, ...patch } : o)) };
  demoListeners.forEach((l) => l(demo!));
}

/** 全局状态（额度、设置、刷新状态、今日额度变化……），后台有变化就推过来。 */
export function useAppState(): StateSnapshot | null {
  const [state, setState] = useState<StateSnapshot | null>(() => {
    if (inTauri) return null;
    demo = demo ?? demoState();
    setChinese(demo.chinese);
    return demo;
  });
  useEffect(() => {
    if (!inTauri) {
      const l = (s: StateSnapshot) => {
        setChinese(s.chinese);
        setState(s);
      };
      demoListeners.add(l);
      return () => void demoListeners.delete(l);
    }
    let unlisten: (() => void) | undefined;
    let alive = true;
    const apply = (s: StateSnapshot) => {
      setChinese(s.chinese);
      setState(s);
    };
    invoke<StateSnapshot>("get_state").then((s) => alive && apply(s));
    listen<StateSnapshot>("state", (e) => apply(e.payload)).then((u) => {
      if (alive) unlisten = u;
      else u();
    });
    return () => {
      alive = false;
      unlisten?.();
    };
  }, []);
  return state;
}

/** 本地用量聚合桶。数据版本变了才重新拉。 */
export function useUsage(): UsagePayload | null {
  const [usage, setUsage] = useState<UsagePayload | null>(() => (inTauri ? null : demoUsage()));
  useEffect(() => {
    if (!inTauri) return;
    let alive = true;
    let unlisten: (() => void) | undefined;
    let current = -1;
    const load = () =>
      invoke<UsagePayload>("get_usage").then((u) => {
        if (alive && u.version !== current) {
          current = u.version;
          setUsage(u);
        }
      });
    load();
    listen<number>("usage", (e) => {
      if (e.payload !== current) load();
    }).then((u) => {
      if (alive) unlisten = u;
      else u();
    });
    return () => {
      alive = false;
      unlisten?.();
    };
  }, []);
  return usage;
}

/** 每 `ms` 毫秒重画一次，让「x 前更新」「x 后重置」走起来。 */
export function useTicker(ms = 1000): number {
  const [now, setNow] = useState(Date.now() / 1000);
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now() / 1000), ms);
    return () => clearInterval(t);
  }, [ms]);
  return now;
}

/** 监听后台事件。 */
export function useEvent<T>(name: string, handler: (payload: T) => void) {
  useEffect(() => {
    if (!inTauri) return;
    let unlisten: (() => void) | undefined;
    let alive = true;
    listen<T>(name, (e) => handler(e.payload)).then((u) => {
      if (alive) unlisten = u;
      else u();
    });
    return () => {
      alive = false;
      unlisten?.();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [name]);
}

export const api = {
  refreshNow: () => call("refresh_now"),
  updateSettings: (patch: Partial<Settings>) => (inTauri ? call("update_settings", { patch }) : Promise.resolve(applyDemoSettings(patch))),
  setAutostart: (enabled: boolean) => call<boolean>("set_autostart", { enabled }),
  setCustomPrice: (key: string, price: ModelPrice | null) => call("set_custom_price", { key, price }),
  removeLocalAccount: (service: UsageApp) => call("remove_local_account", { service }),
  restoreRemovedAccounts: () => call("restore_removed_accounts"),
  // 其他账号（添加 / 登录 / 切换）
  addAccountPaste: (provider: Provider, text: string) => call<string>("add_account_paste", { provider, text }),
  loginStart: (provider: Provider) => call<LoginView>("login_start", { provider }),
  loginSubmitCode: (id: string, code: string) => call("login_submit_code", { id, code }),
  loginCancel: (id: string) => call("login_cancel", { id }),
  googleLoginStart: () => call<string>("google_login_start"),
  googleLoginReopen: (folder: string) => call("google_login_reopen", { folder }),
  googleLoginFinish: (folder: string) => call<string>("google_login_finish", { folder }),
  googleLoginCancel: (folder: string) => call("google_login_cancel", { folder }),
  updateOtherAccount: (id: string, patch: { alias?: string; enabled?: boolean; showInTray?: boolean; showInFloating?: boolean }) =>
    inTauri ? call("update_other_account", { id, patch }) : Promise.resolve(applyDemoOther(id, patch)),
  removeOtherAccount: (id: string) => call("remove_other_account", { id }),
  /** 切换本机 CLI 到这个账号；Codex 给了 home 就切进那个 Codex 目录（其他 Codex 目录），否则切进主目录 */
  switchAccount: (id: string, home?: string | null) => call("switch_account", { id, home: home ?? null }),
  /** 系统的选择文件夹对话框（取消时为 null） */
  pickFolder: (title: string) => (inTauri ? call<string | null>("pick_folder", { title }) : Promise.resolve(null)),
  // bar：yybar 网站
  webConnect: () => call("web_connect"),
  webCancelConnect: () => call("web_cancel_connect"),
  webDisconnect: () => call("web_disconnect"),
  webUploadNow: () => call("web_upload_now"),
  openSite: () => (inTauri ? call("open_site") : Promise.resolve(void window.open("https://yybar-web.hyi030618.workers.dev/me", "_blank"))),
  openMain: (tab?: string) => call("open_main", { tab: tab ?? null }),
  takePendingTab: () => call<string | null>("take_pending_tab"),
  getUiState: () => call<Record<string, unknown>>("get_ui_state"),
  setUiState: (value: Record<string, unknown>) => call("set_ui_state", { value }),
  hidePopover: () => call("hide_popover"),
  fitPopover: (height: number) => call("fit_popover", { height }),
  fitFloating: (width: number, height: number) => call("fit_floating", { width, height }),
  expandFloating: () => (inTauri ? call("expand_floating") : Promise.resolve(void applyDemoSettings({ floatingDock: null }))),
  finishOnboarding: (openStats: boolean) => call("finish_onboarding", { openStats }),
  openUrl: (url: string) => call("open_url", { url }),
  backdrop: () => call<string>("backdrop"),
  quit: () => call("quit"),
  startDragging: () => (inTauri ? getCurrentWindow().startDragging() : Promise.resolve()),
  /** 悬浮窗上按下 / 松手：按着时后台跟着鼠标移动窗口，松手时判断吸附 / 收起 / 展开（对应 Mac FloatingMouseView）。 */
  floatingPress: () => call("floating_press"),
  floatingRelease: () => call("floating_release"),
  floatingMenu: () => call("floating_menu"),
  fitFloatingMenu: (width: number, height: number) => call("fit_floating_menu", { width, height }),
  pickFloatingMenu: (id: string) => call("pick_floating_menu", { id }),
  hideFloatingMenu: () => call("hide_floating_menu"),
  floatingAlive: () => call("floating_alive"),
};
