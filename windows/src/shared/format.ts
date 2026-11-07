// 数字、金额、时间的格式化（对应 Mac `StatsFormatter`、`L10n.swift` 的重置时间、`RelativeTime`）。

import { isChinese, tr } from "./l10n";
import type { ResetTimeDisplay } from "./types";

const pad = (n: number) => String(n).padStart(2, "0");

export function nowSecs() {
  return Date.now() / 1000;
}

/** $1,234.56 */
export function cost(value: number): string {
  return "$" + value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

/** 卡片底部的取整金额：<$1 用于 0~0.99，null 显示 —。 */
export function costInt(value: number | null | undefined): string {
  if (value == null) return "—";
  if (value <= 0) return "$0";
  if (value < 1) return "<$1";
  return "$" + Math.round(value).toLocaleString("en-US");
}

function trimZeros(v: number) {
  return v.toFixed(2).replace(/\.?0+$/, "");
}

/** 紧凑显示。中文用 万 / 亿，英文用 k / M / B。 */
export function compactToken(value: number): string {
  const v = Math.round(value);
  if (isChinese()) {
    if (v >= 100_000_000) return `${trimZeros(v / 100_000_000)} 亿`;
    if (v >= 10_000) return `${trimZeros(v / 10_000)} 万`;
    return v.toLocaleString("en-US");
  }
  if (v >= 1_000_000_000) return `${(v / 1_000_000_000).toFixed(2)}B`;
  if (v >= 1_000_000) return `${(v / 1_000_000).toFixed(2)}M`;
  if (v >= 1_000) return `${(v / 1_000).toFixed(1)}k`;
  return String(v);
}

/** 模型明细：中文下不足 1 万的数也带单位（如「850 个」）。 */
export function tableToken(value: number): string {
  if (isChinese() && value > 0 && value < 10_000) return `${compactToken(value)} 个`;
  return compactToken(value);
}

export function dayString(d: Date): string {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

export function parseDay(s: string): Date {
  const [y, m, d] = s.split("-").map(Number);
  return new Date(y, m - 1, d);
}

export function timeString(secs: number): string {
  const d = new Date(secs * 1000);
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/** 45s / 12m / 3h / 2d */
export function relativeShort(from: number, now = nowSecs()): string {
  const s = Math.max(0, Math.floor(now - from));
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h`;
  return `${Math.floor(h / 24)}d`;
}

function compactRelative(resetsAt: number, now: number): string {
  const seconds = Math.max(0, Math.floor(resetsAt - now));
  if (seconds < 60) return "<1m";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  const rm = minutes % 60;
  if (hours < 24) return rm > 0 ? `${hours}h${rm}m` : `${hours}h`;
  const days = Math.floor(hours / 24);
  const rh = hours % 24;
  return rh > 0 ? `${days}d${rh}h` : `${days}d`;
}

function absolute(resetsAt: number, now: number, alwaysDate: boolean): string {
  const d = new Date(resetsAt * 1000);
  const today = new Date(now * 1000);
  const sameDay = d.toDateString() === today.toDateString();
  const time = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  return sameDay && !alwaysDate ? time : `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${time}`;
}

/** 紧凑形式：4h37m / 5d3h / <1m，或绝对时间 MM-dd HH:mm（按设置）。 */
export function resetCompact(resetsAt: number | null | undefined, mode: ResetTimeDisplay, now = nowSecs()): string {
  if (resetsAt == null) return "—";
  return mode === "absolute" ? absolute(resetsAt, now, true) : compactRelative(resetsAt, now);
}

/** 悬停时显示的「相反格式」。 */
export function resetAltCompact(resetsAt: number | null | undefined, mode: ResetTimeDisplay, now = nowSecs()): string {
  if (resetsAt == null) return "—";
  return mode === "relative" ? absolute(resetsAt, now, false) : compactRelative(resetsAt, now);
}

export function quotaDelta(value: number): string {
  return value > 0 ? `+${value}%` : `${value}%`;
}

export function monthDayLabel(d: Date): string {
  return isChinese() ? `${d.getMonth() + 1}月${d.getDate()}日` : d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}

export function longDate(d: Date): string {
  return isChinese()
    ? `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日`
    : d.toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric" });
}

export function shortMonth(d: Date): string {
  return isChinese() ? `${d.getMonth() + 1}月` : d.toLocaleDateString("en-US", { month: "short" });
}

export const answersHint = () => tr("answers", "次");
