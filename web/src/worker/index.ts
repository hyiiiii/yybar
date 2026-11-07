import { Hono } from "hono";
import { authRoutes, requireApiToken, requireSession, sessionUser } from "./auth";
import { AccountsError, parseAccounts, parseDevice, plansOf, saveAccounts } from "./accounts";
import { achievementRoutes, readyCount, syncAchievements } from "./achievements";
import { parseBadges } from "../shared/achievements";
import { ITEMS } from "../shared/cosmetics";
import { emotesOf, itemsOf, lookOf, shopRoutes } from "./shop";
import { tableRoutes } from "./tables";
import type { AppEnv } from "./types";
import { loadPrices, parseUpload, saveUpload, uploadedPairs, uploadHistory, UploadError } from "./usage";
import { addDays, isoDay, pointsFromMicro, randomToken, sha256 } from "./util";

const app = new Hono<AppEnv>();

app.route("/auth", authRoutes);

/** 每日礼盒的筹码 */
const DAILY_GIFT = 100;

/** 时间段：从几天前到几天前（含）。App 只传已经过完的天，所以网页上用「昨天」不用「今天」；today 留给旧页面 */
const RANGES: Record<string, { from: number | null; to: number }> = {
  yesterday: { from: 1, to: 1 },
  today: { from: 0, to: 0 },
  "7d": { from: 6, to: 0 },
  "30d": { from: 29, to: 0 },
  all: { from: null, to: 0 },
};

/** 起止日期（含）。日期按上传者本地时区记录，这里以 UTC 今天为基准往前推。 */
function rangeDays(range: string): { start: string | null; end: string } {
  const r = RANGES[range];
  const today = isoDay(new Date());
  return { start: r?.from === null || r?.from === undefined ? null : addDays(today, -r.from), end: addDays(today, -(r?.to ?? 0)) };
}

async function pointsOf(db: D1Database, userId: number) {
  const row = await db
    .prepare(
      `SELECT
         (SELECT COALESCE(SUM(cost_micro), 0) FROM daily_usage WHERE user_id = ?1) AS cost_micro,
         (SELECT COALESCE(SUM(delta), 0) FROM points_ledger WHERE user_id = ?1) AS ledger`,
    )
    .bind(userId)
    .first<{ cost_micro: number; ledger: number }>();
  const earned = pointsFromMicro(row!.cost_micro);
  return { earned, balance: earned + row!.ledger };
}

async function dailySeries(db: D1Database, userId: number, days: number) {
  const { results } = await db
    .prepare(
      `SELECT day, app,
         SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens) AS tokens,
         SUM(cost_micro) AS cost_micro, SUM(answers) AS answers
       FROM daily_usage WHERE user_id = ? AND day >= ?
       GROUP BY day, app ORDER BY day`,
    )
    .bind(userId, addDays(isoDay(new Date()), -(days - 1)))
    .all<{ day: string; app: string; tokens: number; cost_micro: number; answers: number }>();
  return results;
}

async function totalsOf(db: D1Database, userId: number) {
  return db
    .prepare(
      `SELECT COUNT(DISTINCT day) AS active_days,
         COALESCE(SUM(input_tokens), 0) AS input_tokens,
         COALESCE(SUM(output_tokens), 0) AS output_tokens,
         COALESCE(SUM(cache_read_tokens), 0) AS cache_read_tokens,
         COALESCE(SUM(cache_creation_tokens), 0) AS cache_creation_tokens,
         COALESCE(SUM(cost_micro), 0) AS cost_micro
       FROM daily_usage WHERE user_id = ?`,
    )
    .bind(userId)
    .first();
}

/** 模型明细：最近 30 天每天每个模型的输入、输出、缓存读取、缓存写入和花费；网页按昨天 / 7 天 / 30 天、按服务自己加起来 */
async function topModels(db: D1Database, userId: number) {
  const { results } = await db
    .prepare(
      `SELECT day, app, model, input_tokens AS input, output_tokens AS output,
         cache_read_tokens AS cache_read, cache_creation_tokens AS cache_write, cost_micro, answers
       FROM daily_usage WHERE user_id = ? AND day >= ? ORDER BY day`,
    )
    .bind(userId, addDays(isoDay(new Date()), -30))
    .all();
  return results;
}

/** 模型明细的「全部」：所有日子每个模型加起来 */
async function modelTotals(db: D1Database, userId: number) {
  const { results } = await db
    .prepare(
      `SELECT app, model, SUM(input_tokens) AS input, SUM(output_tokens) AS output,
         SUM(cache_read_tokens) AS cache_read, SUM(cache_creation_tokens) AS cache_write, SUM(cost_micro) AS cost_micro, SUM(answers) AS answers
       FROM daily_usage WHERE user_id = ? GROUP BY app, model`,
    )
    .bind(userId)
    .all();
  return results;
}

/** Token 活动：最近 53 周多一点（378 天）每天每个服务的 token 合计（含缓存），画热力图；网页按服务筛选 */
async function activityOf(db: D1Database, userId: number) {
  const { results } = await db
    .prepare(
      `SELECT day, app, SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens) AS tokens, SUM(answers) AS answers
       FROM daily_usage WHERE user_id = ? AND day >= ? GROUP BY day, app ORDER BY day`,
    )
    .bind(userId, addDays(isoDay(new Date()), -377))
    .all<{ day: string; app: string; tokens: number; answers: number }>();
  return results;
}

function publicUser(u: { login: string; name: string | null; avatar_url: string | null; badges?: string | null }) {
  return { login: u.login, name: u.name, avatarUrl: u.avatar_url, badges: parseBadges(u.badges) };
}

interface StatRow {
  hands: number | null;
  wins: number | null;
  vpip: number | null;
  pfr: number | null;
  threebet_opp: number | null;
  threebet: number | null;
}

/** 德州统计：手数和几个比率（0～1）；没打过牌的比率是 null */
function statsOf(r: StatRow) {
  const hands = r.hands ?? 0;
  const ratio = (n: number | null, d: number) => (d > 0 ? (n ?? 0) / d : null);
  return {
    hands,
    winRate: ratio(r.wins, hands),
    vpip: ratio(r.vpip, hands),
    pfr: ratio(r.pfr, hands),
    threeBet: ratio(r.threebet, r.threebet_opp ?? 0),
  };
}

// ---------- 公开接口 ----------

/**
 * 排行榜：by=tokens 按烧掉的 token 数（可选时间段），顺带最常用的模型；by=wealth 按筹码余额（sort=today 按今日输赢）。
 */
app.get("/api/leaderboard", async (c) => {
  const by = c.req.query("by") ?? "tokens";
  if (by === "wealth") {
    // 可以按余额排，也可以按今天（UTC）在牌桌上的输赢排
    const sort = c.req.query("sort") === "today" ? "today" : "balance";
    const { results } = await c.env.DB.prepare(
      `SELECT * FROM (
         SELECT u.login, u.name, u.avatar_url, u.badges,
           s.hands, s.wins, s.vpip, s.pfr, s.threebet_opp, s.threebet,
           COALESCE(pd.net, 0) AS today, COALESCE(pd.hands, 0) AS today_hands,
           (SELECT COALESCE(SUM(cost_micro), 0) FROM daily_usage d WHERE d.user_id = u.id) / 1000000
             + (SELECT COALESCE(SUM(delta), 0) FROM points_ledger l WHERE l.user_id = u.id) AS balance
         FROM users u
           LEFT JOIN poker_stats s ON s.user_id = u.id
           LEFT JOIN poker_daily pd ON pd.user_id = u.id AND pd.day = ?
         WHERE u.show_on_board = 1
       ) WHERE balance > 0 ORDER BY ${sort === "today" ? "today_hands > 0 DESC, today DESC, balance DESC" : "balance DESC"} LIMIT 100`,
    )
      .bind(isoDay(new Date()))
      .all<{ login: string; name: string | null; avatar_url: string | null; badges: string; balance: number; today: number; today_hands: number } & StatRow>();
    return c.json({
      by,
      sort,
      rows: results.map((r, i) => ({ rank: i + 1, ...publicUser(r), balance: r.balance, today: r.today, todayHands: r.today_hands, stats: statsOf(r) })),
    });
  }
  if (by !== "tokens") return c.json({ error: "by 只能是 tokens / wealth" }, 400);
  const range = c.req.query("range") ?? "7d";
  if (!(range in RANGES)) return c.json({ error: "range 只能是 yesterday / 7d / 30d / all" }, 400);
  // 燃烧 token 榜可以按 token 数排，也可以按这些 token 的花费排
  const sort = c.req.query("sort") === "cost" ? "cost" : "tokens";
  const { start, end } = rangeDays(range);
  const { results } = await c.env.DB.prepare(
    `WITH per AS (
       SELECT d.user_id, d.app, d.model,
         SUM(d.input_tokens + d.output_tokens + d.cache_read_tokens + d.cache_creation_tokens) AS tokens,
         SUM(d.cost_micro) AS cost_micro
       FROM daily_usage d JOIN users u ON u.id = d.user_id
       WHERE u.show_on_board = 1 AND d.day BETWEEN ? AND ?
       GROUP BY d.user_id, d.app, d.model
     )
     SELECT u.login, u.name, u.avatar_url, u.badges, SUM(per.tokens) AS tokens, SUM(per.cost_micro) AS cost_micro,
       (SELECT p2.model FROM per p2 WHERE p2.user_id = per.user_id ORDER BY p2.tokens DESC LIMIT 1) AS top_model,
       (SELECT p2.app FROM per p2 WHERE p2.user_id = per.user_id ORDER BY p2.tokens DESC LIMIT 1) AS top_app
     FROM per JOIN users u ON u.id = per.user_id
     GROUP BY per.user_id HAVING tokens > 0
     ORDER BY ${sort === "cost" ? "cost_micro DESC, tokens DESC" : "tokens DESC, cost_micro DESC"} LIMIT 100`,
  )
    .bind(start ?? "0000-00-00", end)
    .all<{ login: string; name: string | null; avatar_url: string | null; badges: string; tokens: number; cost_micro: number; top_model: string; top_app: string }>();
  return c.json({
    by,
    range,
    since: start,
    sort,
    rows: results.map((r, i) => ({ rank: i + 1, ...publicUser(r), tokens: r.tokens, costMicro: r.cost_micro, topModel: r.top_model, topApp: r.top_app })),
  });
});

/** 一个人的德州统计（牌桌上点头像看）。牌桌上大家本来就看得到彼此，所以不看「公开主页」设置。 */
app.get("/api/stats/:login", async (c) => {
  const row = await c.env.DB.prepare(
    `SELECT u.login, u.name, u.avatar_url, u.badges, s.hands, s.wins, s.vpip, s.pfr, s.threebet_opp, s.threebet
     FROM users u LEFT JOIN poker_stats s ON s.user_id = u.id WHERE u.login = ? COLLATE NOCASE`,
  )
    .bind(c.req.param("login"))
    .first<{ login: string; name: string | null; avatar_url: string | null; badges: string } & StatRow>();
  if (!row) return c.json({ error: "没有这个用户，或对方未公开" }, 404);
  return c.json({ user: publicUser(row), stats: statsOf(row) });
});

app.get("/api/users/:login", async (c) => {
  const user = await c.env.DB.prepare("SELECT * FROM users WHERE login = ? COLLATE NOCASE AND show_on_board = 1")
    .bind(c.req.param("login"))
    .first<{ id: number; login: string; name: string | null; avatar_url: string | null; created_at: string }>();
  if (!user) return c.json({ error: "没有这个用户，或对方未公开" }, 404);
  const [totals, series, models, modelsAll, points, activity, plans] = await Promise.all([
    totalsOf(c.env.DB, user.id),
    dailySeries(c.env.DB, user.id, 30),
    topModels(c.env.DB, user.id),
    modelTotals(c.env.DB, user.id),
    pointsOf(c.env.DB, user.id),
    activityOf(c.env.DB, user.id),
    plansOf(c.env.DB, user.id),
  ]);
  return c.json({ user: { ...publicUser(user), joinedAt: user.created_at, plans }, totals, series, models, modelsAll, points, activity });
});

// ---------- 网页登录后的接口 ----------

app.get("/api/me", async (c) => {
  const user = await sessionUser(c);
  if (!user) return c.json({ user: null });
  // 先检查成就（第一次登录、连续天数…）：新解锁的等用户自己去成就页领，顶栏奖杯旁边提醒
  await syncAchievements(c.env.DB, user.id);
  const [totals, series, models, modelsAll, points, activity, uploads, items, emotes, achievementsReady, plans] = await Promise.all([
    totalsOf(c.env.DB, user.id),
    dailySeries(c.env.DB, user.id, 30),
    topModels(c.env.DB, user.id),
    modelTotals(c.env.DB, user.id),
    pointsOf(c.env.DB, user.id),
    activityOf(c.env.DB, user.id),
    uploadHistory(c.env.DB, user.id),
    itemsOf(c.env.DB, user.id),
    emotesOf(c.env.DB, user.id),
    readyCount(c.env.DB, user.id),
    plansOf(c.env.DB, user.id),
  ]);
  return c.json({
    user: { ...publicUser(user), showOnBoard: !!user.show_on_board, joinedAt: user.created_at, plans },
    look: lookOf(user),
    // 每日礼盒：今天（UTC）领过没有
    daily: {
      claimed: !!(await c.env.DB.prepare("SELECT 1 FROM points_ledger WHERE ref = ?").bind(`daily:${user.id}:${isoDay(new Date())}`).first()),
      amount: DAILY_GIFT,
    },
    items,
    emotes,
    achievementsReady,
    totals,
    series,
    models,
    modelsAll,
    points,
    activity,
    uploads,
  });
});

const me = new Hono<AppEnv>();
me.use("*", requireSession);

me.patch("/", async (c) => {
  const body = await c.req.json<{ showOnBoard?: unknown }>();
  if (typeof body.showOnBoard !== "boolean") return c.json({ error: "showOnBoard 必须是布尔值" }, 400);
  await c.env.DB.prepare("UPDATE users SET show_on_board = ? WHERE id = ?").bind(body.showOnBoard ? 1 : 0, c.get("user").id).run();
  return c.json({ ok: true });
});

async function createApiToken(db: D1Database, userId: number, label: string) {
  const token = `yyb_${randomToken(24)}`;
  await db.prepare("INSERT INTO api_tokens (user_id, token_hash, label) VALUES (?, ?, ?)")
    .bind(userId, await sha256(token), label)
    .run();
  return token;
}

/** 拆每日礼盒：每天（UTC）一次，固定 $100，外加随机一个道具；按 ref 去重，重复点不会多发 */
me.post("/daily", async (c) => {
  const user = c.get("user");
  const res = await c.env.DB.prepare("INSERT OR IGNORE INTO points_ledger (user_id, delta, reason, ref) VALUES (?, ?, 'daily', ?)")
    .bind(user.id, DAILY_GIFT, `daily:${user.id}:${isoDay(new Date())}`)
    .run();
  if (!res.meta.changes) return c.json({ ok: true, amount: 0, item: null });
  // 筹码发出去了才送道具；道具没写进去不影响筹码
  const item = ITEMS[Math.floor(Math.random() * ITEMS.length)].id;
  await c.env.DB.prepare("INSERT INTO user_items (user_id, item, qty) VALUES (?, ?, 1) ON CONFLICT (user_id, item) DO UPDATE SET qty = qty + 1")
    .bind(user.id, item)
    .run()
    .catch(() => {});
  return c.json({ ok: true, amount: DAILY_GIFT, item });
});

me.post("/tokens", async (c) => {
  const body = await c.req.json<{ label?: unknown }>();
  const label = typeof body.label === "string" && body.label.trim() ? body.label.trim().slice(0, 60) : "yybar App";
  const { count } = (await c.env.DB.prepare("SELECT COUNT(*) AS count FROM api_tokens WHERE user_id = ? AND revoked_at IS NULL")
    .bind(c.get("user").id)
    .first<{ count: number }>())!;
  if (count >= 10) return c.json({ error: "最多 10 个有效令牌，请先撤销旧的" }, 400);
  return c.json({ token: await createApiToken(c.env.DB, c.get("user").id, label) });
});

me.delete("/tokens/:id", async (c) => {
  await c.env.DB.prepare(
    "UPDATE api_tokens SET revoked_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ? AND user_id = ? AND revoked_at IS NULL",
  )
    .bind(Number(c.req.param("id")), c.get("user").id)
    .run();
  return c.json({ ok: true });
});

/** App 的「连接网站」流程：网页确认后生成令牌，交回给 App 的 yybar:// 回调。 */
me.post("/connect", async (c) => {
  const body = await c.req.json<{ state?: unknown }>();
  if (typeof body.state !== "string" || !/^[A-Za-z0-9_-]{8,128}$/.test(body.state)) return c.json({ error: "state 不合法" }, 400);
  const token = await createApiToken(c.env.DB, c.get("user").id, "yybar App");
  const redirect = `yybar://connect?token=${encodeURIComponent(token)}&state=${encodeURIComponent(body.state)}`;
  return c.json({ redirect });
});

app.route("/api/me", me);

// ---------- App 接口 ----------

const v1 = new Hono<AppEnv>();
v1.use("*", requireApiToken);

v1.get("/whoami", (c) => c.json({ user: publicUser(c.get("user")) }));

/** 已经上传过的（日期, 服务）：App 连上后拿它补上本地的「已上传」标记，之后只传没标记的。days 是去重后的日期（旧版 App 用）。 */
v1.get("/usage/days", async (c) => {
  const uploads = await uploadedPairs(c.env.DB, c.get("user").id);
  return c.json({ days: [...new Set(uploads.map((u) => u.day))], uploads });
});

v1.post("/usage", async (c) => {
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "请求体不是合法 JSON" }, 400);
  }
  try {
    const upload = parseUpload(body);
    const { accepted, skipped } = await saveUpload(c.env.DB, c.get("user").id, upload);
    return c.json({ ok: true, accepted, skipped });
  } catch (e) {
    if (e instanceof UploadError) return c.json({ error: e.message }, 422);
    throw e;
  }
});

/** 各服务账号的套餐（个人主页 @ 后面那一排）：这台设备（device）传的整份替换上次的 */
v1.put("/accounts", async (c) => {
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "请求体不是合法 JSON" }, 400);
  }
  try {
    const rows = parseAccounts(body);
    await saveAccounts(c.env.DB, c.get("user").id, c.get("tokenId"), rows, parseDevice(body));
    return c.json({ ok: true, count: rows.length });
  } catch (e) {
    if (e instanceof AccountsError) return c.json({ error: e.message }, 422);
    throw e;
  }
});

app.route("/api/v1", v1);

app.route("/api/tables", tableRoutes);

app.route("/api/shop", shopRoutes);

app.route("/api/achievements", achievementRoutes);

/** 服务端的模型价格表：上传的花费按它算，「总花费」旁边的问号点开看的就是这个 */
app.get("/api/prices", async (c) => c.json({ prices: await loadPrices(c.env.DB) }));

app.notFound((c) => c.json({ error: "Not found" }, 404));

export default app;
export { PokerTable } from "./table";
