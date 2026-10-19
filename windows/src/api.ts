import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useEffect, useState } from "react";
import type { Settings, Snapshot } from "./types";
import { demoSnapshot } from "./demo";

/** 在浏览器里直接打开页面（不在 Tauri 里）时用演示数据，方便调样式。 */
export const inTauri = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

export function useSnapshot(): Snapshot | null {
  const [snap, setSnap] = useState<Snapshot | null>(inTauri ? null : demoSnapshot());
  useEffect(() => {
    if (!inTauri) return;
    let unlisten: (() => void) | undefined;
    invoke<Snapshot>("get_snapshot").then(setSnap);
    listen<Snapshot>("snapshot", (e) => setSnap(e.payload)).then((u) => (unlisten = u));
    return () => unlisten?.();
  }, []);
  return snap;
}

/** 每 15 秒重画一次，让“x 秒前刷新”“x 分后重置”走起来 */
export function useTicker(ms = 15000): number {
  const [now, setNow] = useState(Date.now() / 1000);
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now() / 1000), ms);
    return () => clearInterval(t);
  }, [ms]);
  return now;
}

const call = <T,>(cmd: string, args?: Record<string, unknown>): Promise<T | undefined> =>
  inTauri ? invoke<T>(cmd, args) : Promise.resolve(undefined);

export const api = {
  refresh: () => call("refresh"),
  updateSettings: (settings: Settings) => call("update_settings", { settings }),
  fitPanel: (height: number) => call("fit_panel", { height }),
  fitPill: (width: number) => call("fit_pill", { width }),
  openPanel: () => call("open_panel"),
  hidePanel: () => call("hide_panel"),
  quit: () => call("quit"),
  getAutostart: () => call<boolean>("get_autostart"),
  setAutostart: (enabled: boolean) => call<boolean>("set_autostart", { enabled }),
  backdrop: () => call<string>("backdrop"),
  startDragging: () => (inTauri ? getCurrentWindow().startDragging() : Promise.resolve()),
};
