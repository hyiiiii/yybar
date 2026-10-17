export type App = "codex" | "claude" | "grok";

export interface PublicUser {
  login: string;
  name: string | null;
  avatarUrl: string | null;
}

export interface Totals {
  active_days: number;
  input_tokens: number;
  output_tokens: number;
  cache_read_tokens: number;
  cache_creation_tokens: number;
  cost_micro: number;
}

export interface SeriesPoint {
  day: string;
  app: App;
  tokens: number;
  cost_micro: number;
}

export interface ModelRow {
  app: App;
  model: string;
  tokens: number;
  cost_micro: number;
}

export interface Points {
  earned: number;
  balance: number;
}

export interface Profile {
  user: PublicUser & { joinedAt: string; showOnBoard?: boolean };
  totals: Totals;
  series: SeriesPoint[];
  models: ModelRow[];
  points: Points;
}

export interface MeResponse extends Partial<Omit<Profile, "user">> {
  user: (PublicUser & { joinedAt: string; showOnBoard: boolean }) | null;
  tokens?: { id: number; label: string; created_at: string; last_used_at: string | null }[];
}

export interface LeaderboardRow extends PublicUser {
  rank: number;
  costMicro: number;
  tokens: number;
}

export async function api<T>(path: string, init?: RequestInit & { json?: unknown }): Promise<T> {
  if (import.meta.env.VITE_DEMO) {
    const { demoApi } = await import("./demo");
    return demoApi(path, init?.method ?? "GET", init?.json) as T;
  }
  const res = await fetch(path, {
    ...init,
    headers: init?.json !== undefined ? { "content-type": "application/json" } : undefined,
    body: init?.json !== undefined ? JSON.stringify(init.json) : init?.body,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error((data as { error?: string }).error ?? `请求失败（${res.status}）`);
  return data as T;
}

export const APP_LABEL: Record<App, string> = { codex: "Codex", claude: "Claude Code", grok: "Grok" };

export function fmtUSD(micro: number): string {
  const usd = micro / 1_000_000;
  return `$${usd.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export function fmtTokens(n: number): string {
  if (n >= 1e9) return `${(n / 1e9).toFixed(2)}B`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)}K`;
  return String(n);
}

export function fmtInt(n: number): string {
  return n.toLocaleString("en-US");
}
