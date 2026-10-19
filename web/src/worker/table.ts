// 每张牌桌一个 Durable Object：持有牌局状态，用 WebSocket 给桌上和旁观的人推送。
// 牌局逻辑在 src/shared/poker/room.ts；这里负责存档、计时（alarm）、连接和筹码记账。

import { DurableObject } from "cloudflare:workers";
import { TableRoom, type Player, type RoomConfig, type RoomState } from "../shared/poker/room";
import type { ClientMsg, ServerMsg } from "../shared/poker/types";
import type { Env } from "./types";

/** 连接附带的身份：未登录的旁观者 userId 为 0。 */
interface Attachment extends Player {}

const CASHOUT_RETRY_MS = 5_000;

export class PokerTable extends DurableObject<Env> {
  private room: TableRoom | null = null;
  private reportedSeated = -1;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      const s = await ctx.storage.get<RoomState>("room");
      if (s) this.room = new TableRoom(s);
    });
  }

  /** Worker 转来的 WebSocket 升级请求；配置和身份放在内部请求头里。 */
  async fetch(req: Request): Promise<Response> {
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return new Response("需要 WebSocket", { status: 426 });
    const config = JSON.parse(req.headers.get("x-table")!) as RoomConfig;
    const user = JSON.parse(req.headers.get("x-user") ?? "null") as Player | null;
    if (!this.room) this.room = TableRoom.create(config);
    else Object.assign(this.room.s.config, { sb: config.sb, bb: config.bb, bots: config.bots, temporary: config.temporary });

    const { 0: client, 1: server } = new WebSocketPair();
    const att: Attachment = user ?? { userId: 0, login: "", avatarUrl: null };
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment(att);
    if (att.userId) this.room.setAway(att.userId, false, Date.now());
    await this.commit();
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer) {
    const room = this.room;
    if (!room || typeof raw !== "string" || raw.length > 1000) return;
    const user = ws.deserializeAttachment() as Attachment;
    let msg: ClientMsg;
    try {
      msg = JSON.parse(raw);
    } catch {
      return;
    }
    const fail = (m: string) => send(ws, { t: "error", msg: m });
    const now = Date.now();
    if (msg.t === "ping") return send(ws, { t: "pong" });
    if (!user.userId) return fail("先登录再入座");

    let err: string | null = null;
    if (msg.t === "sit") err = await this.sit(user, msg.seat, msg.buyIn);
    else if (msg.t === "leave") err = room.leave(user.userId, now);
    else if (msg.t === "act") err = room.act(user.userId, msg.action, msg.amount, now);
    else return;
    if (err) fail(err);
    await this.commit();
  }

  async webSocketClose(ws: WebSocket) {
    this.disconnected(ws);
  }

  async webSocketError(ws: WebSocket) {
    this.disconnected(ws);
  }

  async alarm() {
    if (!this.room) return this.ctx.storage.deleteAlarm();
    this.room.tick(Date.now());
    await this.commit();
  }

  private async disconnected(ws: WebSocket) {
    const user = ws.deserializeAttachment() as Attachment;
    if (!this.room || !user.userId) return;
    const still = this.ctx.getWebSockets().some((w) => w !== ws && (w.deserializeAttachment() as Attachment).userId === user.userId);
    if (!still) this.room.setAway(user.userId, true, Date.now());
    await this.commit();
  }

  /** 入座：先从账户余额扣带入，扣成功再坐下；坐不下就退回。 */
  private async sit(user: Player, seat: number, want: number | undefined): Promise<string | null> {
    const room = this.room!;
    const pre = room.canSit(user.userId, seat);
    if (pre) return pre;
    const { no } = room.s.config;
    const amount = room.pickBuyIn(await balanceOf(this.env.DB, user.userId), want);
    if (typeof amount === "string") return amount;
    const ref = `t${no}:buyin:${user.userId}:${crypto.randomUUID()}`;
    // 余额判断和扣款放在同一条语句里，同时在几张桌入座也不会扣成负数
    const res = await this.env.DB.prepare(
      `INSERT INTO points_ledger (user_id, delta, reason, ref)
       SELECT ?1, -?2, 'buyin', ?3
       WHERE (SELECT COALESCE(SUM(cost_micro), 0) / 10000 FROM daily_usage WHERE user_id = ?1)
           + (SELECT COALESCE(SUM(delta), 0) FROM points_ledger WHERE user_id = ?1) >= ?2`,
    )
      .bind(user.userId, amount, ref)
      .run();
    if (!res.meta.changes) return "筹码不够，刚才可能在别的桌用掉了";
    const err = room.sit(user, seat, amount, Date.now());
    if (err) {
      // 等扣款的这段时间座位被别人抢了：原样退回
      room.s.cashouts.push({ userId: user.userId, amount, ref: `${ref}:refund` });
      return err;
    }
    return null;
  }

  /** 存档、写回待结算的筹码、排下一次闹钟，然后给每个连接推送各自视角的牌桌。 */
  private async commit() {
    const room = this.room;
    if (!room) return;
    await this.flushCashouts();
    room.checkEmpty(Date.now());
    if (room.closable(Date.now()) && (await this.close())) return;
    await this.ctx.storage.put("room", room.s);
    // 收桌没成功（删桌失败）时隔一会儿再试，不要马上又醒
    const wake = room.closable(Date.now()) ? Date.now() + CASHOUT_RETRY_MS : room.nextWake();
    const retry = room.s.cashouts.length ? Date.now() + CASHOUT_RETRY_MS : null;
    const at = [wake, retry].filter((x): x is number => x !== null);
    if (at.length) await this.ctx.storage.setAlarm(Math.min(...at));
    else await this.ctx.storage.deleteAlarm();

    const now = Date.now();
    for (const ws of this.ctx.getWebSockets()) {
      const user = ws.deserializeAttachment() as Attachment;
      send(ws, { t: "state", view: room.view(user.userId || null, now) });
    }

    const seated = room.seated();
    if (seated !== this.reportedSeated) {
      try {
        await this.env.DB.prepare("UPDATE poker_tables SET seated = ? WHERE no = ?").bind(seated, room.s.config.no).run();
        this.reportedSeated = seated;
      } catch {
        // 大厅人数只是展示，下次再报
      }
    }
  }

  /** 收桌：删掉大厅里的这张桌，通知还连着的人，清空存档。删桌失败返回 false，下次闹钟再试。 */
  private async close(): Promise<boolean> {
    try {
      await this.env.DB.prepare("DELETE FROM poker_tables WHERE no = ? AND created_by IS NOT NULL").bind(this.room!.s.config.no).run();
    } catch {
      return false;
    }
    for (const ws of this.ctx.getWebSockets()) {
      send(ws, { t: "closed" });
      try {
        ws.close(1000, "closed");
      } catch {
        // 已经断了
      }
    }
    this.room = null;
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
    return true;
  }

  private async flushCashouts() {
    const room = this.room!;
    for (const c of [...room.s.cashouts]) {
      try {
        await this.env.DB.prepare("INSERT OR IGNORE INTO points_ledger (user_id, delta, reason, ref) VALUES (?, ?, ?, ?)")
          .bind(c.userId, c.amount, c.ref.endsWith(":refund") ? "buyin-refund" : "cashout", c.ref)
          .run();
        room.ackCashout(c.ref);
      } catch {
        // 留在队列里，闹钟稍后重试；状态已存档，不会丢
      }
    }
  }
}

function send(ws: WebSocket, msg: ServerMsg) {
  try {
    ws.send(JSON.stringify(msg));
  } catch {
    // 连接已断开
  }
}

async function balanceOf(db: D1Database, userId: number): Promise<number> {
  const row = await db
    .prepare(
      `SELECT (SELECT COALESCE(SUM(cost_micro), 0) / 10000 FROM daily_usage WHERE user_id = ?1)
            + (SELECT COALESCE(SUM(delta), 0) FROM points_ledger WHERE user_id = ?1) AS balance`,
    )
    .bind(userId)
    .first<{ balance: number }>();
  return row?.balance ?? 0;
}
