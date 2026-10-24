// 每日用量图（对应 Mac `dailyUsagePanel` 的 Swift Charts）：按服务堆叠的细柱 + 日均虚线，悬停显示当日各服务数值。
// 横轴约 6 个日期标签，从最后一天往前每 N 天一个；换时间范围 / 服务时柱子从底部长出来。

import { useLayoutEffect, useRef, useState } from "react";
import { ServiceLogo } from "../../shared/design";
import { cost, compactToken, parseDay } from "../../shared/format";
import { shortName } from "../../shared/services";
import type { UsageApp } from "../../shared/types";
import { axisTicks, niceCeiling, type Metric } from "./data";
import { formatMetric } from "./StatsView";

export interface DailySample {
  day: string;
  values: Partial<Record<UsageApp, number>>;
}

const HEIGHT = 104;
const AXIS_W = 44;
const LABEL_H = 18;

const colorOf = (app: UsageApp) => `var(--accent-${app === "agy" ? "google" : app})`;

export function DailyChart({ samples, apps, average, metric }: { samples: DailySample[]; apps: UsageApp[]; average: number; metric: Metric }) {
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(600);
  const [hover, setHover] = useState<number | null>(null);
  const [grown, setGrown] = useState(false);

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setWidth(el.clientWidth));
    ro.observe(el);
    setWidth(el.clientWidth);
    const t = requestAnimationFrame(() => requestAnimationFrame(() => setGrown(true)));
    return () => {
      ro.disconnect();
      cancelAnimationFrame(t);
    };
  }, []);

  const totals = samples.map((s) => apps.reduce((sum, a) => sum + (s.values[a] ?? 0), 0));
  const top = niceCeiling(Math.max(...totals, average));
  const ticks = axisTicks(top);
  const plotW = Math.max(10, width - AXIS_W);
  const pitch = plotW / samples.length;
  const barW = samples.length <= 10 ? Math.min(16, pitch * 0.7) : samples.length <= 31 ? Math.min(10, pitch * 0.7) : Math.max(1, pitch * 0.7);
  const y = (v: number) => HEIGHT - (v / top) * HEIGHT;
  const step = Math.max(1, Math.floor(samples.length / 6));
  const labelIdx = new Set<number>();
  for (let i = samples.length - 1; i >= 0; i -= step) labelIdx.add(i);
  const axisLabel = (v: number) => (metric === "cost" ? `$${Math.round(v)}` : compactToken(v));

  const hovered = hover != null ? samples[hover] : null;
  return (
    <div
      className="daily-chart"
      ref={ref}
      onMouseMove={(e) => {
        const rect = e.currentTarget.getBoundingClientRect();
        const i = Math.floor((e.clientX - rect.left - AXIS_W) / pitch);
        setHover(i >= 0 && i < samples.length ? i : null);
      }}
      onMouseLeave={() => setHover(null)}
    >
      <svg width={width} height={HEIGHT + LABEL_H} className="chart-svg">
        {ticks.map((t) => (
          <g key={t}>
            <line x1={AXIS_W} x2={width} y1={y(t)} y2={y(t)} className="grid-line" />
            <text x={AXIS_W - 6} y={y(t) + 3} textAnchor="end" className="axis-text num">
              {axisLabel(t)}
            </text>
          </g>
        ))}
        <g className={`bars ${grown ? "grown" : ""}`} style={{ transformOrigin: `0 ${HEIGHT}px` }}>
          {samples.map((s, i) => {
            let acc = 0;
            const x = AXIS_W + i * pitch + (pitch - barW) / 2;
            const dim = hover != null && hover !== i ? 0.45 : 1;
            const parts = apps.filter((a) => (s.values[a] ?? 0) > 0);
            return (
              <g key={s.day} opacity={dim}>
                {parts.map((a, j) => {
                  const v = s.values[a] ?? 0;
                  const y0 = y(acc);
                  acc += v;
                  const y1 = y(acc);
                  const h = Math.max(1, y0 - y1 - (j < parts.length - 1 ? 0.5 : 0));
                  return <rect key={a} x={x} y={y1} width={barW} height={h} rx={Math.min(2, barW / 2)} fill={colorOf(a)} />;
                })}
              </g>
            );
          })}
          <line x1={AXIS_W} x2={width} y1={y(average)} y2={y(average)} className="avg-line" />
        </g>
        {samples.map((s, i) =>
          labelIdx.has(i) ? (
            <text key={s.day} x={AXIS_W + i * pitch + pitch / 2} y={HEIGHT + 13} textAnchor="middle" className="axis-text num">
              {parseDay(s.day).getMonth() + 1}/{parseDay(s.day).getDate()}
            </text>
          ) : null,
        )}
      </svg>
      {hovered && (
        <div className="chart-tooltip" style={{ left: Math.min(Math.max(0, AXIS_W + hover! * pitch + pitch / 2 - 75), width - 150), top: -6 }}>
          <div className="tooltip-title num">{hovered.day}</div>
          {apps.map((a) => (
            <div className="tooltip-row" key={a}>
              <ServiceLogo app={a} size={10} />
              <span>{shortName(a)}</span>
              <span style={{ flex: 1 }} />
              <span className="num">{metric === "cost" ? cost(hovered.values[a] ?? 0) : formatMetric(hovered.values[a] ?? 0, metric)}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
