import { Hono } from "hono";
import { COSMETICS, findCosmetic, findItem, ITEMS, type CosmeticKind, type ItemId } from "../shared/cosmetics";
import { requireSession, sessionUser } from "./auth";
import type { AppEnv, UserRow } from "./types";

/** 买过的牌背、牌面、表情记在积分流水里，ref 唯一，所以同一款不会扣两次钱 */
const shopRef = (userId: number, kind: CosmeticKind, id: string) => `shop:${userId}:${kind}:${id}`;

/** 余额够才写这条扣款流水：余额判断和扣款是同一条 SQL */
const CHARGE = `INSERT OR IGNORE INTO points_ledger (user_id, delta, reason, ref)
  SELECT ?1, -?2, 'shop', ?3
  WHERE (SELECT COALESCE(SUM(cost_micro), 0) / 1000000 FROM daily_usage WHERE user_id = ?1)
      + (SELECT COALESCE(SUM(delta), 0) FROM points_ledger WHERE user_id = ?1) >= ?2`;

async function ownedOf(db: D1Database, userId: number): Promise<Set<string>> {
  const { results } = await db
    .prepare("SELECT ref FROM points_ledger WHERE user_id = ? AND reason = 'shop' AND ref NOT LIKE 'shop:%:item:%'")
    .bind(userId)
    .all<{ ref: string }>();
  // ref 是 shop:<用户>:<种类>:<款式>，取后两段
  return new Set(results.map((r) => r.ref.split(":").slice(2).join(":")));
}

const owns = (owned: Set<string>, kind: CosmeticKind, id: string) => findCosmetic(kind, id)?.price === 0 || owned.has(`${kind}:${id}`);

/** 自己有的表情（默认四个 + 买过的） */
export async function emotesOf(db: D1Database, userId: number): Promise<string[]> {
  const owned = await ownedOf(db, userId);
  return COSMETICS.filter((c) => c.kind === "emote" && owns(owned, "emote", c.id)).map((c) => c.id);
}

/** 道具库存 */
export async function itemsOf(db: D1Database, userId: number): Promise<Record<ItemId, number>> {
  const { results } = await db.prepare("SELECT item, qty FROM user_items WHERE user_id = ?").bind(userId).all<{ item: ItemId; qty: number }>();
  const out = Object.fromEntries(ITEMS.map((x) => [x.id, 0])) as Record<ItemId, number>;
  for (const r of results) if (r.item in out) out[r.item] = r.qty;
  return out;
}

/** 用掉一个道具；没有了返回 false。 */
export async function spendItem(db: D1Database, userId: number, item: ItemId): Promise<boolean> {
  const res = await db.prepare("UPDATE user_items SET qty = qty - 1 WHERE user_id = ? AND item = ? AND qty > 0").bind(userId, item).run();
  return res.meta.changes > 0;
}

export function lookOf(user: Pick<UserRow, "card_back" | "card_face">) {
  return { back: user.card_back, face: user.card_face };
}

export const shopRoutes = new Hono<AppEnv>();

/** 商品列表；登录了顺带告诉你买过哪些、道具还剩几个、正在用哪个 */
shopRoutes.get("/", async (c) => {
  const user = await sessionUser(c);
  const [owned, items] = user ? await Promise.all([ownedOf(c.env.DB, user.id), itemsOf(c.env.DB, user.id)]) : [new Set<string>(), null];
  return c.json({
    cosmetics: COSMETICS.map((x) => ({ ...x, owned: !!user && owns(owned, x.kind, x.id) })),
    items: ITEMS.map((x) => ({ ...x, qty: items?.[x.id] ?? 0 })),
    equipped: user ? lookOf(user) : null,
  });
});

type BuyBody = { kind?: CosmeticKind | "item"; id?: string };

/** 买：牌背、牌面、表情买一次永久拥有；道具每次买一个 */
shopRoutes.post("/buy", requireSession, async (c) => {
  const body = await c.req.json<BuyBody>().catch(() => ({}) as BuyBody);
  const user = c.get("user");
  const db = c.env.DB;

  if (body.kind === "item") {
    const item = findItem(body.id ?? "");
    if (!item) return c.json({ error: "没有这件商品" }, 404);
    const ref = `shop:${user.id}:item:${item.id}:${crypto.randomUUID()}`;
    // 扣款和加库存在同一个事务里：扣款没写进去，库存也不会加
    const [charged] = await db.batch([
      db.prepare(CHARGE).bind(user.id, item.price, ref),
      db
        .prepare(
          `INSERT INTO user_items (user_id, item, qty) SELECT ?1, ?2, 1 WHERE EXISTS (SELECT 1 FROM points_ledger WHERE ref = ?3)
           ON CONFLICT (user_id, item) DO UPDATE SET qty = qty + 1`,
        )
        .bind(user.id, item.id, ref),
    ]);
    if (!charged.meta.changes) return c.json({ error: "筹码不够" }, 400);
    return c.json({ ok: true });
  }

  const item = body.kind && body.id ? findCosmetic(body.kind, body.id) : undefined;
  if (!item) return c.json({ error: "没有这件商品" }, 404);
  if (item.price === 0 || (await ownedOf(db, user.id)).has(`${item.kind}:${item.id}`)) return c.json({ ok: true });
  const res = await db.prepare(CHARGE).bind(user.id, item.price, shopRef(user.id, item.kind, item.id)).run();
  if (!res.meta.changes) return c.json({ error: "筹码不够" }, 400);
  return c.json({ ok: true });
});

/** 换上一款牌背或牌面（必须是买过的或默认款）。下次连上牌桌时生效。 */
shopRoutes.post("/equip", requireSession, async (c) => {
  const body = await c.req.json<BuyBody>().catch(() => ({}) as BuyBody);
  const item = body.kind === "back" || body.kind === "face" ? findCosmetic(body.kind, body.id ?? "") : undefined;
  if (!item) return c.json({ error: "没有这件商品" }, 404);
  const user = c.get("user");
  if (!owns(await ownedOf(c.env.DB, user.id), item.kind, item.id)) return c.json({ error: "还没买这一款" }, 400);
  const column = item.kind === "back" ? "card_back" : "card_face";
  await c.env.DB.prepare(`UPDATE users SET ${column} = ? WHERE id = ?`).bind(item.id, user.id).run();
  return c.json({ ok: true });
});
