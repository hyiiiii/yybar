// 统计 · 额度变化（对应 Mac `QuotaTimelineOverview`）：今天各账号所选窗口（5H / WK）的剩余额度画在一张阶梯图里，
// 只记录发生变化的时间点，线延伸到当前时刻；悬停显示该时刻各账号的剩余。下方账号列表可开关曲线、展开变动记录。
// Grok 只有周期额度，只在 WK 下出现；Antigravity 两个池子各一条。

import { useLayoutEffect, useRef, useState } from "react";
import { useTicker } from "../../shared/api";
import { Collapsible, Icon, planName, RollingText, Segmented, statusColor, Toggle } from "../../shared/design";
import { dayString, quotaDelta, timeString } from "../../shared/format";
import { tr } from "../../shared/l10n";
import { displayName } from "../../shared/services";
import { localShown, type QuotaSnapshot, type ChangeEvent, type QuotaWindow, type StateSnapshot, type UsageApp } from "../../shared/types";
import { SectionHeading } from "../SectionedPage";
import { usePersisted } from "../uiState";
import { Placeholder } from "./Panel";

interface TimelineSection {
  key: string;
  title: string;
  color: string;
  currentRemaining: number | null;
  totalDelta: number;
  latestEventAt: number | null;
  events: ChangeEvent[];
  recordingStartedAt: number | null;
}

const PALETTE = ["var(--sys-blue)", "var(--sys-purple)", "var(--sys-teal)", "#ff6482", "#5e5ce6"];
const CHART_H = 260;
const AXIS_W = 40;

export function QuotaTimeline({ state }: { state: StateSnapshot }) {
  const [win, setWin] = usePersisted<"fiveHour" | "weekly">("timeline.window", "fiveHour");
  const [hidden, setHidden] = usePersisted<string[]>("timeline.hidden", []);
  const [expanded, setExpanded] = usePersisted<string[]>("timeline.expanded", []);
  const [collapsed, setCollapsed] = usePersisted("timeline.collapsed", false);
  const now = useTicker(30_000);
  const weekly = win === "weekly";
  const history = state.history;

  const sections: TimelineSection[] = [];
  const usedColors = new Set<UsageApp>();
  let paletteIndex = 0;
  const add = (app: UsageApp, base: string, title: string, window: QuotaWindow | null | undefined, exists: boolean) => {
    const key = weekly ? `${base}#wk` : base;
    const events = history.events.filter((e) => e.accountKey === key).sort((a, b) => a.sampledAt - b.sampledAt);
    const sample = history.lastSamples[key];
    if (!exists && !window && !sample && !events.length) return;
    const first = history.firstSampledAt?.[key];
    const recordingStartedAt = first != null ? Math.min(first, events[0]?.sampledAt ?? first) : events.length ? null : sample?.sampledAt ?? null;
    let color = `var(--accent-${app === "agy" ? "google" : app})`;
    if (usedColors.has(app)) color = PALETTE[paletteIndex++ % PALETTE.length];
    usedColors.add(app);
    sections.push({
      key,
      title,
      color,
      currentRemaining: sample?.remainingPercent ?? (window ? Math.round(Math.max(0, Math.min(100, 100 - window.usedPercent))) : null),
      totalDelta: events.reduce((s, e) => s + e.deltaPercent, 0),
      latestEventAt: events.length ? events[events.length - 1].sampledAt : null,
      events,
      recordingStartedAt,
    });
  };
  const titleOf = (provider: string, plan: string | null, email: string | null, app: UsageApp) =>
    [provider, plan ? planName(plan, app) : null, email].filter(Boolean).join(" · ");

  // 顺序：Codex 本机 → Codex 其他 → Claude 本机 → Claude 其他 → Grok … → Antigravity …
  const addAgy = (keys: string[], q: QuotaSnapshot | null, plan: string | null, email: string | null) => {
    const pools = q?.pools ?? [];
    const labels = ["Gemini", "Claude·GPT"];
    keys.forEach((key, i) => {
      const pool = pools.find((p) => p.label === labels[i]);
      add("agy", key, titleOf(`Antigravity · ${labels[i]}`, plan, email, "agy"), weekly ? pool?.weekly : pool?.fiveHour, false);
    });
  };
  for (const s of state.services) {
    if (s.enabled && localShown(s)) {
      const q = s.quota;
      if (s.app === "agy") addAgy(s.historyKeys, q, s.plan, s.email);
      else if (s.app !== "grok" || weekly) add(s.app, s.historyKeys[0], titleOf(displayName[s.app], s.plan, s.email, s.app), weekly ? q?.weekly ?? q?.primary : q?.fiveHour, s.detected);
    }
    for (const o of state.others) {
      if (o.app !== s.app || !o.enabled) continue;
      const oq = o.quota;
      if (o.provider === "google") addAgy(o.historyKeys, oq, o.plan, o.email ?? o.name);
      else if (o.app !== "grok" || weekly) add(o.app, o.historyKeys[0], titleOf(displayName[o.app], o.plan, o.email ?? o.name, o.app), weekly ? oq?.weekly ?? oq?.primary : oq?.fiveHour, true);
    }
  }

  const dayStart = new Date();
  dayStart.setHours(0, 0, 0, 0);
  const ds = dayStart.getTime() / 1000;
  const allLate = sections.length > 0 && sections.every((s) => (s.recordingStartedAt ?? ds) - ds > 60);
  const earliest = Math.min(...sections.map((s) => s.recordingStartedAt ?? ds));
  const note = allLate
    ? tr(`Recording started at ${timeString(earliest)} today; earlier changes aren't available.`, `今天从 ${timeString(earliest)} 开始记录，更早的变化没有数据。`)
    : null;

  const visible = sections.filter((s) => !hidden.includes(s.key));
  return (
    <div className="timeline">
      <SectionHeading
        title={weekly ? tr("Today WK Quota", "今日 WK 额度") : tr("Today 5H Quota", "今日 5H 额度")}
        subtitle={note}
        right={
          <span className="panel-controls">
            <Segmented
              options={[
                { value: "fiveHour", label: "5H" },
                { value: "weekly", label: "WK" },
              ]}
              value={win}
              onChange={setWin}
            />
            <span className="mono-date">{dayString(new Date())}</span>
          </span>
        }
      />
      {sections.length === 0 ? (
        <div className="panel">
          <Placeholder height={220} message={tr("No accounts", "暂无账号")} />
        </div>
      ) : (
        <>
          {/* 换 5H / WK 时整张图淡入 */}
          <div key={win} className="fade-swap">
            <TimelineChart sections={visible} start={ds} now={now} allHidden={visible.length === 0} />
          </div>
          <div className="panel accounts-panel">
            <div className="accounts-head">
              <button className="accounts-toggle" onClick={() => setCollapsed(!collapsed)} title={collapsed ? tr("Show accounts", "展开账号列表") : tr("Hide accounts", "收起账号列表")}>
                <span className={`chev ${collapsed ? "" : "open"}`}>
                  <Icon name="chevronRight" size={11} />
                </span>
                <b>{tr("Accounts", "账号")}</b>
                <span className="secondary num">{sections.length}</span>
              </button>
              <span style={{ flex: 1 }} />
              <span className={`secondary fade-toggle ${collapsed ? "off" : ""}`} style={{ fontSize: 10.5 }}>
                {tr("Show in chart", "显示曲线")}
              </span>
            </div>
            <Collapsible open={!collapsed}>
              {sections.map((s) => {
                const open = expanded.includes(s.key);
                return (
                  <div key={s.key}>
                    <div className="divider" />
                    <div className="account-row">
                      <span className="series-swatch" style={{ background: s.color }} />
                      <span className="account-title">{s.title}</span>
                      <span style={{ flex: 1 }} />
                      <Metric label={tr("Now", "当前")} value={s.currentRemaining != null ? `${s.currentRemaining}%` : "--"} />
                      <Metric label={tr("Today", "今日")} value={quotaDelta(s.totalDelta)} />
                      <Metric label={tr("Latest", "最近")} value={s.latestEventAt ? timeString(s.latestEventAt) : "--"} />
                      <button className="details-button" onClick={() => setExpanded(open ? expanded.filter((k) => k !== s.key) : [...expanded, s.key])}>
                        {tr("Details", "详情")}
                        <span className={`chev ${open ? "flip" : ""}`}>
                          <Icon name="chevronDown" size={10} />
                        </span>
                      </button>
                      <Toggle small checked={!hidden.includes(s.key)} onChange={(v) => setHidden(v ? hidden.filter((k) => k !== s.key) : [...hidden, s.key])} />
                    </div>
                    <Collapsible open={open}>
                      <div className="account-details">
                        {s.events.length === 0 ? <span className="secondary">{tr("No changes today", "今天暂无变动")}</span> : <EventTable events={s.events} />}
                      </div>
                    </Collapsible>
                  </div>
                );
              })}
            </Collapsible>
          </div>
        </>
      )}
    </div>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <span className="metric">
      <span className="tertiary">{label}</span>
      <span className="num secondary">
        <RollingText text={value} />
      </span>
    </span>
  );
}

function EventTable({ events }: { events: ChangeEvent[] }) {
  const rows = [...events].sort((a, b) => b.sampledAt - a.sampledAt);
  return (
    <table className="event-table">
      <thead>
        <tr>
          <th style={{ textAlign: "left" }}>{tr("Time", "时间")}</th>
          <th>{tr("Change", "变动值")}</th>
          <th>{tr("After", "变动后剩余")}</th>
          <th>{tr("Reset", "重置时间")}</th>
        </tr>
      </thead>
      <tbody>
        {rows.map((e) => (
          <tr key={e.id}>
            <td style={{ textAlign: "left" }}>{timeString(e.sampledAt)}</td>
            <td style={{ color: e.deltaPercent < 0 ? "var(--sys-red)" : "var(--sys-green)" }}>{quotaDelta(e.deltaPercent)}</td>
            <td style={{ color: statusColor(e.afterRemainingPercent) }}>{e.afterRemainingPercent}%</td>
            <td>{e.resetsAt ? timeString(e.resetsAt) : "--"}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

/** 曲线点：从开始记录的时刻起（值为第一次变动前的剩余；没有变动为当前剩余），每次变动后的剩余，最后延伸到现在。 */
function points(s: TimelineSection, dayStart: number, now: number): { t: number; v: number; sample: boolean }[] {
  const start = s.recordingStartedAt ?? dayStart;
  const startValue = s.events[0]?.beforeRemainingPercent ?? s.currentRemaining;
  if (startValue == null) return [];
  const out = [{ t: start, v: startValue, sample: false }];
  for (const e of s.events) out.push({ t: e.sampledAt, v: e.afterRemainingPercent, sample: true });
  out.push({ t: now, v: s.currentRemaining ?? out[out.length - 1].v, sample: false });
  return out;
}

function valueAt(s: TimelineSection, t: number): number | null {
  if (s.recordingStartedAt != null && t < s.recordingStartedAt) return null;
  const last = [...s.events].reverse().find((e) => e.sampledAt <= t);
  if (last) return last.afterRemainingPercent;
  return s.events[0]?.beforeRemainingPercent ?? s.currentRemaining;
}

function TimelineChart({ sections, start, now, allHidden }: { sections: TimelineSection[]; start: number; now: number; allHidden: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(600);
  const [hover, setHover] = useState<number | null>(null);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setWidth(el.clientWidth - 32));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const series = sections.map((s) => ({ s, pts: points(s, start, now) }));
  const hasData = series.some((x) => x.pts.length > 0);
  const t0 = Math.min(start, ...series.flatMap((x) => x.pts.map((p) => p.t)));
  const t1 = Math.max(now, t0 + 3600);
  const plotW = Math.max(10, width - AXIS_W - 8);
  const x = (t: number) => AXIS_W + ((t - t0) / (t1 - t0)) * plotW;
  const y = (v: number) => 34 + (1 - v / 100) * (CHART_H - 54);
  const hourStep = Math.max(1, Math.ceil((t1 - t0) / 3600 / 6));
  const hourTicks: number[] = [];
  const firstHour = Math.ceil(t0 / 3600) * 3600;
  for (let t = firstHour; t <= t1; t += hourStep * 3600) hourTicks.push(t);

  return (
    <div className="panel timeline-chart" ref={ref}>
      {!hasData ? (
        <Placeholder height={240} message={allHidden ? tr("Turn on an account below to show its line.", "在下方打开账号即可显示曲线。") : tr("No quota data yet", "还没有额度数据")} />
      ) : (
        <div
          style={{ position: "relative" }}
          onMouseMove={(e) => {
            const rect = e.currentTarget.getBoundingClientRect();
            const t = t0 + ((e.clientX - rect.left - AXIS_W) / plotW) * (t1 - t0);
            setHover(t >= t0 && t <= t1 ? t : null);
          }}
          onMouseLeave={() => setHover(null)}
        >
          <svg width={width} height={CHART_H} className="chart-svg">
            {[0, 20, 50, 80, 100].map((v) => (
              <g key={v}>
                <line x1={AXIS_W} x2={AXIS_W + plotW} y1={y(v)} y2={y(v)} className="grid-line" />
                <text x={AXIS_W - 6} y={y(v) + 3} textAnchor="end" className="axis-text num">
                  {v}%
                </text>
              </g>
            ))}
            {hourTicks.map((t) => (
              <g key={t}>
                <line x1={x(t)} x2={x(t)} y1={34} y2={CHART_H - 20} className="grid-line faint" />
                <text x={x(t)} y={CHART_H - 6} textAnchor="middle" className="axis-text num">
                  {timeString(t)}
                </text>
              </g>
            ))}
            {series.map(({ s, pts }) => {
              if (!pts.length) return null;
              let d = `M${x(pts[0].t)},${y(pts[0].v)}`;
              for (let i = 1; i < pts.length; i++) d += ` H${x(pts[i].t)} V${y(pts[i].v)}`;
              return (
                <g key={s.key}>
                  <path d={d} fill="none" stroke={s.color} strokeWidth={1.8} strokeLinejoin="round" strokeLinecap="round" />
                  {pts.filter((p) => p.sample).map((p) => (
                    <circle key={p.t} cx={x(p.t)} cy={y(p.v)} r={2.4} fill={s.color} />
                  ))}
                </g>
              );
            })}
            {hover != null && <line x1={x(hover)} x2={x(hover)} y1={34} y2={CHART_H - 20} className="hover-line" />}
          </svg>
          {hover != null && (
            <div className="chart-tooltip" style={{ left: Math.min(Math.max(0, x(hover) - 105), width - 210), top: 0, width: 210 }}>
              <div className="tooltip-title num">{timeString(hover)}</div>
              {sections.map((s) => {
                const v = valueAt(s, hover);
                return (
                  <div className="tooltip-row" key={s.key}>
                    <span className="series-swatch small" style={{ background: s.color }} />
                    <span className="ellipsis">{s.title}</span>
                    <span style={{ flex: 1 }} />
                    <span className="num">{v != null ? `${v}%` : "—"}</span>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
