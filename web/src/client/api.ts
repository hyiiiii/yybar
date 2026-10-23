export type App = "codex" | "claude" | "grok";

export interface PublicUser {
  login: string;
  name: string | null;
  avatarUrl: string | null;
  /** 戴在名字后面的成就徽章（最多 3 个） */
  badges?: string[];
}

/** 德州统计：手数和几个比率（0～1，没打过是 null） */
export interface PokerStats {
  hands: number;
  winRate: number | null;
  vpip: number | null;
  pfr: number | null;
  threeBet: number | null;
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
  input: number;
  output: number;
  cache_read: number;
  cache_write: number;
  /** 合计（含缓存） */
  tokens: number;
  cost_micro: number;
}

/** Token 活动：某一天的 token 合计（含缓存） */
export interface ActivityPoint {
  day: string;
  tokens: number;
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
  /** 最近 378 天每天的 token，画 Token 活动热力图 */
  activity: ActivityPoint[];
}

/** 商场里换上的牌背、牌面 */
export interface Look {
  back: string;
  face: string;
}

export interface MeResponse extends Partial<Omit<Profile, "user">> {
  user: (PublicUser & { joinedAt: string; showOnBoard: boolean }) | null;
  look?: Look;
  /** 道具库存 */
  items?: Record<"timecard" | "peek" | "runout", number>;
  /** 自己有的表情 */
  emotes?: string[];
  /** 每日礼盒：今天领过没有、给多少 */
  daily?: { claimed: boolean; amount: number };
  tokens?: { id: number; label: string; created_at: string; last_used_at: string | null }[];
}

/** 燃烧 token 榜的一行：token 数和最常用的模型 */
export interface TokenRow extends PublicUser {
  rank: number;
  tokens: number;
  /** 这些 token 的花费（微美元） */
  costMicro: number;
  topModel: string;
  topApp: App;
}

/** 财富榜的一行：筹码余额 */
export interface WealthRow extends PublicUser {
  rank: number;
  balance: number;
  /** 今天（UTC）在牌桌上的输赢，和今天打了几手 */
  today: number;
  todayHands: number;
  stats: PokerStats;
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
