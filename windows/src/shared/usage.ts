// 用量汇总的小工具（今日合计、本周开始等）。

import { dayString } from "./format";
import type { UsageApp, UsageBucket } from "./types";

export interface Totals {
  input: number;
  output: number;
  cacheRead: number;
  cacheCreation: number;
  cost: number;
}

export const emptyTotals = (): Totals => ({ input: 0, output: 0, cacheRead: 0, cacheCreation: 0, cost: 0 });

export const allTokens = (t: Totals) => t.input + t.output + t.cacheRead + t.cacheCreation;
/** 不含缓存读取（输入 + 输出 + 缓存写入）。 */
export const nonCacheReadTokens = (t: Totals) => t.input + t.output + t.cacheCreation;

export function addBucket(t: Totals, b: UsageBucket) {
  t.input += b.inputTokens;
  t.output += b.outputTokens;
  t.cacheRead += b.cacheReadTokens;
  t.cacheCreation += b.cacheCreationTokens;
  t.cost += b.costUSD;
}

/** [from, to) 区间（YYYY-MM-DD 字符串比较）内、所选服务的合计。 */
export function totalsBetween(buckets: UsageBucket[], from: string, to: string, apps?: UsageApp[]): Totals {
  const t = emptyTotals();
  for (const b of buckets) {
    if (b.day >= from && b.day < to && (!apps || apps.includes(b.app))) addBucket(t, b);
  }
  return t;
}

/** 本地今天 / 明天 / 本周一（周一开头）。 */
export function dayBounds(now = new Date()) {
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const tomorrow = new Date(today);
  tomorrow.setDate(today.getDate() + 1);
  const week = new Date(today);
  week.setDate(today.getDate() - ((today.getDay() + 6) % 7));
  return { today: dayString(today), tomorrow: dayString(tomorrow), weekStart: dayString(week) };
}
