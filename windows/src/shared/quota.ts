// 额度窗口的展示规则（对应 Mac `QuotaCardView.standardWindows / grokWindows`、`MenuBarPopoverView.shortLabel`、
// 统计页 `quotaLanes`）。

import { tr } from "./l10n";
import type { QuotaPool, QuotaSnapshot, QuotaWindow, UsageApp } from "./types";

export interface CardWindow {
  id: string;
  label: string;
  window: QuotaWindow | null;
}

export const remaining = (w: QuotaWindow | null | undefined): number | null =>
  w ? Math.max(0, Math.min(100, 100 - w.usedPercent)) : null;

function lengthLabel(w: QuotaWindow | null | undefined, fallback: string): string {
  const seconds = w?.windowSeconds;
  if (!seconds || seconds <= 0) return fallback;
  const hours = seconds / 3600;
  if (hours < 24) return tr(`${Math.round(hours)}-hour`, `${Math.round(hours)} 小时`);
  if (hours < 48) return tr("Daily", "每天");
  if (hours < 24 * 14) return tr("Weekly", "每周");
  return tr("Monthly", "每月");
}

/** Codex / Claude / Antigravity：5H 与 WK 并列；有数据的窗口才显示（都没有时两个都显示 --）。 */
export function standardWindows(s: QuotaSnapshot | null | undefined): CardWindow[] {
  if (s?.pools) {
    return s.pools.flatMap((p) => [
      { id: `${p.label}-5h`, label: `${p.label} ${tr("5h", "5 小时")}`, window: p.fiveHour ?? null },
      { id: `${p.label}-wk`, label: `${p.label} ${tr("weekly", "每周")}`, window: p.weekly ?? null },
    ]);
  }
  const all: CardWindow[] = [
    { id: "5h", label: lengthLabel(s?.fiveHour, tr("5-hour", "5 小时")), window: s?.fiveHour ?? null },
    { id: "wk", label: lengthLabel(s?.weekly, tr("Weekly", "每周")), window: s?.weekly ?? null },
  ];
  const present = all.filter((w) => w.window);
  return present.length ? present : all;
}

/** Grok：只有云端当前周期一个窗口。标签形如 "WEEK · 本周"，按界面语言取一半。 */
export function grokWindows(s: QuotaSnapshot | null | undefined): CardWindow[] {
  const parts = (s?.primaryLabel ?? "PERIOD · 当前周期").split(" · ");
  const label = parts.length === 2 ? tr(parts[0][0] + parts[0].slice(1).toLowerCase(), parts[1]) : parts[0];
  return [{ id: "period", label, window: s?.primary ?? s?.weekly ?? null }];
}

export function windowsFor(app: UsageApp, s: QuotaSnapshot | null | undefined): CardWindow[] {
  return app === "grok" ? grokWindows(s) : standardWindows(s);
}

/** 浮窗里的短标签：按窗口实际长度写 5H / 1D / WK / MO；Antigravity 前面加池名。 */
export function shortLabel(item: CardWindow, pools: QuotaPool[] | null | undefined): string {
  let code: string;
  const seconds = item.window?.windowSeconds;
  if (seconds && seconds > 0) {
    const hours = seconds / 3600;
    if (hours < 24) code = `${Math.round(hours)}H`;
    else if (hours < 48) code = "1D";
    else if (hours < 24 * 14) code = "WK";
    else code = "MO";
  } else {
    code = item.id.endsWith("5h") ? "5H" : "WK";
  }
  const pool = pools?.find((p) => item.id.startsWith(p.label + "-"));
  return pool ? `${pool.label} ${code}` : code;
}

/** 统计 ·「当前额度」每格的行：5H / WK；Grok 只有周期一行；Antigravity 每池两行。 */
export function quotaLanes(app: UsageApp, s: QuotaSnapshot | null | undefined): { label: string; window: QuotaWindow | null }[] {
  if (app === "grok") {
    const period = (s?.primaryLabel ?? "WEEK · 本周").split(" · ")[0];
    const label = period === "MONTH" ? "MO" : period === "DAY" ? "DAY" : period === "PERIOD" ? tr("Period", "周期") : "WK";
    return [{ label, window: s?.primary ?? s?.weekly ?? null }];
  }
  if (s?.pools) {
    return s.pools.flatMap((p) => [
      { label: `${p.label} 5H`, window: p.fiveHour ?? null },
      { label: `${p.label} WK`, window: p.weekly ?? null },
    ]);
  }
  // 标签按窗口长度写（免费 ChatGPT 账号的长窗口是每月，写 MO）；没有 5H 的只列长窗口
  const lanes = [
    { label: shortLabel({ id: "5h", label: "", window: s?.fiveHour ?? null }, null), window: s?.fiveHour ?? null },
    { label: shortLabel({ id: "wk", label: "", window: s?.weekly ?? null }, null), window: s?.weekly ?? null },
  ];
  const present = lanes.filter((l) => l.window);
  return present.length ? present : lanes;
}

/** 悬浮窗那一行的数：Grok 取周期，其余 5H（没有时 WK）。 */
export function headlineWindow(app: UsageApp, s: QuotaSnapshot | null | undefined): QuotaWindow | null {
  if (!s) return null;
  if (app === "grok") return s.primary ?? s.weekly ?? null;
  return s.fiveHour ?? s.weekly ?? null;
}
