// 统计 · Token 活动（对应 Mac `TokenActivityPanel`）：最近 53 周，列 = 周（周一开头），全部 token（含缓存），跟随服务筛选。
// 每天 = 日历热力格（4 档）；每周 = 每列从下往上填，格数 ∝ 当周合计；累计总量 = 填到截至该周的累计。
// 「全部」用火苗同色系的暖色四档，单个服务用它的识别色。月份标签只标在每月 1 号所在的那一列。

import { useLayoutEffect, useRef, useState } from "react";
import { compactToken, dayString, longDate, monthDayLabel, parseDay, shortMonth } from "../../shared/format";
import { RollingText } from "../../shared/design";
import { tr } from "../../shared/l10n";
import { usePersisted } from "../uiState";
import { TokenHeat, type ServiceFilter } from "./data";

type Mode = "daily" | "weekly" | "cumulative";

const WEEKS = 53;
const GAP = 3;
const MAX_CELL = 14;

export function TokenActivity({ daily, filter }: { daily: Map<string, number>; filter: ServiceFilter }) {
  const [mode, setMode] = usePersisted<Mode>("activity.mode", "daily");
  const [hover, setHover] = useState<{ col: number; row: number } | null>(null);
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(700);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setWidth(el.clientWidth));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const today = parseDay(dayString(new Date()));
  const thisWeek = new Date(today);
  thisWeek.setDate(today.getDate() - ((today.getDay() + 6) % 7));
  const starts: Date[] = [];
  for (let i = WEEKS - 1; i >= 0; i--) {
    const d = new Date(thisWeek);
    d.setDate(thisWeek.getDate() - i * 7);
    starts.push(d);
  }
  const dayOf = (col: number, row: number) => {
    const d = new Date(starts[col]);
    d.setDate(d.getDate() + row);
    return d;
  };
  const value = (d: Date) => daily.get(dayString(d)) ?? 0;
  const weekTotals = starts.map((_, c) => [0, 1, 2, 3, 4, 5, 6].reduce((s, r) => s + value(dayOf(c, r)), 0));
  let running = [...daily].filter(([d]) => d < dayString(starts[0])).reduce((s, [, v]) => s + v, 0);
  const cumulative = weekTotals.map((t) => (running += t));
  const thresholds = TokenHeat.thresholds(daily, dayString(starts[0]));

  // 汇总
  const totalAll = [...daily.values()].reduce((s, v) => s + v, 0);
  const peak = Math.max(0, ...daily.values());
  const used = new Set([...daily].filter(([, v]) => v > 0).map(([d]) => d));
  let longest = 0;
  for (const d of used) {
    const prev = new Date(parseDay(d));
    prev.setDate(prev.getDate() - 1);
    if (used.has(dayString(prev))) continue;
    let len = 1;
    const next = parseDay(d);
    for (;;) {
      next.setDate(next.getDate() + 1);
      if (!used.has(dayString(next))) break;
      len++;
    }
    longest = Math.max(longest, len);
  }
  const cursor = new Date(today);
  if (!used.has(dayString(cursor))) cursor.setDate(cursor.getDate() - 1);
  let current = 0;
  while (used.has(dayString(cursor))) {
    current++;
    cursor.setDate(cursor.getDate() - 1);
  }

  const cell = Math.max(6, Math.min(MAX_CELL, (width - (WEEKS - 1) * GAP) / WEEKS));
  const pitch = cell + GAP;
  const tint = filter === "all" ? null : `var(--accent-${filter === "agy" ? "google" : filter})`;
  const levels = tint
    ? [0.22, 0.45, 0.72, 1].map((o) => `color-mix(in srgb, ${tint} ${o * 100}%, transparent)`)
    : ["var(--heat-1)", "var(--heat-2)", "var(--heat-3)", "var(--heat-4)"];
  const bar = tint ? `color-mix(in srgb, ${tint} 72%, transparent)` : "var(--heat-3)";
  const barHover = tint ?? "var(--heat-4)";

  const fill = (col: number, row: number): string => {
    if (mode === "daily") {
      const d = dayOf(col, row);
      if (d > today) return "transparent";
      const lvl = TokenHeat.level(value(d), thresholds);
      return lvl === 0 ? "var(--fill)" : levels[lvl - 1];
    }
    const values = mode === "weekly" ? weekTotals : cumulative;
    const max = Math.max(1, ...values);
    const v = values[col];
    const filled = v > 0 ? Math.max(1, Math.round((v / max) * 7)) : 0;
    if (row < 7 - filled) return "var(--fill)";
    return hover?.col === col ? barHover : bar;
  };

  const tokens = (v: number) => tr(`${compactToken(v).replace(" ", "")} tokens`, `${compactToken(v).replace(" ", "")} 个 Token`);
  const tooltip = (col: number, row: number): string[] | null => {
    if (mode === "daily") {
      const d = dayOf(col, row);
      if (d > today) return null;
      return [monthDayLabel(d), tokens(value(d))];
    }
    if (mode === "weekly") return [tr(`Week of ${longDate(starts[col])}`, `${longDate(starts[col])} 起的一周`), tokens(weekTotals[col])];
    return [tr(`Total through week of ${longDate(starts[col])}`, `累计至 ${longDate(starts[col])} 起的一周`), tokens(cumulative[col])];
  };

  // 月份标签：每月 1 号所在的列；最左边去年同月的残段不标，左右同月时只留右边。
  const monthCols: number[] = [];
  starts.forEach((s, i) => {
    if (i >= starts.length - 2) return;
    if (i === 0) {
      if (s.getDate() <= 7) monthCols.push(i);
    } else if (s.getMonth() !== starts[i - 1].getMonth()) monthCols.push(i);
  });
  if (monthCols.length > 1 && starts[monthCols[0]].getMonth() === starts[monthCols[monthCols.length - 1]].getMonth()) monthCols.shift();

  const tip = hover ? tooltip(hover.col, hover.row) : null;
  const anchorRow = mode === "daily" ? hover?.row ?? 0 : 0;

  return (
    <div className="panel activity-panel">
      <div className="activity-summary">
        <Summary value={compactToken(totalAll)} label={tr("Total tokens", "累计 Token 数")} />
        <Summary value={compactToken(peak)} label={tr("Peak day", "Token 使用峰值")} />
        <Summary value={tr(`${longest} days`, `${longest} 天`)} label={tr("Longest streak", "最长连续天数")} />
        <Summary value={tr(`${current} days`, `${current} 天`)} label={tr("Current streak", "当前连续天数")} />
      </div>
      <div className="activity-head">
        <b>{tr("Token activity", "Token 活动")}</b>
        <span style={{ flex: 1 }} />
        {(
          [
            ["daily", tr("Daily", "每天")],
            ["weekly", tr("Weekly", "每周")],
            ["cumulative", tr("Cumulative", "累计总量")],
          ] as [Mode, string][]
        ).map(([m, label]) => (
          <button key={m} className={`mode-button ${mode === m ? "active" : ""}`} onClick={() => setMode(m)}>
            {label}
          </button>
        ))}
      </div>
      <div className="heatmap" ref={ref}>
        <div
          className="heat-grid"
          style={{ gridTemplateColumns: `repeat(${WEEKS}, ${cell}px)`, gap: GAP }}
          onMouseMove={(e) => {
            const rect = e.currentTarget.getBoundingClientRect();
            const col = Math.floor((e.clientX - rect.left) / pitch);
            const row = Math.floor((e.clientY - rect.top) / pitch);
            setHover(col >= 0 && col < WEEKS && row >= 0 && row < 7 ? { col, row } : null);
          }}
          onMouseLeave={() => setHover(null)}
        >
          {starts.map((_, col) => (
            <div key={col} className="heat-col" style={{ gap: GAP }}>
              {[0, 1, 2, 3, 4, 5, 6].map((row) => (
                <span key={row} className="heat-cell" style={{ width: cell, height: cell, borderRadius: cell * 0.24, background: fill(col, row) }} />
              ))}
            </div>
          ))}
          {hover && tip && (
            <div
              className="heat-tooltip"
              style={{
                left: Math.min(Math.max(0, hover.col * pitch + cell / 2 - 80), width - 160),
                top: anchorRow * pitch - 6,
              }}
            >
              {tip.map((l) => (
                <div key={l} className="num">
                  {l}
                </div>
              ))}
            </div>
          )}
        </div>
        <div className="month-labels" style={{ height: 16 }}>
          {monthCols.map((c) => (
            <span key={c} style={{ left: c * pitch }}>
              {shortMonth(starts[c])}
            </span>
          ))}
        </div>
      </div>
    </div>
  );
}

function Summary({ value, label }: { value: string; label: string }) {
  return (
    <div className="summary-cell">
      <div className="summary-value num">
        <RollingText text={value} />
      </div>
      <div className="summary-label">{label}</div>
    </div>
  );
}
