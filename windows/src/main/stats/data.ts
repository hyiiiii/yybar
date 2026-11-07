// 统计页的数据与口径（对应 Mac `StatsView` 的 StatsRange / StatsDataIndex / 每日序列 / TokenHeat）。

import { dayString, parseDay } from "../../shared/format";
import { tr } from "../../shared/l10n";
import { hasDisplayableCost } from "../../shared/pricing";
import type { StateSnapshot, UsageApp, UsageBucket } from "../../shared/types";
import { addBucket, emptyTotals, type Totals } from "../../shared/usage";

export type StatsRange = "today" | "yesterday" | "last7" | "last30" | "all" | "custom";
export type ServiceFilter = "all" | UsageApp;
export type Metric = "cost" | "tokens";
export type Baseline = "yesterday" | "sevenDays" | "thirtyDays" | "all";

export const RANGES: StatsRange[] = ["today", "yesterday", "last7", "last30", "all", "custom"];

export function rangeLabel(r: StatsRange): string {
  switch (r) {
    case "today":
      return tr("Today", "今天");
    case "yesterday":
      return tr("Yesterday", "昨日");
    case "last7":
      return tr("7d", "7 天");
    case "last30":
      return tr("30d", "30 天");
    case "all":
      return tr("All", "全部");
    case "custom":
      return tr("Custom", "自定义");
  }
}

export const MIN_DAY = "0000-01-01";
export const MAX_DAY = "9999-12-31";

export function addDays(day: string, n: number): string {
  const d = parseDay(day);
  d.setDate(d.getDate() + n);
  return dayString(d);
}

export function todayString(): string {
  return dayString(new Date());
}

/** [from, to) 的本地日期区间。 */
export interface Bounds {
  from: string;
  to: string;
}

export function rangeBounds(range: StatsRange, customFrom: string, customTo: string): Bounds {
  const today = todayString();
  const tomorrow = addDays(today, 1);
  switch (range) {
    case "today":
      return { from: today, to: tomorrow };
    case "yesterday":
      return { from: addDays(today, -1), to: today };
    case "last7":
      return { from: addDays(today, -6), to: tomorrow };
    case "last30":
      return { from: addDays(today, -29), to: tomorrow };
    case "all":
      return { from: MIN_DAY, to: MAX_DAY };
    case "custom": {
      const to = addDays(customTo, 1);
      return { from: customFrom, to: to > customFrom ? to : customFrom };
    }
  }
}

export function dayCount(b: Bounds): number {
  return Math.round((parseDay(b.to).getTime() - parseDay(b.from).getTime()) / 86400000);
}

/** 上一个等长区间（环比）。全部 / 自定义没有。 */
export function previousBounds(range: StatsRange, customFrom: string, customTo: string): Bounds | null {
  if (range === "all" || range === "custom") return null;
  const cur = rangeBounds(range, customFrom, customTo);
  const n = dayCount(cur);
  return { from: addDays(cur.from, -n), to: cur.from };
}

export function isSingleDay(b: Bounds): boolean {
  return b.from !== MIN_DAY && dayCount(b) <= 1;
}

export interface DayTotals {
  totals: Totals;
  knownCost: number;
  hasUnknown: boolean;
}

const emptyDay = (): DayTotals => ({ totals: emptyTotals(), knownCost: 0, hasUnknown: false });

/** 用量按 (服务, 天) 预先汇总；数据版本变化时才重建。 */
export class StatsIndex {
  readonly perDay = new Map<UsageApp, Map<string, DayTotals>>();
  readonly firstDays = new Map<UsageApp, string>();

  constructor(
    readonly buckets: UsageBucket[],
    state: StateSnapshot,
  ) {
    for (const b of buckets) {
      let days = this.perDay.get(b.app);
      if (!days) this.perDay.set(b.app, (days = new Map()));
      let d = days.get(b.day);
      if (!d) days.set(b.day, (d = emptyDay()));
      addBucket(d.totals, b);
      if (hasDisplayableCost(state, b.app, b.model, b.costUSD)) d.knownCost += b.costUSD;
      else d.hasUnknown = true;
      const first = this.firstDays.get(b.app);
      if (!first || b.day < first) this.firstDays.set(b.app, b.day);
    }
  }

  sum(apps: UsageApp[], from: string, to: string): DayTotals {
    const out = emptyDay();
    for (const app of apps) {
      const days = this.perDay.get(app);
      if (!days) continue;
      for (const [day, d] of days) {
        if (day < from || day >= to) continue;
        out.totals.input += d.totals.input;
        out.totals.output += d.totals.output;
        out.totals.cacheRead += d.totals.cacheRead;
        out.totals.cacheCreation += d.totals.cacheCreation;
        out.totals.cost += d.totals.cost;
        out.knownCost += d.knownCost;
        out.hasUnknown ||= d.hasUnknown;
      }
    }
    return out;
  }

  firstDay(apps: UsageApp[], before: string): string | null {
    const days = apps.map((a) => this.firstDays.get(a)).filter((d): d is string => !!d && d < before);
    return days.length ? days.sort()[0] : null;
  }

  /** 所选服务按天的全部 token（含缓存）。 */
  dailyTokens(apps: UsageApp[]): Map<string, number> {
    const out = new Map<string, number>();
    for (const app of apps) {
      for (const [day, d] of this.perDay.get(app) ?? []) {
        const t = d.totals;
        out.set(day, (out.get(day) ?? 0) + t.input + t.output + t.cacheRead + t.cacheCreation);
      }
    }
    return out;
  }
}

/** Token 活动热力图和「今天」火苗共用的分档：最近 53 周里有用量的日子按 25% / 50% / 75% 分位分 1~4 档。 */
export const TokenHeat = {
  windowStart(): string {
    const today = parseDay(todayString());
    const monday = new Date(today);
    monday.setDate(today.getDate() - ((today.getDay() + 6) % 7) - 52 * 7);
    return dayString(monday);
  },
  thresholds(daily: Map<string, number>, since: string): number[] {
    const values = [...daily].filter(([d, v]) => d >= since && v > 0).map(([, v]) => v).sort((a, b) => a - b);
    if (!values.length) return [];
    return [0.25, 0.5, 0.75].map((q) => values[Math.min(values.length - 1, Math.floor(values.length * q))]);
  },
  level(value: number, thresholds: number[]): number {
    if (value <= 0) return 0;
    if (thresholds.length !== 3) return 4;
    if (value <= thresholds[0]) return 1;
    if (value <= thresholds[1]) return 2;
    if (value <= thresholds[2]) return 3;
    return 4;
  },
};

/** 纵轴上限取不小于 value 的「整齐」数。 */
export function niceCeiling(value: number): number {
  if (!(value > 0) || !isFinite(value)) return 1;
  const mag = Math.pow(10, Math.floor(Math.log10(value)));
  for (const step of [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]) if (step * mag >= value * 0.999999) return step * mag;
  return 10 * mag;
}

/** 纵轴刻度：0 到 top，步长约 top / 3 的整齐数。 */
export function axisTicks(top: number): number[] {
  if (!(top > 0)) return [0];
  const raw = top / 3;
  const mag = Math.pow(10, Math.floor(Math.log10(raw)));
  const step = [1, 2, 2.5, 5, 10].map((s) => s * mag).find((s) => s >= raw * 0.999999) ?? raw;
  const out: number[] = [];
  for (let v = 0; v <= top * 1.000001; v += step) out.push(v);
  return out;
}
