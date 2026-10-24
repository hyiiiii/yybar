// 统计 / 设置各是一个大页：所有部分纵向排列在同一个滚动区里（对应 Mac `SectionedScrollPage`）。
// - 侧边栏点击 → 平滑滚动到对应部分；
// - 手动滚动时，滚到顶部区域的部分成为侧边栏选中项。

import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import type { MainTab } from "./tabs";

const LANDING_GAP = 20;

export interface ScrollRequest {
  tab: MainTab;
  seq: number;
  animated: boolean;
}

export function SectionedPage({ sections, request, active, onActive, children }: {
  sections: MainTab[];
  request: ScrollRequest;
  active: MainTab;
  onActive: (t: MainTab) => void;
  children: ReactNode;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const suppressUntil = useRef(0);
  const [viewport, setViewport] = useState(600);

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setViewport(el.clientHeight));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  useEffect(() => {
    const el = ref.current;
    if (!el || !sections.includes(request.tab)) return;
    const go = () => {
      const target = el.querySelector<HTMLElement>(`[data-section="${request.tab}"]`);
      if (!target) return;
      suppressUntil.current = Date.now() + (request.animated ? 800 : 200);
      el.scrollTo({ top: target.getBoundingClientRect().top - el.getBoundingClientRect().top + el.scrollTop - LANDING_GAP + 20, behavior: request.animated ? "smooth" : "auto" });
    };
    go();
    if (!request.animated) {
      // 首帧后图表 / 数据还可能改变上方部分的高度，稍后再对齐一次。
      const t = setTimeout(go, 150);
      return () => clearTimeout(t);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [request.seq]);

  const onScroll = () => {
    const el = ref.current;
    if (!el || Date.now() < suppressUntil.current || !sections.includes(active)) return;
    const top = el.getBoundingClientRect().top;
    let current: MainTab = sections[0];
    for (const tab of sections) {
      const target = el.querySelector<HTMLElement>(`[data-section="${tab}"]`);
      if (target && target.getBoundingClientRect().top - top <= 120) current = tab;
    }
    if (current !== active) onActive(current);
  };

  return (
    <div className="sectioned" ref={ref} onScroll={onScroll}>
      <div className="sectioned-content">{children}</div>
      <div style={{ height: Math.max(0, viewport - 320) }} />
    </div>
  );
}

/** 大页里的一个部分。 */
export function Section({ tab, children, maxWidth }: { tab: MainTab; children: ReactNode; maxWidth?: number }) {
  return (
    <section className="section" data-section={tab} style={maxWidth ? { maxWidth } : undefined}>
      {children}
    </section>
  );
}

export function SectionHeading({ title, subtitle, right }: { title: string; subtitle?: string | null; right?: ReactNode }) {
  return (
    <div className="section-heading">
      <div>
        <div className="section-title">{title}</div>
        {subtitle && <div className="section-subtitle">{subtitle}</div>}
      </div>
      {right && <div className="section-heading-right">{right}</div>}
    </div>
  );
}
