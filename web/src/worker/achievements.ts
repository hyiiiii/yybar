import { Hono } from "hono";
import { ACHIEVEMENTS, findAchievement, longestStreak, MAX_BADGES, parseBadges, type AchievementId } from "../shared/achievements";
import { requireSession, sessionUser } from "./auth";
import type { AppEnv } from "./types";
import { addDays, isoDay } from "./util";

/** 解锁一个成就（还没领奖励，等用户自己点「领取」）；已经解锁过的什么都不做（按主键去重）。 */
export async function unlockAchievement(db: D1Database, userId: number, id: AchievementId) {
  if (!findAchievement(id)) return;
  await db.prepare("INSERT OR IGNORE INTO user_achievements (user_id, id) VALUES (?, ?)").bind(userId, id).run();
}

/** 解锁了还没领的成就有几个：顶栏奖杯旁边的提醒 */
export async function readyCount(db: D1Database, userId: number): Promise<number> {
  const row = await db.prepare("SELECT COUNT(*) AS n FROM user_achievements WHERE user_id = ? AND claimed_at IS NULL").bind(userId).first<{ n: number }>();
  return row?.n ?? 0;
}

/**
 * 领一个已经解锁的成就：发奖励、记下领取时间。返回这次发了多少（已经领过、没解锁返回 0）。
 * 发奖励只在这一行还没领时写（同一条语句里判断），ref 也去重，连点两下不会发两次。
 */
export async function claimAchievement(db: D1Database, userId: number, id: AchievementId): Promise<number> {
  const a = findAchievement(id);
  if (!a) return 0;
  const [paid] = await db.batch([
    db
      .prepare(
        `INSERT OR IGNORE INTO points_ledger (user_id, delta, reason, ref)
         SELECT ?1, ?2, 'achievement', ?3
         WHERE EXISTS (SELECT 1 FROM user_achievements WHERE user_id = ?1 AND id = ?4 AND claimed_at IS NULL)`,
      )
      .bind(userId, a.reward, `ach:${userId}:${id}`, id),
    db
      .prepare("UPDATE user_achievements SET claimed_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE user_id = ? AND id = ? AND claimed_at IS NULL")
      .bind(userId, id),
  ]);
  return paid.meta.changes ? a.reward : 0;
}

const TOKENS = "input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens";

/**
 * 按用量和流水检查一遍能自动判定的成就，新达成的就解锁（奖励等用户自己领）。返回进度（连续天数、累计 token、累计花费美元）。
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
    if (reached[id] && !have.has(id)) await unlockAchievement(db, userId, id);
  }
  return { streak, tokens, spend };
}

export const achievementRoutes = new Hono<AppEnv>();

/** 成就列表；登录了顺带检查一遍、给出进度、领没领和正在戴的徽章 */
achievementRoutes.get("/", async (c) => {
  const user = await sessionUser(c);
  if (!user) return c.json({ achievements: ACHIEVEMENTS.map((a) => ({ ...a, unlockedAt: null, claimedAt: null })), progress: null, badges: [] });
  const progress = await syncAchievements(c.env.DB, user.id);
  const { results } = await c.env.DB.prepare("SELECT id, unlocked_at, claimed_at FROM user_achievements WHERE user_id = ?")
    .bind(user.id)
    .all<{ id: string; unlocked_at: string; claimed_at: string | null }>();
  const at = new Map(results.map((r) => [r.id, r]));
  const row = await c.env.DB.prepare("SELECT badges FROM users WHERE id = ?").bind(user.id).first<{ badges: string }>();
  return c.json({
    achievements: ACHIEVEMENTS.map((a) => ({ ...a, unlockedAt: at.get(a.id)?.unlocked_at ?? null, claimedAt: at.get(a.id)?.claimed_at ?? null })),
    progress,
    badges: parseBadges(row?.badges),
  });
});

/** 领奖励：带 id 领那一个，不带就把解锁了还没领的全领了。返回这次一共领了多少 */
achievementRoutes.post("/claim", requireSession, async (c) => {
  const body = await c.req.json<{ id?: string }>().catch(() => ({}) as { id?: string });
  const user = c.get("user");
  if (body.id !== undefined && !findAchievement(body.id)) return c.json({ error: "没有这个成就" }, 404);
  const ids = body.id
    ? [body.id as AchievementId]
    : (
        await c.env.DB.prepare("SELECT id FROM user_achievements WHERE user_id = ? AND claimed_at IS NULL").bind(user.id).all<{ id: string }>()
      ).results.map((r) => r.id as AchievementId);
  let amount = 0;
  for (const id of ids) amount += await claimAchievement(c.env.DB, user.id, id);
  if (body.id && !amount) {
    const row = await c.env.DB.prepare("SELECT claimed_at FROM user_achievements WHERE user_id = ? AND id = ?").bind(user.id, body.id).first<{ claimed_at: string | null }>();
    return c.json({ error: row ? "已经领过了" : "还没解锁这个成就" }, 400);
  }
  return c.json({ ok: true, amount });
});

/** 戴上或摘下一个徽章：on 为 true 戴上（必须已解锁，最多同时戴 3 个），false 摘下。牌桌上下次连上时生效。 */
achievementRoutes.post("/wear", requireSession, async (c) => {
  const body = await c.req.json<{ id?: string; on?: boolean }>().catch(() => ({}) as { id?: string; on?: boolean });
  const user = c.get("user");
  if (!body.id || !findAchievement(body.id)) return c.json({ error: "没有这个成就" }, 404);
  let badges = parseBadges(user.badges).filter((b) => b !== body.id);
  if (body.on) {
    const ok = await c.env.DB.prepare("SELECT claimed_at FROM user_achievements WHERE user_id = ? AND id = ?").bind(user.id, body.id).first<{ claimed_at: string | null }>();
    if (!ok) return c.json({ error: "还没解锁这个成就" }, 400);
    if (!ok.claimed_at) return c.json({ error: "先领了这个成就再戴" }, 400);
    if (badges.length >= MAX_BADGES) return c.json({ error: `最多戴 ${MAX_BADGES} 个徽章` }, 400);
    badges = [...badges, body.id];
  }
  await c.env.DB.prepare("UPDATE users SET badges = ? WHERE id = ?").bind(JSON.stringify(badges), user.id).run();
  return c.json({ ok: true, badges });
});
