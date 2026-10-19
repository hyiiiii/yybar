import { Hono } from "hono";
import { authRoutes, requireApiToken, requireSession, sessionUser } from "./auth";
import { achievementRoutes, syncAchievements } from "./achievements";
import { emotesOf, itemsOf, lookOf, shopRoutes } from "./shop";
import { tableRoutes } from "./tables";
import type { AppEnv } from "./types";
import { parseUpload, saveUpload, UploadError } from "./usage";
import { addDays, isoDay, pointsFromMicro, randomToken, sha256 } from "./util";

const app = new Hono<AppEnv>();

app.route("/auth", authRoutes);

const RANGES: Record<string, number | null> = { today: 0, "7d": 6, "30d": 29, all: null };

/** 起始日期（含）。日期按上传者本地时区记录，这里以 UTC 今天为基准往前推。 */
function rangeStart(range: string): string | null {
  const days = RANGES[range];
  return days === null || days === undefined ? null : addDays(isoDay(new Date()), -days);
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
         SUM(cost_micro) AS cost_micro
       FROM daily_usage WHERE user_id = ? AND day >= ?
       GROUP BY day, app ORDER BY day`,
    )
    .bind(userId, addDays(isoDay(new Date()), -(days - 1)))
    .all<{ day: string; app: string; tokens: number; cost_micro: number }>();
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

async function topModels(db: D1Database, userId: number) {
  const { results } = await db
    .prepare(
      `SELECT app, model, SUM(cost_micro) AS cost_micro,
         SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens) AS tokens
       FROM daily_usage WHERE user_id = ? GROUP BY app, model ORDER BY cost_micro DESC LIMIT 10`,
    )
    .bind(userId)
    .all();
  return results;
}

function publicUser(u: { login: string; name: string | null; avatar_url: string | null; badge?: string | null }) {
  return { login: u.login, name: u.name, avatarUrl: u.avatar_url, badge: u.badge ?? null };
}

// ---------- 公开接口 ----------

/**
 * 排行榜：by=tokens 按烧掉的 token 数（可选时间段），顺带最常用的模型；by=wealth 按筹码余额。
 */
app.get("/api/leaderboard", async (c) => {
  const by = c.req.query("by") ?? "tokens";
  if (by === "wealth") {
    const { results } = await c.env.DB.prepare(
      `SELECT * FROM (
         SELECT u.login, u.name, u.avatar_url, u.badge,
           (SELECT COALESCE(SUM(cost_micro), 0) FROM daily_usage d WHERE d.user_id = u.id) / 10000
             + (SELECT COALESCE(SUM(delta), 0) FROM points_ledger l WHERE l.user_id = u.id) AS balance
         FROM users u WHERE u.show_on_board = 1
       ) WHERE balance > 0 ORDER BY balance DESC LIMIT 100`,
    ).all<{ login: string; name: string | null; avatar_url: string | null; badge: string | null; balance: number }>();
    return c.json({ by, rows: results.map((r, i) => ({ rank: i + 1, ...publicUser(r), balance: r.balance })) });
  }
  if (by !== "tokens") return c.json({ error: "by 只能是 tokens / wealth" }, 400);
  const range = c.req.query("range") ?? "7d";
  if (!(range in RANGES)) return c.json({ error: "range 只能是 today / 7d / 30d / all" }, 400);
  const start = rangeStart(range);
  const { results } = await c.env.DB.prepare(
    `WITH per AS (
       SELECT d.user_id, d.app, d.model,
         SUM(d.input_tokens + d.output_tokens + d.cache_read_tokens + d.cache_creation_tokens) AS tokens
       FROM daily_usage d JOIN users u ON u.id = d.user_id
       WHERE u.show_on_board = 1 AND d.day >= ?
       GROUP BY d.user_id, d.app, d.model
     )
     SELECT u.login, u.name, u.avatar_url, u.badge, SUM(per.tokens) AS tokens,
       (SELECT p2.model FROM per p2 WHERE p2.user_id = per.user_id ORDER BY p2.tokens DESC LIMIT 1) AS top_model,
       (SELECT p2.app FROM per p2 WHERE p2.user_id = per.user_id ORDER BY p2.tokens DESC LIMIT 1) AS top_app
     FROM per JOIN users u ON u.id = per.user_id
     GROUP BY per.user_id HAVING tokens > 0
     ORDER BY tokens DESC LIMIT 100`,
  )
    .bind(start ?? "0000-00-00")
    .all<{ login: string; name: string | null; avatar_url: string | null; badge: string | null; tokens: number; top_model: string; top_app: string }>();
  return c.json({
    by,
    range,
    since: start,
    rows: results.map((r, i) => ({ rank: i + 1, ...publicUser(r), tokens: r.tokens, topModel: r.top_model, topApp: r.top_app })),
  });
});

app.get("/api/users/:login", async (c) => {
  const user = await c.env.DB.prepare("SELECT * FROM users WHERE login = ? COLLATE NOCASE AND show_on_board = 1")
    .bind(c.req.param("login"))
    .first<{ id: number; login: string; name: string | null; avatar_url: string | null; created_at: string }>();
  if (!user) return c.json({ error: "没有这个用户，或对方未公开" }, 404);
  const [totals, series, models, points] = await Promise.all([
    totalsOf(c.env.DB, user.id),
    dailySeries(c.env.DB, user.id, 30),
    topModels(c.env.DB, user.id),
    pointsOf(c.env.DB, user.id),
  ]);
  return c.json({ user: { ...publicUser(user), joinedAt: user.created_at }, totals, series, models, points });
});

// ---------- 网页登录后的接口 ----------

app.get("/api/me", async (c) => {
  const user = await sessionUser(c);
  if (!user) return c.json({ user: null });
  // 先检查成就（第一次登录、连续天数…），新解锁的奖励要算进下面的余额
  await syncAchievements(c.env.DB, user.id);
  const [totals, series, models, points, tokens, items, emotes] = await Promise.all([
    totalsOf(c.env.DB, user.id),
    dailySeries(c.env.DB, user.id, 30),
    topModels(c.env.DB, user.id),
    pointsOf(c.env.DB, user.id),
    c.env.DB.prepare(
      "SELECT id, label, created_at, last_used_at FROM api_tokens WHERE user_id = ? AND revoked_at IS NULL ORDER BY id DESC",
    )
      .bind(user.id)
      .all(),
    itemsOf(c.env.DB, user.id),
    emotesOf(c.env.DB, user.id),
  ]);
  return c.json({
    user: { ...publicUser(user), showOnBoard: !!user.show_on_board, joinedAt: user.created_at },
    look: lookOf(user),
    items,
    emotes,
    totals,
    series,
    models,
    points,
    tokens: tokens.results,
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

v1.post("/usage", async (c) => {
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "请求体不是合法 JSON" }, 400);
  }
  try {
    const upload = parseUpload(body);
    await saveUpload(c.env.DB, c.get("user").id, upload);
    return c.json({ ok: true, days: upload.days.length, rows: upload.rows.length });
  } catch (e) {
    if (e instanceof UploadError) return c.json({ error: e.message }, 422);
    throw e;
  }
});

app.route("/api/v1", v1);

app.route("/api/tables", tableRoutes);

app.route("/api/shop", shopRoutes);

app.route("/api/achievements", achievementRoutes);

app.notFound((c) => c.json({ error: "Not found" }, 404));

export default app;
export { PokerTable } from "./table";
