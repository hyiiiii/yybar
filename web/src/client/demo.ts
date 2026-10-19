// 预览版用的示例数据：VITE_DEMO=1 构建时，api() 不请求后端，改从这里取。
import type { MeResponse, Profile, SeriesPoint, TokenRow, WealthRow } from "./api";
import { localBalance, spendLocal } from "./localTable";
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

function tokenBoard(range: string): TokenRow[] {
  const k = SCALE[range] ?? 1;
  return PEOPLE.map((p, i) => ({
    rank: i + 1,
    login: p.login,
    name: p.name,
    avatarUrl: null,
    tokens: Math.round(p.tokens * k),
    topApp: TOP[i][0],
    topModel: TOP[i][1],
  }));
}

function wealthBoard(): WealthRow[] {
  const rows = PEOPLE.map((p, i) => ({ login: p.login, name: p.name, avatarUrl: null, balance: p.login === "hyiiiii" ? localBalance() : Math.floor(p.cost * 100 * (0.7 + ((i * 37) % 60) / 100)) }));
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
    models: [
      { app: "claude", model: "claude-opus-4.5", tokens: Math.round(p.tokens * 0.46), cost_micro: Math.round(cost * 0.52) },
      { app: "codex", model: "gpt-5-codex", tokens: Math.round(p.tokens * 0.31), cost_micro: Math.round(cost * 0.27) },
      { app: "claude", model: "claude-sonnet-4.5", tokens: Math.round(p.tokens * 0.15), cost_micro: Math.round(cost * 0.14) },
      { app: "grok", model: "grok-4", tokens: Math.round(p.tokens * 0.08), cost_micro: Math.round(cost * 0.07) },
    ],
    points: { earned: Math.floor(p.cost * 100), balance: Math.floor(p.cost * 100) - 23_650 },
  };
}

let loggedIn = false;
let showOnBoard = true;
/** 预览里的商场：买过的款式、正在用的、道具库存（先送几张试试） */
const owned = new Set<string>();
const look = { back: DEFAULT_BACK, face: DEFAULT_FACE };
const stock: Record<ItemId, number> = { timecard: 2, peek: 1, runout: 1 };

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
    return url.searchParams.get("by") === "wealth" ? { rows: wealthBoard() } : { rows: tokenBoard(url.searchParams.get("range") ?? "7d") };
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
      user: { ...p.user, showOnBoard },
      look: { ...look },
      items: { ...stock },
      emotes: demoEmotes(),
      // 余额跟着预览牌桌的带入、离桌变
      points: { ...p.points, balance: localBalance() },
      tokens: [{ id: 1, label: "yybar App", created_at: "2026-10-17T08:00:00Z", last_used_at: "2026-10-17T16:05:00Z" }],
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
