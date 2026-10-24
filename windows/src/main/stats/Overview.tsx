// 统计 · 概览（对应 Mac `StatsView.overviewSection`）：
// - 3 张 KPI：估算费用 / Tokens（不含缓存读取，可与缓存合并为「全部 Tokens」）/ 缓存读取；
//   多日和上一同长度区间比较，单日（今天 / 昨日）和所选对比基准比较，细条按服务拆分，单日时画基准竖线；
// - 多日：每日用量堆叠柱 + 日均虚线（费用 / Tokens 切换）；单日：「今天 / 昨日」各服务当天 vs 对比基准的横条；
// - 当前额度：2 列，每格服务图标 + 5H / WK 行（Grok 一行，Antigravity 每池两行）。

import { useTicker } from "../../shared/api";
import { LimitBarRow, Segmented, ServiceLogo } from "../../shared/design";
import { compactToken, cost, parseDay } from "../../shared/format";
import { tr } from "../../shared/l10n";
import { quotaLanes } from "../../shared/quota";
import { accentVar, shortName } from "../../shared/services";
import type { StateSnapshot, UsageApp } from "../../shared/types";
import { allTokens, nonCacheReadTokens, type Totals } from "../../shared/usage";
import { addDays, todayString, TokenHeat, type Baseline, type Bounds, type Metric, type StatsIndex } from "./data";
import { DailyChart, type DailySample } from "./DailyChart";
import { Panel } from "./Panel";
import { deltaText, formatMetric, MergeButton, type StatsSelections } from "./StatsView";
import { TodayFlame } from "./TodayFlame";

const BASELINES: Baseline[] = ["yesterday", "sevenDays", "thirtyDays", "all"];

function baselineShort(b: Baseline) {
  switch (b) {
    case "yesterday":
      return tr("Yesterday", "昨日");
    case "sevenDays":
      return tr("7d", "7 天");
    case "thirtyDays":
      return tr("30d", "30 天");
    case "all":
      return tr("All", "全部");
  }
}

function baselineLine(b: Baseline) {
  switch (b) {
    case "yesterday":
      return tr("yesterday", "昨日");
    case "sevenDays":
      return tr("prior 7-day daily average", "前 7 日日均");
    case "thirtyDays":
      return tr("prior 30-day daily average", "前 30 日日均");
    case "all":
      return tr("daily average since first use", "首次使用以来的日均");
  }
}

function baselineCompare(b: Baseline) {
  switch (b) {
    case "yesterday":
      return tr("vs yesterday", "较昨日");
    case "sevenDays":
      return tr("vs 7-day avg", "较 7 日均");
    case "thirtyDays":
      return tr("vs 30-day avg", "较 30 日均");
    case "all":
      return tr("vs all-time avg", "较历史日均");
  }
}

export function Overview({ state, index, sel, apps, bounds, previous, single, setMetric, setBaseline, setMergeTokens }: {
  state: StateSnapshot;
  index: StatsIndex;
  sel: StatsSelections;
  apps: UsageApp[];
  bounds: Bounds;
  previous: Bounds | null;
  single: boolean;
  setMetric: (m: Metric) => void;
  setBaseline: (b: Baseline) => void;
  setMergeTokens: (v: boolean) => void;
}) {
  const { metric, baseline, mergeTokens, range } = sel;
  const sum = (a: UsageApp[], b: Bounds) => index.sum(a, b.from, b.to);
  const tokenCount = (t: Totals) => (mergeTokens ? allTokens(t) : nonCacheReadTokens(t));
  const metricValue = (app: UsageApp, from: string, to: string) => {
    const d = index.sum([app], from, to);
    return metric === "cost" ? d.knownCost : tokenCount(d.totals);
  };

  /** 某一天之前的基准值：昨日 = 前一天；7 / 30 天 = 前 N 天日均；全部 = 首次使用以来的日均。顶部选「昨日」时仍以今天为参照。 */
  const baselineAverage = (a: UsageApp[], day: string, value: (from: string, to: string) => number): number => {
    const ref = range === "yesterday" ? todayString() : day;
    switch (baseline) {
      case "yesterday":
        return value(addDays(ref, -1), ref);
      case "sevenDays":
      case "thirtyDays": {
        const n = baseline === "sevenDays" ? 7 : 30;
        return value(addDays(ref, -n), ref) / n;
      }
      case "all": {
        const first = index.firstDay(a, ref);
        if (!first) return 0;
        const days = Math.max(1, Math.round((parseDay(ref).getTime() - parseDay(first).getTime()) / 86400000));
        return value(first, ref) / days;
      }
    }
  };

  // ---------- KPI ----------
  const current = sum(apps, bounds);
  const prev = previous ? sum(apps, previous) : null;
  const all = allTokens(current.totals);
  const cacheShare = all > 0 ? Math.round((current.totals.cacheRead / all) * 100) : 0;
  const day = bounds.from;

  const comparison = (value: number, prevValue: number | null, base: () => number): { text: string | null; line: number | null } => {
    if (single) {
      const b = base();
      return { text: deltaText(value, b, baselineCompare(baseline)), line: b };
    }
    return { text: deltaText(value, prevValue, tr("vs previous", "较上期")), line: null };
  };
  const costCmp = comparison(current.knownCost, prev?.knownCost ?? null, () => baselineAverage(apps, day, (f, t) => index.sum(apps, f, t).knownCost));
  const tokensCmp = comparison(nonCacheReadTokens(current.totals), prev ? nonCacheReadTokens(prev.totals) : null, () =>
    baselineAverage(apps, day, (f, t) => nonCacheReadTokens(index.sum(apps, f, t).totals)),
  );
  const cacheCmp = comparison(current.totals.cacheRead, prev?.totals.cacheRead ?? null, () => baselineAverage(apps, day, (f, t) => index.sum(apps, f, t).totals.cacheRead));
  const allCmp = comparison(all, prev ? allTokens(prev.totals) : null, () => baselineAverage(apps, day, (f, t) => allTokens(index.sum(apps, f, t).totals)));

  const segments = (value: (app: UsageApp) => number): KpiSegment[] =>
    apps.length > 1 || single ? apps.map((a) => ({ app: a, value: value(a) })) : [];

  return (
    <div className="overview">
      <div className={`kpi-row ${mergeTokens ? "merged" : ""}`}>
        <KpiCard
          title={tr("Estimated cost", "估算费用")}
          value={cost(current.knownCost) + (current.hasUnknown ? "+" : "")}
          detail={costCmp.text}
          segments={segments((a) => index.sum([a], bounds.from, bounds.to).knownCost)}
          line={costCmp.line}
        />
        <KpiCard
          className="kpi-tokens"
          title={mergeTokens ? tr("All tokens (incl. cache)", "全部 Tokens（含缓存）") : tr("Tokens (excl. cache reads)", "Tokens（不含缓存读取）")}
          value={compactToken(mergeTokens ? all : nonCacheReadTokens(current.totals))}
          detail={
            mergeTokens
              ? [allCmp.text, all > 0 ? tr(`cache reads ${cacheShare}% of all`, `缓存读取占 ${cacheShare}%`) : null].filter(Boolean).join(" · ")
              : tokensCmp.text
          }
          segments={segments((a) => tokenCount(index.sum([a], bounds.from, bounds.to).totals))}
          line={mergeTokens ? allCmp.line : tokensCmp.line}
          accessory={
            <MergeButton
              merged={mergeTokens}
              onClick={() => setMergeTokens(!mergeTokens)}
              titleMerge={tr("Merge tokens and cache reads", "合并 Tokens 和缓存读取")}
              titleSplit={tr("Show tokens and cache reads separately", "拆开 Tokens 和缓存读取")}
            />
          }
        />
        <KpiCard
          className="kpi-cache"
          title={tr("Cache reads", "缓存读取")}
          value={compactToken(current.totals.cacheRead)}
          detail={single ? cacheCmp.text : all > 0 ? tr(`${cacheShare}% of all tokens`, `占全部 Token ${cacheShare}%`) : null}
          segments={segments((a) => index.sum([a], bounds.from, bounds.to).totals.cacheRead)}
          line={cacheCmp.line}
        />
      </div>

      {single ? (
        <SingleDayPanel
          index={index}
          apps={apps}
          day={day}
          isToday={range === "today"}
          isYesterday={range === "yesterday"}
          metric={metric}
          baseline={baseline}
          setMetric={setMetric}
          setBaseline={setBaseline}
          metricValue={metricValue}
          baselineAverage={baselineAverage}
        />
      ) : (
        <DailyPanel index={index} apps={apps} bounds={bounds} metric={metric} mergeTokens={mergeTokens} setMetric={setMetric} chartKey={`${sel.range}|${sel.customFrom}|${sel.customTo}|${apps.join()}`} />
      )}

      <CurrentLimits state={state} apps={apps} />
    </div>
  );
}

// ---------- KPI 卡 ----------

interface KpiSegment {
  app: UsageApp;
  value: number;
}

function KpiCard({ title, value, detail, segments, line, accessory, className }: {
  title: string;
  value: string;
  detail: string | null;
  segments: KpiSegment[];
  line: number | null;
  accessory?: React.ReactNode;
  className?: string;
}) {
  const total = segments.reduce((s, x) => s + x.value, 0);
  const lineValue = line ?? 0;
  const scale = Math.max(total, lineValue, 0.0001);
  const filled = line == null ? 100 : (total / scale) * 100;
  const visible = segments.filter((s) => s.value > 0);
  return (
    <div className={`panel kpi-card ${className ?? ""}`}>
      <div className="kpi-title">
        <span>{title}</span>
        {accessory}
      </div>
      <div className="kpi-value num">{value}</div>
      <div className="kpi-detail num">{detail ?? " "}</div>
      <span style={{ flex: 1 }} />
      <div className="kpi-bar">
        {(total > 0 || lineValue > 0) && (
          <>
            {line != null && <div className="kpi-track" />}
            <div className="kpi-segments" style={{ width: `${filled}%` }}>
              {visible.map((s) => (
                <span key={s.app} style={{ flexGrow: s.value, background: `var(--accent-${s.app === "agy" ? "google" : s.app})` }} />
              ))}
            </div>
            {lineValue > 0 && <div className="kpi-line" style={{ left: `calc(${Math.min(100, (lineValue / scale) * 100)}% - 1px)` }} />}
          </>
        )}
      </div>
    </div>
  );
}

// ---------- 每日用量 ----------

function DailyPanel({ index, apps, bounds, metric, mergeTokens, setMetric, chartKey }: {
  index: StatsIndex;
  apps: UsageApp[];
  bounds: Bounds;
  metric: Metric;
  mergeTokens: boolean;
  setMetric: (m: Metric) => void;
  chartKey: string;
}) {
  // 连续的每日序列（没有用量的日子补 0）
  const samples: DailySample[] = [];
  const today = todayString();
  let start = bounds.from;
  if (start === "0000-01-01") start = index.firstDay(apps, "9999-12-31") ?? today;
  const last = bounds.to > today ? today : addDays(bounds.to, -1);
  for (let d = start; d <= last; d = addDays(d, 1)) {
    const values: Partial<Record<UsageApp, number>> = {};
    for (const app of apps) {
      const t = index.sum([app], d, addDays(d, 1));
      values[app] = metric === "cost" ? t.knownCost : t.totals.input + t.totals.output + t.totals.cacheCreation + (mergeTokens ? t.totals.cacheRead : 0);
    }
    samples.push({ day: d, values });
    if (samples.length > 4000) break;
  }
  const average = samples.length ? samples.reduce((s, x) => s + Object.values(x.values).reduce((a, b) => a + (b ?? 0), 0), 0) / samples.length : 0;
  const empty = samples.every((s) => Object.values(s.values).every((v) => !v));
  return (
    <Panel
      title={tr("Daily usage", "每日用量")}
      accessory={
        !empty && (
          <span className="avg-legend num">
            <span className="dash" />
            {tr("avg", "日均")} {formatMetric(average, metric)}
          </span>
        )
      }
      right={
        <span className="panel-controls">
          <span className="legend">
            {apps.map((a) => (
              <span key={a} className="legend-item" title={shortName(a)}>
                <ServiceLogo app={a} size={11} />
                <span className="legend-name">{shortName(a)}</span>
              </span>
            ))}
          </span>
          <MetricPicker metric={metric} setMetric={setMetric} />
        </span>
      }
    >
      {empty ? (
        <div className="placeholder" style={{ height: 104 }}>
          {tr("No usage in this range", "这段时间没有用量")}
        </div>
      ) : (
        <DailyChart key={chartKey} samples={samples} apps={apps} average={average} metric={metric} />
      )}
    </Panel>
  );
}

function MetricPicker({ metric, setMetric }: { metric: Metric; setMetric: (m: Metric) => void }) {
  return (
    <Segmented
      small
      options={[
        { value: "cost", label: tr("Cost", "费用") },
        { value: "tokens", label: "Tokens" },
      ]}
      value={metric}
      onChange={setMetric}
    />
  );
}

// ---------- 单日（今天 / 昨日） ----------

function SingleDayPanel({ index, apps, day, isToday, isYesterday, metric, baseline, setMetric, setBaseline, metricValue, baselineAverage }: {
  index: StatsIndex;
  apps: UsageApp[];
  day: string;
  isToday: boolean;
  isYesterday: boolean;
  metric: Metric;
  baseline: Baseline;
  setMetric: (m: Metric) => void;
  setBaseline: (b: Baseline) => void;
  metricValue: (app: UsageApp, from: string, to: string) => number;
  baselineAverage: (apps: UsageApp[], day: string, value: (from: string, to: string) => number) => number;
}) {
  const next = addDays(day, 1);
  const rows = apps.map((app) => ({
    app,
    value: metricValue(app, day, next),
    average: baselineAverage([app], day, (f, t) => metricValue(app, f, t)),
  }));
  const maxValue = Math.max(0.0001, ...rows.map((r) => Math.max(r.value, r.average)));
  const total = rows.reduce((s, r) => s + r.value, 0);
  const avgTotal = rows.reduce((s, r) => s + r.average, 0);

  // 「今天」旁的火苗：今天全部服务的全部 Token（含缓存）落在热力图哪一档
  const allDaily = index.dailyTokens(["codex", "claude", "grok", "agy"]);
  const todayTokens = allDaily.get(todayString()) ?? 0;
  const level = TokenHeat.level(todayTokens, TokenHeat.thresholds(allDaily, TokenHeat.windowStart()));

  const legend = tr(`Line = ${baselineLine(baseline)}.`, `竖线 = ${baselineLine(baseline)}。`);
  const pct = avgTotal > 0 ? Math.round((total / avgTotal) * 100) : null;
  const progress =
    pct == null
      ? ""
      : isToday
        ? tr(` So far today: ${pct}% of it.`, ` 今天到目前为止为它的 ${pct}%。`)
        : isYesterday
          ? tr(` Yesterday: ${pct}% of it.`, ` 昨日为它的 ${pct}%。`)
          : tr(` That day: ${pct}% of it.`, ` 当天为它的 ${pct}%。`);

  return (
    <Panel
      title={isToday ? tr("Today", "今天") : isYesterday ? tr("Yesterday", "昨日") : tr("This day", "当天")}
      accessory={<span style={{ visibility: isToday ? "visible" : "hidden" }}><TodayFlame level={level} tokens={todayTokens} /></span>}
      right={
        <span className="panel-controls">
          <Segmented small title={tr("Compare against", "对比基准")} options={BASELINES.map((b) => ({ value: b, label: baselineShort(b) }))} value={baseline} onChange={setBaseline} />
          <MetricPicker metric={metric} setMetric={setMetric} />
        </span>
      }
    >
      <div className="single-rows">
        {rows.map((r) => (
          <div className="single-row" key={r.app}>
            <span className="single-name">
              <ServiceLogo app={r.app} size={14} />
              {shortName(r.app) === "Claude" ? "Claude Code" : shortName(r.app)}
            </span>
            <span className="single-bar">
              <span className="single-track" />
              <span className="single-fill" style={{ width: `${Math.min(100, (r.value / maxValue) * 100)}%`, background: accentVar[r.app] }} />
              {r.average > 0 && <span className="single-line" style={{ left: `calc(${Math.min(100, (r.average / maxValue) * 100)}% - 1px)` }} />}
            </span>
            <span className="single-value num">
              {formatMetric(r.value, metric)} / {tr("avg", "均")} {formatMetric(r.average, metric)}
            </span>
          </div>
        ))}
        <div className="footnote">{legend + progress}</div>
      </div>
    </Panel>
  );
}

// ---------- 当前额度 ----------

function CurrentLimits({ state, apps }: { state: StateSnapshot; apps: UsageApp[] }) {
  const now = useTicker(30_000);
  const shown = apps.filter((a) => state.services.find((s) => s.app === a)?.enabled !== false);
  return (
    <Panel title={tr("Current limits", "当前额度")}>
      <div className="limits-grid">
        {shown.map((app, i) => {
          const s = state.services.find((x) => x.app === app)!;
          const lanes = quotaLanes(app, s.quota);
          return (
            <div className={`quota-tile ${i >= 2 ? "with-divider" : ""}`} key={app} title={s.refresh.lastError ?? undefined}>
              <span style={{ paddingTop: 4 }}>
                <ServiceLogo app={app} size={20} />
              </span>
              <div style={{ flex: 1, minWidth: 0 }}>
                {lanes.map((l) => (
                  <LimitBarRow key={l.label} label={l.label} window={l.window} tint={accentVar[app]} labelWidth={lanes.length > 2 ? 100 : 40} mode={state.settings.resetTimeDisplay} now={now} />
                ))}
              </div>
            </div>
          );
        })}
      </div>
    </Panel>
  );
}
