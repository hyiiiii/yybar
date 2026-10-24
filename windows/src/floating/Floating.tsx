// 桌面悬浮窗（对应 Mac `FloatingContentView`）：每行 18px tile + 4px 进度条 + 剩余百分比（状态色）。
// Grok 显示周期额度，其余显示 5H。置顶、不抢焦点；按住任意处拖动，拖到屏幕边 20 像素内自动吸附；双击打开统计。

import { useLayoutEffect, useRef } from "react";
import { api, useAppState } from "../shared/api";
import { ProgressBar, ServiceTile, statusColor } from "../shared/design";
import { tr } from "../shared/l10n";
import { headlineWindow, remaining } from "../shared/quota";
import { ALL_APPS, floatingShows } from "../shared/types";

export function Floating() {
  const state = useAppState();
  const ref = useRef<HTMLDivElement>(null);

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const fit = () => {
      const r = el.getBoundingClientRect();
      api.fitFloating(Math.ceil(r.width), Math.ceil(r.height));
    };
    fit();
    const ro = new ResizeObserver(fit);
    ro.observe(el);
    return () => ro.disconnect();
  }, [state != null]);

  const rows = state
    ? ALL_APPS.map((app) => state.services.find((s) => s.app === app)!).filter((s) => s && floatingShows(state.settings, s.app) && !s.removed)
    : [];

  return (
    <div
      ref={ref}
      className="hud"
      onMouseDown={(e) => {
        if (e.button === 0 && e.detail === 1) api.startDragging();
      }}
      onDoubleClick={() => api.openMain("overview")}
      title={tr("Drag to move · double-click to open Statistics", "拖动可移动 · 双击打开统计")}
    >
      {rows.map((s) => {
        const w = headlineWindow(s.app, s.quota);
        const rem = remaining(w);
        const color = statusColor(rem);
        return (
          <div className="hud-row" key={s.app}>
            <ServiceTile app={s.app} size={18} logoSize={12} radius={5} />
            <ProgressBar value={(rem ?? 0) / 100} color={color} height={4} />
            <span className="hud-percent num" style={{ color }}>
              {rem == null ? "--%" : `${Math.round(rem)}%`}
            </span>
          </div>
        );
      })}
      {state && rows.length === 0 && <span className="secondary" style={{ fontSize: 11 }}>{tr("No services", "未启用")}</span>}
    </div>
  );
}
