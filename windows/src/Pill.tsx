import { useLayoutEffect, useRef } from "react";
import { api, useSnapshot } from "./api";
import { SHORT_NAME, pct, statusClass, tightest, usd } from "./format";

/**
 * 桌面悬浮条：代替 Mac 菜单栏上的文字。每个服务显示最紧张那档的剩余比例，最后是今日花费。
 * 按住拖动可以挪位置，单击打开托盘面板。
 */
export default function Pill() {
  const snap = useSnapshot();
  const root = useRef<HTMLDivElement>(null);
  const press = useRef<{ x: number; y: number } | null>(null);

  useLayoutEffect(() => {
    const el = root.current;
    if (!el) return;
    const ro = new ResizeObserver(() => api.fitPill(Math.ceil(el.getBoundingClientRect().width)));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const services = snap?.services.filter((s) => s.enabled && (s.quota || s.detected)) ?? [];

  return (
    <div
      className="pill"
      ref={root}
      onMouseDown={(e) => {
        if (e.button === 0) press.current = { x: e.screenX, y: e.screenY };
      }}
      onMouseMove={(e) => {
        const p = press.current;
        if (p && Math.hypot(e.screenX - p.x, e.screenY - p.y) > 3) {
          press.current = null;
          api.startDragging();
        }
      }}
      onMouseUp={() => {
        if (press.current) api.openPanel();
        press.current = null;
      }}
    >
      {services.map((s) => {
        const rem = tightest(s);
        return (
          <span key={s.app} className="pill-item">
            <i className={`dot ${statusClass(rem)}`} />
            <span className="pill-name">{SHORT_NAME[s.app]}</span>
            <span className="num">{pct(rem)}</span>
          </span>
        );
      })}
      <span className="pill-item">
        <span className="pill-name">今日</span>
        <span className="num">{usd(snap?.usage.today.costUsd ?? 0)}</span>
      </span>
    </div>
  );
}
