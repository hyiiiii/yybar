import type { AppId, QuotaWindow, ServiceView } from "./types";

export const APP_NAME: Record<AppId, string> = {
  codex: "Codex",
  claude: "Claude Code",
  grok: "Grok",
};

export const SHORT_NAME: Record<AppId, string> = {
  codex: "Codex",
  claude: "Claude",
  grok: "Grok",
};

export function remaining(w: QuotaWindow | null | undefined): number | null {
  if (!w) return null;
  return Math.max(0, Math.min(100, 100 - w.usedPercent));
}

/** 额度状态四档：剩余 >50% 正常、20%~50% 提醒、<20% 偏低、=0 用完（docs/设计风格.md §4.3） */
export function statusClass(rem: number | null): string {
  if (rem === null) return "st-none";
  if (rem <= 0) return "st-empty";
  if (rem < 20) return "st-low";
  if (rem <= 50) return "st-warn";
  return "st-ok";
}

export function pct(rem: number | null): string {
  return rem === null ? "--%" : `${Math.round(rem)}%`;
}

/** 服务里最紧张的一档 */
export function tightest(s: ServiceView): number | null {
  const q = s.quota;
  if (!q) return null;
  const values = [q.fiveHour, q.weekly, q.primary].map(remaining).filter((v): v is number => v !== null);
  return values.length ? Math.min(...values) : null;
}

export function usd(v: number): string {
  if (v >= 1000) return `$${(v / 1000).toFixed(1)}k`;
  if (v >= 100) return `$${v.toFixed(0)}`;
  return `$${v.toFixed(2)}`;
}

export function tokens(v: number): string {
  if (v >= 1e9) return `${(v / 1e9).toFixed(1)}B`;
  if (v >= 1e6) return `${(v / 1e6).toFixed(1)}M`;
  if (v >= 1e3) return `${(v / 1e3).toFixed(0)}k`;
  return `${v}`;
}

export function resetText(resetsAt: number | null, asClock: boolean, now = Date.now() / 1000): string {
  if (!resetsAt) return "重置时间未知";
  const secs = Math.max(0, resetsAt - now);
  if (asClock) {
    const d = new Date(resetsAt * 1000);
    const today = new Date(now * 1000);
    const hm = `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
    if (d.toDateString() === today.toDateString()) return `${hm} 重置`;
    return `${d.getMonth() + 1}月${d.getDate()}日 ${hm} 重置`;
  }
  const days = Math.floor(secs / 86400);
  const hours = Math.floor((secs % 86400) / 3600);
  const mins = Math.floor((secs % 3600) / 60);
  if (days > 0) return `${days} 天 ${hours} 小时后重置`;
  if (hours > 0) return `${hours} 小时 ${mins} 分后重置`;
  return `${Math.max(1, mins)} 分钟后重置`;
}

export function ago(ts: number | null, now = Date.now() / 1000): string {
  if (!ts) return "等待数据";
  const s = Math.max(0, Math.round(now - ts));
  if (s < 60) return `${s} 秒前刷新`;
  if (s < 3600) return `${Math.floor(s / 60)} 分钟前刷新`;
  return `${Math.floor(s / 3600)} 小时前刷新`;
}

export function planLabel(plan: string | null): string | null {
  if (!plan) return null;
  const p = plan.toLowerCase();
  const map: Record<string, string> = { plus: "Plus", pro: "Pro", team: "Team", max: "Max", free: "Free", enterprise: "Enterprise" };
  return map[p] ?? plan;
}
