// 桌面悬浮窗（对应 Mac `FloatingContentView`）：每行 18px tile + 4px 进度条 + 剩余百分比（状态色）。
// Grok 显示周期额度，其余显示 5H。勾了「悬浮窗」的其他账号排在同服务本机账号后面；同一服务有几行时每行加账号名。置顶、不抢焦点；按住任意处拖动，拖到屏幕边 20 像素内自动吸附；双击打开统计。
// 拖出屏幕左 / 右边缘时收起成贴边窄条（像微信通话小窗），每行只剩小图标和剩余百分比；单击窄条展开，拖动窄条沿边上下移动（贴边逻辑在 windows.rs）。

import { useLayoutEffect, useRef } from "react";
import { api, useAppState } from "../shared/api";
import { ProgressBar, ServiceTile, statusColor } from "../shared/design";
import { tr } from "../shared/l10n";
import { headlineWindow, remaining } from "../shared/quota";
import { ALL_APPS, floatingShows, localShown, type QuotaSnapshot, type UsageApp } from "../shared/types";

export function Floating() {
  const state = useAppState();
  const ref = useRef<HTMLDivElement>(null);
  /** 收起时按下鼠标的位置：没移动就松开算单击（展开），移动超过 3 像素才开始拖动。 */
  const press = useRef<{ x: number; y: number } | null>(null);

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

  type Row = { key: string; app: UsageApp; name: string | null; quota: QuotaSnapshot | null };
  const rows: Row[] = [];
  if (state) {
    for (const app of ALL_APPS) {
      const s = state.services.find((x) => x.app === app);
      const group: Row[] = [];
      if (s && floatingShows(state.settings, app) && localShown(s)) group.push({ key: app, app, name: s.email ? s.email.split("@")[0] : null, quota: s.quota });
      for (const o of state.others) {
        if (o.app === app && o.enabled && o.showInFloating) group.push({ key: o.id, app, name: o.name, quota: o.quota });
      }
      // 只有一行时不写名字
      rows.push(...(group.length > 1 ? group : group.map((r) => ({ ...r, name: null }))));
    }
  }

  const dock = state?.settings.floatingDock ?? null;
  if (dock) {
    return (
      <div
        ref={ref}
        className={`hud collapsed dock-${dock}`}
        onMouseDown={(e) => {
          if (e.button === 0) press.current = { x: e.screenX, y: e.screenY };
        }}
        onMouseMove={(e) => {
          const p = press.current;
          if (p && e.buttons === 1 && Math.hypot(e.screenX - p.x, e.screenY - p.y) > 3) {
            press.current = null;
            api.dragFloating();
          }
        }}
        onMouseUp={() => {
          if (press.current) api.expandFloating();
          press.current = null;
        }}
        title={tr("Click to expand · drag it back to the edge to keep it tucked, or away to open it there", "单击展开 · 拖动：放回屏幕边继续收着，拖远了就在那里展开")}
      >
        {rows.map((s) => {
          const rem = remaining(headlineWindow(s.app, s.quota));
          return (
            <div className="tab-row" key={s.key}>
              <ServiceTile app={s.app} size={14} logoSize={9} radius={4} />
              <span className="tab-percent num" style={{ color: statusColor(rem) }}>
                {rem == null ? "--" : Math.round(rem)}
              </span>
            </div>
          );
        })}
        {rows.length === 0 && <span className="tab-chevron">{dock === "right" ? "‹" : "›"}</span>}
      </div>
    );
  }

  return (
    <div
      ref={ref}
      className="hud"
      onMouseDown={(e) => {
        if (e.button === 0 && e.detail === 1) api.dragFloating();
      }}
      onDoubleClick={() => api.openMain("overview")}
      title={tr("Drag to move · double-click to open Statistics · drag past the screen edge to tuck it away", "拖动可移动 · 双击打开统计 · 拖出屏幕边缘可收起")}
    >
      {rows.map((s) => {
        const w = headlineWindow(s.app, s.quota);
        const rem = remaining(w);
        const color = statusColor(rem);
        return (
          <div className="hud-row" key={s.key}>
            <ServiceTile app={s.app} size={18} logoSize={12} radius={5} />
            {s.name && <span className="hud-name">{s.name}</span>}
            <ProgressBar value={(rem ?? 0) / 100} color={color} height={4} />
            <span className="hud-percent num" style={{ color }}>
              {rem == null ? "--%" : `${Math.round(rem)}%`}
            </span>
          </div>
        );
      })}
      {state && rows.length === 0 && <span className="secondary" style={{ fontSize: 11 }}>{tr("Nothing to show", "没有要显示的账号")}</span>}
    </div>
  );
}
