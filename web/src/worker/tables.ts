import { Hono } from "hono";
import { BLIND_LEVELS } from "../shared/poker/room";
import { requireSession, sessionUser } from "./auth";
import type { AppEnv } from "./types";

interface TableRow {
  no: number;
  sb: number;
  bb: number;
  bots: number;
  seated: number;
  created_by: number | null;
}

/** 每人最多开几张桌 */
const MAX_OWN_TABLES = 3;

export const tableRoutes = new Hono<AppEnv>();

const listed = (t: TableRow) => ({ no: t.no, blinds: [t.sb, t.bb], bots: !!t.bots, seated: t.seated, temporary: t.created_by !== null });

tableRoutes.get("/", async (c) => {
  // 玩家开的桌没人坐会自己收掉；开了却一直没人连上去的，在这里顺手清掉
  await c.env.DB.prepare(
    "DELETE FROM poker_tables WHERE created_by IS NOT NULL AND seated = 0 AND created_at < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-2 minutes')",
  ).run();
  const { results } = await c.env.DB.prepare("SELECT no, sb, bb, bots, seated, created_by FROM poker_tables ORDER BY no").all<TableRow>();
  // 登录了顺带告诉你坐在哪几张桌，前端在后台连着它们，轮到你时提醒
  const user = await sessionUser(c);
  const mine = user
    ? (await c.env.DB.prepare("SELECT table_no FROM poker_seats WHERE user_id = ?").bind(user.id).all<{ table_no: number }>()).results.map((r) => r.table_no)
    : [];
  return c.json({ tables: results.map(listed), mine });
});

/** 开桌：盲注从 BLIND_LEVELS 里选，桌号接在最后。没人坐的时候牌桌会自己收掉。 */
tableRoutes.post("/", requireSession, async (c) => {
  const body = await c.req.json<{ blinds?: unknown }>().catch(() => ({ blinds: undefined }));
  const blinds = BLIND_LEVELS.find(([sb, bb]) => Array.isArray(body.blinds) && body.blinds[0] === sb && body.blinds[1] === bb);
  if (!blinds) return c.json({ error: "没有这档盲注" }, 400);
  const user = c.get("user");
  // 坐着的时候不能开新桌，免得一个人开一堆桌
  const sitting = await c.env.DB.prepare("SELECT table_no FROM poker_seats WHERE user_id = ? LIMIT 1").bind(user.id).first<{ table_no: number }>();
  if (sitting) return c.json({ error: `你还坐在 #${sitting.table_no}，离桌后才能开新桌` }, 400);
  const { count } = (await c.env.DB.prepare("SELECT COUNT(*) AS count FROM poker_tables WHERE created_by = ?")
    .bind(user.id)
    .first<{ count: number }>())!;
  if (count >= MAX_OWN_TABLES) return c.json({ error: `每人最多开 ${MAX_OWN_TABLES} 张桌` }, 400);
  const row = await c.env.DB.prepare(
    `INSERT INTO poker_tables (no, sb, bb, bots, created_by)
     SELECT COALESCE(MAX(no), 1000) + 1, ?, ?, 0, ? FROM poker_tables
     RETURNING no, sb, bb, bots, seated, created_by`,
  )
    .bind(blinds[0], blinds[1], user.id)
    .first<TableRow>();
  return c.json({ table: listed(row!) });
});

/** 牌桌的实时连接。登录了可以入座，没登录只能旁观。 */
tableRoutes.get("/:no/ws", async (c) => {
  if (c.req.header("upgrade")?.toLowerCase() !== "websocket") return c.json({ error: "需要 WebSocket" }, 426);
  // 浏览器会带上登录 cookie，挡住别的网站发起的连接
  const origin = c.req.header("origin");
  if (origin && origin !== new URL(c.req.url).origin && origin !== new URL(c.env.APP_URL).origin) {
    return c.json({ error: "来源不对" }, 403);
  }
  const no = Number(c.req.param("no"));
  const table = await c.env.DB.prepare("SELECT * FROM poker_tables WHERE no = ?").bind(no).first<TableRow>();
  if (!table) return c.json({ error: "没有这张桌" }, 404);
  const user = await sessionUser(c);

  const headers = new Headers(c.req.raw.headers);
  headers.set("x-table", JSON.stringify({ no: table.no, sb: table.sb, bb: table.bb, bots: !!table.bots, temporary: table.created_by !== null }));
  headers.set(
    "x-user",
    // 请求头只能放 ASCII，用户名转义一下
    user ? JSON.stringify({ userId: user.id, login: user.login, avatarUrl: user.avatar_url, back: user.card_back }).replace(/[^\x20-\x7e]/g, (ch) => `\\u${ch.charCodeAt(0).toString(16).padStart(4, "0")}`) : "null",
  );
  const stub = c.env.TABLES.get(c.env.TABLES.idFromName(String(no)));
  return stub.fetch(new Request(c.req.raw.url, { headers }));
});
