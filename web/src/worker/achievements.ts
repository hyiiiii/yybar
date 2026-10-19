import { Hono } from "hono";
import { ACHIEVEMENTS, findAchievement, longestStreak, type AchievementId } from "../shared/achievements";
import { requireSession, sessionUser } from "./auth";
import type { AppEnv } from "./types";
import { addDays, isoDay } from "./util";

/** 解锁一个成就并发奖励；已经解锁过的什么都不做（两条都按主键 / ref 去重）。 */
export async function grantAchievement(db: D1Database, userId: number, id: AchievementId) {
  const a = findAchievement(id);
  if (!a) return;
  await db.batch([
    db.prepare("INSERT OR IGNORE INTO user_achievements (user_id, id) VALUES (?, ?)").bind(userId, id),
    db
      .prepare("INSERT OR IGNORE INTO points_ledger (user_id, delta, reason, ref) VALUES (?, ?, 'achievement', ?)")
      .bind(userId, a.reward, `ach:${userId}:${id}`),
  ]);
}

const TOKENS = "input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens";

/**
 * 按用量和流水检查一遍能自动判定的成就，新达成的就解锁。返回进度（连续天数、累计 token、累计花费美元）。
 * 打开网站（/api/me）和成就页时调用。
 */
export async function syncAchievements(db: D1Database, userId: number) {
  const today = isoDay(new Date());
  const [unlocked, days, totals, flags, recent] = await Promise.all([
    db.prepare("SELECT id FROM user_achievements WHERE user_id = ?").bind(userId).all<{ id: string }>(),
    db.prepare(`SELECT DISTINCT day FROM daily_usage WHERE user_id = ? AND ${TOKENS} > 0 ORDER BY day`).bind(userId).all<{ day: string }>(),
    db
      .prepare(`SELECT COALESCE(SUM(${TOKENS}), 0) AS tokens, COALESCE(SUM(cost_micro), 0) AS cost FROM daily_usage WHERE user_id = ?`)
      .bind(userId)
      .first<{ tokens: number; cost: number }>(),
    db
      .prepare(
        `SELECT EXISTS (SELECT 1 FROM points_ledger WHERE user_id = ?1 AND reason = 'buyin') AS sat,
                EXISTS (SELECT 1 FROM points_ledger WHERE user_id = ?1 AND reason = 'shop') AS bought`,
      )
      .bind(userId)
      .first<{ sat: number; bought: number }>(),
    // 今天、昨天每天谁烧得最多（日期按上传者本地记，这里两天都看，免得时区差一天）
    db
      .prepare(`SELECT day, user_id, SUM(${TOKENS}) AS tokens FROM daily_usage WHERE day >= ? GROUP BY day, user_id`)
      .bind(addDays(today, -1))
      .all<{ day: string; user_id: number; tokens: number }>(),
  ]);
  const have = new Set(unlocked.results.map((r) => r.id));
  const streak = longestStreak(days.results.map((r) => r.day));
  const tokens = totals?.tokens ?? 0;
  const spend = Math.floor((totals?.cost ?? 0) / 1_000_000);
  const top = new Map<string, { user: number; tokens: number }>();
  for (const r of recent.results) {
    const cur = top.get(r.day);
    if (r.tokens > 0 && (!cur || r.tokens > cur.tokens)) top.set(r.day, { user: r.user_id, tokens: r.tokens });
  }

  const reached: Record<string, boolean> = {
    first_login: true,
    first_sit: !!flags?.sat,
    first_purchase: !!flags?.bought,
    streak_7: streak >= 7,
    streak_30: streak >= 30,
    streak_365: streak >= 365,
    top_today: [...top.values()].some((x) => x.user === userId),
    tokens_100m: tokens >= 100_000_000,
    tokens_1b: tokens >= 1_000_000_000,
    spend_1k: spend >= 1_000,
  };
  for (const id of Object.keys(reached) as AchievementId[]) {
    if (reached[id] && !have.has(id)) await grantAchievement(db, userId, id);
  }
  return { streak, tokens, spend };
}

export const achievementRoutes = new Hono<AppEnv>();

/** 成就列表；登录了顺带检查一遍、给出进度和正在戴的徽章 */
achievementRoutes.get("/", async (c) => {
  const user = await sessionUser(c);
  if (!user) return c.json({ achievements: ACHIEVEMENTS.map((a) => ({ ...a, unlockedAt: null })), progress: null, badge: null });
  const progress = await syncAchievements(c.env.DB, user.id);
  const { results } = await c.env.DB.prepare("SELECT id, unlocked_at FROM user_achievements WHERE user_id = ?")
    .bind(user.id)
    .all<{ id: string; unlocked_at: string }>();
  const at = new Map(results.map((r) => [r.id, r.unlocked_at]));
  const badge = await c.env.DB.prepare("SELECT badge FROM users WHERE id = ?").bind(user.id).first<{ badge: string | null }>();
  return c.json({ achievements: ACHIEVEMENTS.map((a) => ({ ...a, unlockedAt: at.get(a.id) ?? null })), progress, badge: badge?.badge ?? null });
});

/** 戴上一个已解锁成就的徽章；id 为 null 就摘掉。牌桌上下次连上时生效。 */
achievementRoutes.post("/wear", requireSession, async (c) => {
  const body = await c.req.json<{ id?: string | null }>().catch(() => ({ id: undefined }));
  const user = c.get("user");
  if (body.id) {
    const ok = await c.env.DB.prepare("SELECT 1 FROM user_achievements WHERE user_id = ? AND id = ?").bind(user.id, body.id).first();
    if (!ok) return c.json({ error: "还没解锁这个成就" }, 400);
  }
  await c.env.DB.prepare("UPDATE users SET badge = ? WHERE id = ?").bind(body.id ?? null, user.id).run();
  return c.json({ ok: true });
});
