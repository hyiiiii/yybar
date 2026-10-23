// 预览版用的示例数据：VITE_DEMO=1 构建时，api() 不请求后端，改从这里取。
import type { ActivityPoint, MeResponse, ModelRow, Profile, SeriesPoint, TokenRow, WealthRow } from "./api";
import { localBalance, spendLocal } from "./localTable";
import { ACHIEVEMENTS } from "../shared/achievements";
import { COSMETICS, DEFAULT_BACK, DEFAULT_FACE, findCosmetic, findItem, ITEMS, type CosmeticKind, type ItemId } from "../shared/cosmetics";

const PEOPLE = [
  { login: "hyiiiii", name: "hyi", cost: 1_842.31, tokens: 912_000_000 },
  { login: "nightowl", name: "夜猫子", cost: 1_516.07, tokens: 801_400_000 },
  { login: "token-burner", name: "烧钱机器", cost: 1_203.88, tokens: 655_200_000 },
  { login: "vibe-coder", name: "Vibe Coder", cost: 874.5, tokens: 468_900_000 },
  { login: "mia", name: "Mia", cost: 612.19, tokens: 330_700_000 },
  { login: "lazy-dev", name: "摸鱼大师", cost: 401.02, tokens: 219_300_000 },
  { login: "codex-fan", name: "Codex 信徒", cost: 288.6, tokens: 151_800_000 },
  { login: "grokker", name: "Grokker", cost: 132.44, tokens: 71_000_000 },
];

const SCALE: Record<string, number> = { today: 0.035, "7d": 0.24, "30d": 0.82, all: 1 };

const TOP: [TokenRow["topApp"], string][] = [
  ["claude", "claude-opus-4.5"], ["codex", "gpt-5-codex"], ["claude", "claude-sonnet-4.5"], ["claude", "claude-opus-4.5"],
  ["grok", "grok-4"], ["codex", "gpt-5-codex"], ["codex", "gpt-5"], ["grok", "grok-4"],
];

const DEMO_BADGES: (string | null)[] = [null, "streak_30", "big_pot", null, "first_login", null, "spend_1k", null];

/** 不同模型单价不一样，按花费排和按 token 排名次会不同 */
const PRICE_FACTOR = [1, 0.7, 1.35, 1.6, 0.5, 0.8, 0.9, 0.4];

function tokenBoard(range: string, sort: string): TokenRow[] {
  const k = SCALE[range] ?? 1;
  const rows = PEOPLE.map((p, i) => ({
    login: p.login,
    name: p.name,
    avatarUrl: null,
    tokens: Math.round(p.tokens * k),
    costMicro: Math.round(p.cost * k * PRICE_FACTOR[i] * 1e6),
    badges: p.login === "hyiiiii" ? badges : DEMO_BADGES[i] ? [DEMO_BADGES[i]!] : [],
    topApp: TOP[i][0],
    topModel: TOP[i][1],
  }));
  rows.sort((a, b) => (sort === "cost" ? b.costMicro - a.costMicro : b.tokens - a.tokens));
  return rows.map((r, i) => ({ ...r, rank: i + 1 }));
}

function wealthBoard(sort: string): WealthRow[] {
  const rows = PEOPLE.map((p, i) => ({
    login: p.login, name: p.name, avatarUrl: null,
    badges: p.login === "hyiiiii" ? badges : DEMO_BADGES[i] ? [DEMO_BADGES[i]!] : [],
    stats: demoStats(p.login),
    balance: p.login === "hyiiiii" ? localBalance() : Math.floor(p.cost * 100 * (0.7 + ((i * 37) % 60) / 100)),
    today: ((i * 7919) % 2400) - 1100,
    todayHands: i % 4 === 3 ? 0 : 12 + ((i * 13) % 50) }));
  if (sort === "today") return rows.sort((a, b) => Number(b.todayHands > 0) - Number(a.todayHands > 0) || b.today - a.today).map((r, i) => ({ ...r, rank: i + 1 }));
  return rows.sort((a, b) => b.balance - a.balance).map((r, i) => ({ ...r, rank: i + 1 }));
}

function series(seed: number): SeriesPoint[] {
  const out: SeriesPoint[] = [];
  const today = new Date();
  let x = seed;
  const rnd = () => ((x = (x * 9301 + 49297) % 233280) / 233280);
  for (let i = 0; i < 30; i++) {
    const d = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate() - i)).toISOString().slice(0, 10);
    for (const app of ["codex", "claude", "grok"] as const) {
      if (rnd() < 0.25) continue;
      const usd = (app === "claude" ? 40 : app === "codex" ? 18 : 8) * (0.3 + rnd());
      out.push({ day: d, app, tokens: Math.round(usd * 480_000), cost_micro: Math.round(usd * 1e6) });
    }
  }
  return out;
}

/** 预览用的模型明细：把每天每个服务的用量分给它的几个模型 */
function demoModels(points: SeriesPoint[]): ModelRow[] {
  const split: Record<string, [string, number][]> = {
    claude: [["claude-opus-4.5", 0.75], ["claude-sonnet-4.5", 0.25]],
    codex: [["gpt-5-codex", 1]],
    grok: [["grok-4", 1]],
  };
  return points.flatMap((p) =>
    split[p.app].map(([model, share]) => {
      const tokens = p.tokens * share;
      return {
        day: p.day, app: p.app, model, cost_micro: Math.round(p.cost_micro * share),
        input: Math.round(tokens * 0.04), output: Math.round(tokens * 0.03), cache_read: Math.round(tokens * 0.88),
        cache_write: p.app === "claude" ? Math.round(tokens * 0.05) : 0,
      };
    }),
  );
}

/** 预览用的 Token 活动：最近 378 天，越近用得越多，周末少一点，偶尔歇一天；按 Claude / Codex / Grok 大概六三一分 */
function activity(seed: number, total: number): ActivityPoint[] {
  const out: ActivityPoint[] = [];
  const today = new Date();
  let x = seed;
  const rnd = () => ((x = (x * 9301 + 49297) % 233280) / 233280);
  for (let i = 377; i >= 0; i--) {
    const d = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate() - i));
    if (i > 240 || rnd() < 0.18) continue;
    const weekend = d.getUTCDay() === 0 || d.getUTCDay() === 6 ? 0.45 : 1;
    const day = d.toISOString().slice(0, 10);
    const tokens = Math.round((total / 160) * weekend * (0.2 + rnd() * 1.6) * (1.4 - i / 300));
    out.push({ day, app: "claude", tokens: Math.round(tokens * 0.6) }, { day, app: "codex", tokens: Math.round(tokens * 0.3) });
    if (rnd() < 0.4) out.push({ day, app: "grok", tokens: Math.round(tokens * 0.1) });
  }
  return out;
}

function profile(login: string): Profile {
  const p = PEOPLE.find((x) => x.login === login) ?? PEOPLE[0];
  const cost = Math.round(p.cost * 1e6);
  return {
    user: { login: p.login, name: p.name, avatarUrl: null, joinedAt: "2026-09-02T10:00:00Z" },
    totals: {
      active_days: 41,
      input_tokens: Math.round(p.tokens * 0.04),
      output_tokens: Math.round(p.tokens * 0.03),
      cache_read_tokens: Math.round(p.tokens * 0.88),
      cache_creation_tokens: Math.round(p.tokens * 0.05),
      cost_micro: cost,
    },
    series: series(p.login.length * 7),
    models: demoModels(series(p.login.length * 7)),
    activity: activity(p.login.length * 13, p.tokens),
    points: { earned: Math.floor(p.cost * 100), balance: Math.floor(p.cost * 100) - 23_650 },
  };
}

let loggedIn = false;
let showOnBoard = true;
/** 预览里的商场：买过的款式、正在用的、道具库存（先送几张试试） */
const owned = new Set<string>();
const look = { back: DEFAULT_BACK, face: DEFAULT_FACE };
const stock: Record<ItemId, number> = { timecard: 2, peek: 1, runout: 1 };

/** 预览里的成就：这几个算已经解锁 */
const demoUnlocked: Record<string, string> = { first_login: "2026-09-02", streak_7: "2026-09-20", tokens_100m: "2026-09-28", top_today: "2026-10-12", spend_1k: "2026-10-15" };
let badges: string[] = ["top_today", "streak_7"];
/** 预览里每日礼盒今天领过没有 */
let dailyClaimed = false;

/** 预览里的德州统计：按名字算一组看着像样的数 */
function demoStats(login: string) {
  let h = 0;
  for (const ch of login) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  const r = (k: number) => ((h >> k) % 1000) / 1000;
  return { hands: 120 + (h % 2400), winRate: 0.18 + r(3) * 0.2, vpip: 0.16 + r(5) * 0.3, pfr: 0.08 + r(7) * 0.18, threeBet: 0.03 + r(9) * 0.09 };
}

export function demoBadges() {
  return badges;
}

export function demoLook() {
  return look;
}

export function demoEmotes() {
  return COSMETICS.filter((c) => c.kind === "emote" && (c.price === 0 || owned.has(`emote:${c.id}`))).map((c) => c.id);
}

/** 预览牌桌上用掉一个道具；没有了返回 false */
export function demoSpend(item: ItemId) {
  if (!stock[item]) return false;
  stock[item] -= 1;
  return true;
}

export function demoApi(path: string, method: string, _json?: unknown): unknown {
  const url = new URL(path, "https://demo.local");
  if (url.pathname === "/api/leaderboard") {
    return url.searchParams.get("by") === "wealth" ? { rows: wealthBoard(url.searchParams.get("sort") ?? "balance") } : { rows: tokenBoard(url.searchParams.get("range") ?? "7d", url.searchParams.get("sort") ?? "tokens") };
  }
  if (url.pathname === "/api/achievements") {
    if (!loggedIn) return { achievements: ACHIEVEMENTS.map((a) => ({ ...a, unlockedAt: null })), progress: null, badge: null };
    return {
      achievements: ACHIEVEMENTS.map((a) => ({ ...a, unlockedAt: demoUnlocked[a.id] ? `${demoUnlocked[a.id]}T08:00:00Z` : null })),
      progress: { streak: 23, tokens: 912_000_000, spend: 1_842 },
      badges,
    };
  }
  if (url.pathname === "/api/achievements/wear") {
    const { id, on } = (_json ?? {}) as { id: string; on: boolean };
    const rest = badges.filter((b) => b !== id);
    if (on && rest.length >= 3) throw new Error("最多戴 3 个徽章");
    badges = on ? [...rest, id] : rest;
    return { ok: true, badges };
  }
  if (url.pathname.startsWith("/api/stats/")) {
    const login = decodeURIComponent(url.pathname.slice(11));
    return { user: { login, name: login, avatarUrl: null, badges: login === "hyiiiii" ? badges : [] }, stats: demoStats(login) };
  }
  if (url.pathname === "/api/me/daily") {
    const amount = dailyClaimed ? 0 : 100;
    const item = dailyClaimed ? null : ITEMS[Math.floor(Math.random() * ITEMS.length)].id;
    if (!dailyClaimed) spendLocal(-100);
    if (item) stock[item] += 1;
    dailyClaimed = true;
    return { ok: true, amount, item };
  }
  if (url.pathname === "/api/shop") {
    return {
      cosmetics: COSMETICS.map((x) => ({ ...x, owned: loggedIn && (x.price === 0 || owned.has(`${x.kind}:${x.id}`)) })),
      items: ITEMS.map((x) => ({ ...x, qty: loggedIn ? stock[x.id] : 0 })),
      equipped: loggedIn ? look : null,
    };
  }
  if (url.pathname === "/api/shop/buy" || url.pathname === "/api/shop/equip") {
    const { kind, id } = (_json ?? {}) as { kind: CosmeticKind | "item"; id: string };
    if (kind === "item") {
      const it = findItem(id);
      if (!it) throw new Error("没有这件商品");
      if (localBalance() < it.price) throw new Error("筹码不够");
      spendLocal(it.price);
      stock[it.id] += 1;
      return { ok: true };
    }
    const item = findCosmetic(kind, id);
    if (!item) throw new Error("没有这件商品");
    const key = `${kind}:${id}`;
    if (url.pathname.endsWith("buy") && item.price && !owned.has(key)) {
      if (localBalance() < item.price) throw new Error("筹码不够");
      spendLocal(item.price);
      owned.add(key);
    }
    if (url.pathname.endsWith("equip") && (kind === "back" || kind === "face")) look[kind] = id;
    return { ok: true };
  }
  if (url.pathname.startsWith("/api/users/")) return profile(decodeURIComponent(url.pathname.slice(11)));
  if (url.pathname === "/api/me" && method === "PATCH") return (showOnBoard = !showOnBoard), { ok: true };
  if (url.pathname === "/api/me") {
    if (!loggedIn) return { user: null } satisfies MeResponse;
    const p = profile("hyiiiii");
    return {
      ...p,
      user: { ...p.user, showOnBoard, badges },
      daily: { claimed: dailyClaimed, amount: 100 },
      look: { ...look },
      items: { ...stock },
      emotes: demoEmotes(),
      // 余额跟着预览牌桌的带入、离桌变
      points: { ...p.points, balance: localBalance() },
      // 上传记录：近 30 天里有用量的日子，第二天早上传上来
      uploads: [...new Set(p.series.map((x) => x.day))].sort().reverse().map((day) => {
        const rows = p.series.filter((x) => x.day === day);
        const next = new Date(`${day}T00:00:00Z`);
        next.setUTCDate(next.getUTCDate() + 1);
        return { day, uploaded_at: `${next.toISOString().slice(0, 10)}T01:12:00Z`, tokens: rows.reduce((a, x) => a + x.tokens, 0), cost_micro: rows.reduce((a, x) => a + x.cost_micro, 0) };
      }),
    } satisfies MeResponse;
  }
  if (url.pathname === "/api/me/tokens") return { token: "yyb_demo_仅预览不可用" };
  if (url.pathname === "/auth/logout") return (loggedIn = false), { ok: true };
  if (url.pathname === "/api/me/connect") return { redirect: "#" };
  return { ok: true };
}

/** 预览版里「用 GitHub 登录」直接切到已登录状态。 */
export function demoLogin() {
  loggedIn = true;
}
