import { Hono } from "hono";
import { requireSession, sessionUser } from "./auth";
import type { AppEnv } from "./types";

interface TableRow {
  no: number;
  sb: number;
  bb: number;
  bots: number;
  seated: number;
}

/** 每人最多开几张桌 */
const MAX_OWN_TABLES = 3;

export const tableRoutes = new Hono<AppEnv>();

const listed = (t: TableRow) => ({ no: t.no, blinds: [t.sb, t.bb], bots: !!t.bots, seated: t.seated });

tableRoutes.get("/", async (c) => {
  const { results } = await c.env.DB.prepare("SELECT no, sb, bb, bots, seated FROM poker_tables ORDER BY no").all<TableRow>();
  return c.json({ tables: results.map(listed) });
});

/** 开桌：盲注沿用 from 那张桌，桌号接在最后。 */
tableRoutes.post("/", requireSession, async (c) => {
  const body = await c.req.json<{ from?: unknown }>();
  const from = await c.env.DB.prepare("SELECT * FROM poker_tables WHERE no = ?").bind(Number(body.from)).first<TableRow>();
  if (!from) return c.json({ error: "没有这张桌" }, 404);
  const user = c.get("user");
  const { count } = (await c.env.DB.prepare("SELECT COUNT(*) AS count FROM poker_tables WHERE created_by = ?")
    .bind(user.id)
    .first<{ count: number }>())!;
  if (count >= MAX_OWN_TABLES) return c.json({ error: `每人最多开 ${MAX_OWN_TABLES} 张桌` }, 400);
  const row = await c.env.DB.prepare(
    `INSERT INTO poker_tables (no, sb, bb, bots, created_by)
     SELECT COALESCE(MAX(no), 1000) + 1, ?, ?, 0, ? FROM poker_tables
     RETURNING no, sb, bb, bots, seated`,
  )
    .bind(from.sb, from.bb, user.id)
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
  headers.set("x-table", JSON.stringify({ no: table.no, sb: table.sb, bb: table.bb, bots: !!table.bots }));
  headers.set(
    "x-user",
    // 请求头只能放 ASCII，用户名转义一下
    user ? JSON.stringify({ userId: user.id, login: user.login, avatarUrl: user.avatar_url }).replace(/[^\x20-\x7e]/g, (ch) => `\\u${ch.charCodeAt(0).toString(16).padStart(4, "0")}`) : "null",
  );
  const stub = c.env.TABLES.get(c.env.TABLES.idFromName(String(no)));
  return stub.fetch(new Request(c.req.raw.url, { headers }));
});
