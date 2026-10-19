import { Hono } from "hono";
import { COSMETICS, findCosmetic, type CosmeticKind } from "../shared/cosmetics";
import { requireSession, sessionUser } from "./auth";
import type { AppEnv, UserRow } from "./types";

/** 买过的款式记在积分流水里，ref 唯一，所以同一款不会扣两次钱 */
const shopRef = (userId: number, kind: CosmeticKind, id: string) => `shop:${userId}:${kind}:${id}`;

async function ownedOf(db: D1Database, userId: number): Promise<Set<string>> {
  const { results } = await db
    .prepare("SELECT ref FROM points_ledger WHERE user_id = ? AND reason = 'shop'")
    .bind(userId)
    .all<{ ref: string }>();
  // ref 是 shop:<用户>:<种类>:<款式>，取后两段
  return new Set(results.map((r) => r.ref.split(":").slice(2).join(":")));
}

const owns = (owned: Set<string>, kind: CosmeticKind, id: string) => findCosmetic(kind, id)?.price === 0 || owned.has(`${kind}:${id}`);

export const shopRoutes = new Hono<AppEnv>();

/** 商品列表；登录了顺带告诉你买过哪些、正在用哪个 */
shopRoutes.get("/", async (c) => {
  const user = await sessionUser(c);
  const owned = user ? await ownedOf(c.env.DB, user.id) : new Set<string>();
  return c.json({
    items: COSMETICS.map((x) => ({ ...x, owned: !!user && owns(owned, x.kind, x.id) })),
    equipped: user ? { back: user.card_back, face: user.card_face } : null,
  });
});

/** 买一款：余额判断和扣款是同一条 SQL；买过的不会再扣 */
shopRoutes.post("/buy", requireSession, async (c) => {
  const body = await c.req.json<{ kind?: CosmeticKind; id?: string }>().catch(() => ({}) as { kind?: CosmeticKind; id?: string });
  const item = body.kind && body.id ? findCosmetic(body.kind, body.id) : undefined;
  if (!item) return c.json({ error: "没有这件商品" }, 404);
  const user = c.get("user");
  if (item.price === 0 || (await ownedOf(c.env.DB, user.id)).has(`${item.kind}:${item.id}`)) return c.json({ ok: true });
  const res = await c.env.DB.prepare(
    `INSERT OR IGNORE INTO points_ledger (user_id, delta, reason, ref)
     SELECT ?1, -?2, 'shop', ?3
     WHERE (SELECT COALESCE(SUM(cost_micro), 0) / 10000 FROM daily_usage WHERE user_id = ?1)
         + (SELECT COALESCE(SUM(delta), 0) FROM points_ledger WHERE user_id = ?1) >= ?2`,
  )
    .bind(user.id, item.price, shopRef(user.id, item.kind, item.id))
    .run();
  if (!res.meta.changes) return c.json({ error: "筹码不够" }, 400);
  return c.json({ ok: true });
});

/** 换上一款（必须是买过的或默认款）。牌背下次连上牌桌时生效。 */
shopRoutes.post("/equip", requireSession, async (c) => {
  const body = await c.req.json<{ kind?: CosmeticKind; id?: string }>().catch(() => ({}) as { kind?: CosmeticKind; id?: string });
  const item = body.kind && body.id ? findCosmetic(body.kind, body.id) : undefined;
  if (!item) return c.json({ error: "没有这件商品" }, 404);
  const user = c.get("user");
  if (!owns(await ownedOf(c.env.DB, user.id), item.kind, item.id)) return c.json({ error: "还没买这一款" }, 400);
  const column = item.kind === "back" ? "card_back" : "card_face";
  await c.env.DB.prepare(`UPDATE users SET ${column} = ? WHERE id = ?`).bind(item.id, user.id).run();
  return c.json({ ok: true });
});

export function lookOf(user: Pick<UserRow, "card_back" | "card_face">) {
  return { back: user.card_back, face: user.card_face };
}
