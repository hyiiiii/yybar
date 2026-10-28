// 桌面悬浮窗（对应 Mac `FloatingContentView`）：每行 18px tile + 4px 进度条 + 剩余百分比（状态色）。
// Grok 显示周期额度，其余显示 5H。勾了「悬浮窗」的其他账号排在同服务本机账号后面；同一服务有几行时每行加账号名。置顶、不抢焦点；按住任意处拖动，拖到屏幕边 20 像素内自动吸附。
// 拖出屏幕左 / 右边缘时收起成贴边窄条（像微信通话小窗），每行只剩小图标和剩余百分比；单击窄条展开，拖动窄条沿边上下移动（贴边逻辑在 windows.rs）。
// 按下、拖动、松手的处理和 Mac 版一样（FloatingMouseView）：见 usePress。

import { useLayoutEffect, useRef, type PointerEvent } from "react";
import { api, useAppState } from "../shared/api";
import { ProgressBar, ServiceTile, statusColor } from "../shared/design";
import { tr } from "../shared/l10n";
import { headlineWindow, remaining } from "../shared/quota";
import { ALL_APPS, floatingShows, localShown, type QuotaSnapshot, type UsageApp } from "../shared/types";

/** 悬浮窗（展开的、收起的窄条都一样）上的鼠标：按下、松手报给后台。按着时后台每帧跟一次光标，超过 3 像素才让窗口
 *  跟着鼠标走；松手时按有没有拖动过决定单击展开、吸附、收起或贴回边（windows.rs floating_press）。
 *  按下时捕获指针，在窗口外松手也收得到；万一没收到，后台看到左键松开也会收尾。 */
function usePress() {
  const pressed = useRef(false);
  const release = () => {
    if (!pressed.current) return;
    pressed.current = false;
    api.floatingRelease();
  };
  return {
    onPointerDown: (e: PointerEvent<HTMLDivElement>) => {
      if (e.button !== 0) return;
      e.currentTarget.setPointerCapture(e.pointerId);
      pressed.current = true;
      api.floatingPress();
    },
    onPointerUp: release,
    onLostPointerCapture: release,
  };
}

export function Floating() {
  const state = useAppState();
  const ref = useRef<HTMLDivElement>(null);
  const press = usePress();

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
    // 收起 / 展开时根节点换了，要重新观察尺寸
  }, [state != null, state?.settings.floatingDock ?? null]);

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
        key={`dock-${dock}`}
        className={`hud collapsed dock-${dock}`}
        // 没拖动 = 单击展开；拖动过 = 放回屏幕边继续收着，拖远了就地展开
        {...press}
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
      key="open"
      className="hud"
      {...press}
      title={tr("Drag to move · drag past the screen edge to tuck it away", "拖动可移动 · 拖出屏幕边缘可收起")}
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
