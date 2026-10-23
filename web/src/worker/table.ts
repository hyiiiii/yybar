// 每张牌桌一个 Durable Object：持有牌局状态，用 WebSocket 给桌上和旁观的人推送。
// 牌局逻辑在 src/shared/poker/room.ts；这里负责存档、计时（alarm）、连接和筹码记账。

import { DurableObject } from "cloudflare:workers";
import { TableRoom, type Player, type RoomConfig, type RoomState } from "../shared/poker/room";
import type { ClientMsg, ServerMsg } from "../shared/poker/types";
import type { Env } from "./types";
import { DEFAULT_EMOTES, findItem, THROW_PRICE, type ItemId, type ThrowItem } from "../shared/cosmetics";
import { spendItem } from "./shop";
import { unlockAchievement } from "./achievements";

/** 连接附带的身份：未登录的旁观者 userId 为 0。emotes 是这个人有的表情。 */
interface Attachment extends Player {
  emotes?: string[];
}

const CASHOUT_RETRY_MS = 5_000;

export class PokerTable extends DurableObject<Env> {
  private room: TableRoom | null = null;
  private reportedSeated = -1;
  private reportedOnline = -1;
  /** 上次写进 poker_seats 的在座真人，变了才重写 */
  private reportedHumans: string | null = null;

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
    // 桌号重新用上（大厅里删掉又开了同号的桌）时，旧存档里没人了就从头开一张新桌；还有人坐着就接着用，只换配置
    const stale = this.room && this.room.s.config.since !== config.since && this.room.vacant();
    if (!this.room || stale) this.room = TableRoom.create(config);
    else Object.assign(this.room.s.config, { sb: config.sb, bb: config.bb, bots: config.bots, temporary: config.temporary, since: config.since });
    // 机器人桌没人看时停着：有人进来先把错过的手补打上
    this.room.resume(Date.now());

    const { 0: client, 1: server } = new WebSocketPair();
    const att: Attachment = user ?? { userId: 0, login: "", avatarUrl: null };
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment(att);
    if (att.userId) {
      this.room.setAway(att.userId, false, Date.now());
      this.room.setLook(att.userId, att.back, att.face, att.badges);
    }
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
    else if (msg.t === "hold") err = room.hold(user, msg.seat, now);
    else if (msg.t === "release") room.release(user.userId);
    else if (msg.t === "show") err = room.show(user.userId, msg.which);
    else if (msg.t === "item") err = await this.useItem(user, msg.item);
    else if (msg.t === "emote") err = room.emote(user.userId, String(msg.id), user.emotes ?? DEFAULT_EMOTES, now);
    else if (msg.t === "throw") err = await this.throwAt(user, msg.item, msg.seat, msg.n);
    else if (msg.t === "roll") err = room.roll(user, now);
    else if (msg.t === "act") err = room.act(user.userId, msg.action, msg.amount, now);
    else return;
    if (err) fail(err);
    await this.commit();
  }

  async webSocketClose(ws: WebSocket) {
    await this.disconnected(ws);
  }

  async webSocketError(ws: WebSocket) {
    await this.disconnected(ws);
  }

  async alarm() {
    if (!this.room) return this.ctx.storage.deleteAlarm();
    this.room.resume(Date.now());
    this.room.tick(Date.now());
    await this.commit();
  }

  private async disconnected(ws: WebSocket) {
    const user = ws.deserializeAttachment() as Attachment;
    if (!this.room) return;
    // 没登录的旁观者走了不用存档，只把布告栏的在线人数改掉：机器人桌最后一个人走了，下一次闹钟时发现没人看，机器人就停手
    if (!user.userId) return this.reportCounts(ws);
    const still = this.ctx.getWebSockets().some((w) => w !== ws && (w.deserializeAttachment() as Attachment).userId === user.userId);
    if (!still) this.room.setAway(user.userId, true, Date.now());
    await this.commit(ws);
  }

  /** 用道具：先看现在能不能用，再扣库存，扣完再生效；等扣库存的时候局面变了用不了，就把那一个退回去。 */
  private async useItem(user: Player, item: ItemId): Promise<string | null> {
    const room = this.room!;
    if (!findItem(item)) return "没有这个道具";
    const pre = room.canUseItem(user.userId, item);
    if (pre) return pre;
    if (!(await spendItem(this.env.DB, user.userId, item))) return "这个道具用完了，去商场买一些";
    const err = room.useItem(user.userId, item, Date.now());
    if (err) {
      await this.env.DB.prepare("UPDATE user_items SET qty = qty + 1 WHERE user_id = ? AND item = ?").bind(user.userId, item).run();
    }
    return err;
  }

  /** 扔番茄、送玫瑰：先看能不能扔，再从账户扣钱（余额判断和扣款同一条语句），扣成功才扔；这时候扔不了就退回。 */
  private async throwAt(user: Player, item: unknown, target: number, n: unknown): Promise<string | null> {
    const room = this.room!;
    const price = (item === "tomato" || item === "rose") && (n === 1 || n === 5) ? THROW_PRICE[item as ThrowItem][n] : undefined;
    if (!price) return "看不懂的操作";
    const pre = room.canThrow(user.userId, target, Date.now());
    if (pre) return pre;
    const ref = `t${room.s.config.no}:${item}:${user.userId}:${crypto.randomUUID()}`;
    const res = await this.env.DB.prepare(
      `INSERT INTO points_ledger (user_id, delta, reason, ref)
       SELECT ?1, -?2, ?4, ?3
       WHERE (SELECT COALESCE(SUM(cost_micro), 0) / 1000000 FROM daily_usage WHERE user_id = ?1)
           + (SELECT COALESCE(SUM(delta), 0) FROM points_ledger WHERE user_id = ?1) >= ?2`,
    )
      .bind(user.userId, price, ref, item)
      .run();
    if (!res.meta.changes) return "筹码不够";
    const err = room.throwAt(user, target, item as ThrowItem, n as 1 | 5, Date.now());
    if (err) room.s.cashouts.push({ userId: user.userId, amount: price, ref: `${ref}:refund` });
    return err;
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
       WHERE (SELECT COALESCE(SUM(cost_micro), 0) / 1000000 FROM daily_usage WHERE user_id = ?1)
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

  /** 存档、写回待结算的筹码、排下一次闹钟，然后给每个连接推送各自视角的牌桌。gone 是正在断开的连接。 */
  private async commit(gone?: WebSocket) {
    const room = this.room;
    if (!room) return;
    await this.flushCashouts();
    await this.flushStats();
    for (const u of [...(room.s.unlocks ?? [])]) {
      try {
        await unlockAchievement(this.env.DB, u.userId, u.id);
        room.ackUnlock(u.userId, u.id);
      } catch {
        // 留着下次再写
      }
    }
    room.checkEmpty(Date.now());
    if (room.closable(Date.now()) && (await this.close())) return;
    // 机器人桌上只剩机器人、也没人在看：先停手，有人连上来时把错过的手一下补打完（room.resume）。
    // 看的人眼里它一直在打，但没人看的时候不用每一两秒醒一次（按请求和写入行数计费，免费额度撑不住全天跑）
    const idle = room.s.config.bots && room.vacant() && !this.ctx.getWebSockets().some((w) => w !== gone);
    if (idle) room.pause(Date.now());
    await this.ctx.storage.put("room", room.s);
    // 收桌没成功（删桌失败）时隔一会儿再试，不要马上又醒
    const wake = idle ? null : room.closable(Date.now()) ? Date.now() + CASHOUT_RETRY_MS : room.nextWake();
    const retry = room.s.cashouts.length ? Date.now() + CASHOUT_RETRY_MS : null;
    const at = [wake, retry].filter((x): x is number => x !== null);
    // 闹钟排在整毫秒、而且一定在现在之后：在闹钟里再排一个和这次同一时刻（或更早）的闹钟，
    // 跑完会被当成已经响过删掉，牌桌就停住了，要等有人重连才接着打
    if (at.length) await this.ctx.storage.setAlarm(Math.max(Math.ceil(Math.min(...at)), Date.now() + 1));
    else await this.ctx.storage.deleteAlarm();

    const now = Date.now();
    for (const ws of this.ctx.getWebSockets()) {
      const user = ws.deserializeAttachment() as Attachment;
      send(ws, { t: "state", view: room.view(user.userId || null, now) });
    }

    await this.reportHumans();
    await this.reportCounts(gone);
  }

  /** 在座人数和在线人数变了就写回 poker_tables（大厅、布告栏用）。gone 是正在断开的连接 */
  private async reportCounts(gone?: WebSocket) {
    const room = this.room;
    if (!room) return;
    const seated = room.seated();
    const online = this.online(gone);
    if (seated === this.reportedSeated && online === this.reportedOnline) return;
    try {
      await this.env.DB.prepare("UPDATE poker_tables SET seated = ?, online = ? WHERE no = ?").bind(seated, online, room.s.config.no).run();
      this.reportedSeated = seated;
      this.reportedOnline = online;
    } catch {
      // 大厅人数只是展示，下次再报
    }
  }

  /** 连着这张桌的真人有几个：在座的、旁观的都算，同一个账号开几个页面算一个，没登录的每个连接算一个。gone 是正在断开的连接 */
  private online(gone?: WebSocket): number {
    const users = new Set<number>();
    let guests = 0;
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === gone) continue;
      const user = ws.deserializeAttachment() as Attachment;
      if (user.userId) users.add(user.userId);
      else guests++;
    }
    return users.size + guests;
  }

  /** 把在座的真人写进 poker_seats，大厅靠它知道一个人坐在哪几张桌。只是提醒用，失败下次再写。 */
  private async reportHumans() {
    const room = this.room;
    const no = room ? room.s.config.no : null;
    const ids = room ? room.s.seats.filter((x) => x && !x.bot).map((x) => x!.userId).sort((a, b) => a - b) : [];
    const key = ids.join();
    if (key === this.reportedHumans || no === null) return;
    try {
      const db = this.env.DB;
      await db.batch([
        db.prepare("DELETE FROM poker_seats WHERE table_no = ?").bind(no),
        ...ids.map((id) => db.prepare("INSERT OR IGNORE INTO poker_seats (table_no, user_id) VALUES (?, ?)").bind(no, id)),
      ]);
      this.reportedHumans = key;
    } catch {
      // 下次再写
    }
  }

  /** 收桌：删掉大厅里的这张桌，通知还连着的人，清空存档。删桌失败返回 false，下次闹钟再试。 */
  private async close(): Promise<boolean> {
    try {
      const no = this.room!.s.config.no;
      await this.env.DB.batch([
        this.env.DB.prepare("DELETE FROM poker_tables WHERE no = ? AND created_by IS NOT NULL").bind(no),
        this.env.DB.prepare("DELETE FROM poker_seats WHERE table_no = ?").bind(no),
      ]);
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

  /** 打完的手的统计加进 poker_stats；写失败留着下次再写 */
  private async flushStats() {
    const room = this.room!;
    const stats = room.s.stats ?? [];
    if (!stats.length) return;
    const db = this.env.DB;
    const b = (x: boolean) => (x ? 1 : 0);
    try {
      await db.batch(
        stats.map((s) =>
          db
            .prepare(
              `INSERT INTO poker_stats (user_id, hands, wins, vpip, pfr, threebet_opp, threebet) VALUES (?, 1, ?, ?, ?, ?, ?)
               ON CONFLICT (user_id) DO UPDATE SET hands = hands + 1, wins = wins + excluded.wins, vpip = vpip + excluded.vpip,
                 pfr = pfr + excluded.pfr, threebet_opp = threebet_opp + excluded.threebet_opp, threebet = threebet + excluded.threebet`,
            )
            .bind(s.userId, b(s.won), b(s.vpip), b(s.pfr), b(s.tbOpp), b(s.tb)),
        ).concat(
          // 每天的输赢，财富榜「今日输赢」用
          stats.filter((s) => s.day).map((s) =>
            db
              .prepare(
                `INSERT INTO poker_daily (user_id, day, net, hands) VALUES (?, ?, ?, 1)
                 ON CONFLICT (user_id, day) DO UPDATE SET net = net + excluded.net, hands = hands + 1`,
              )
              .bind(s.userId, s.day, s.net ?? 0),
          ),
        ),
      );
      room.ackStats(stats.length);
    } catch {
      // 下次再写
    }
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
      `SELECT (SELECT COALESCE(SUM(cost_micro), 0) / 1000000 FROM daily_usage WHERE user_id = ?1)
            + (SELECT COALESCE(SUM(delta), 0) FROM points_ledger WHERE user_id = ?1) AS balance`,
    )
    .bind(userId)
    .first<{ balance: number }>();
  return row?.balance ?? 0;
}
