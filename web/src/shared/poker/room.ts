// 一张德州牌桌的完整状态机：入座、离桌、发牌、下注、边池、摊牌。
// 纯逻辑，不碰网络和存储：服务端的 Durable Object 和预览版的本地牌桌都包一层用它。
// 状态是普通 JSON，可以直接存进 Durable Object 的存储。

import { bestScore, handName, newDeck, shuffle, type Card } from "./cards";
import { botDecide } from "./bot";
import { SEATS, type Legal, type SeatView, type Street, type TableView } from "./types";

export interface RoomConfig {
  no: number;
  sb: number;
  bb: number;
  /** 机器人练习桌：有真人坐下时自动补机器人陪打 */
  bots: boolean;
  /** 预览版用：固定这几个机器人一直坐着打，不管有没有真人 */
  fixedBots?: string[];
  /** 玩家开的桌：没有真人坐着一段时间后收掉 */
  temporary?: boolean;
}

export interface Player {
  userId: number;
  login: string;
  avatarUrl: string | null;
  /** 商场里换上的牌背，同桌的人都看得到；机器人和旧存档没有 */
  back?: string;
}

interface RoomSeat extends Player {
  bot: boolean;
  stack: number;
  inHand: boolean;
  folded: boolean;
  allIn: boolean;
  /** 这一轮已下注 */
  bet: number;
  /** 这一手累计投入（含这一轮） */
  committed: number;
  acted: boolean;
  /** 这一轮还能不能加注：面对不足额的全下加注时，已经行动过的人只能跟或弃 */
  mayRaise: boolean;
  hole: Card[];
  shown: boolean;
  /** 赢了没摊牌时自己选择亮的牌：第 1 位第一张，第 2 位第二张；旧存档没有 */
  showMask?: number;
  last: string | null;
  won: number;
  hand: string | null;
  /** 断线时刻；在线为 null */
  away: number | null;
  leaving: boolean;
  timeouts: number;
}

/** 点了空位、正在选带入的人先占着这个座位 */
export interface Hold extends Player {
  start: number;
  until: number;
}

export interface Cashout {
  userId: number;
  amount: number;
  ref: string;
}

export interface RoomState {
  config: RoomConfig;
  seats: (RoomSeat | null)[];
  handNo: number;
  street: Street;
  button: number;
  deck: Card[];
  board: Card[];
  currentBet: number;
  /** 最小加注幅度（上一次足额加注的幅度，至少一个大盲） */
  minRaise: number;
  toAct: number;
  /** 当前这次行动开始的时刻，画倒计时圈用 */
  turnStart?: number | null;
  deadline: number | null;
  nextHandAt: number | null;
  say: string | null;
  /** 待写回账户的筹码；宿主写成功后调用 ackCashout */
  cashouts: Cashout[];
  /** 玩家开的桌从这一刻起没有真人；旧存档没有这个字段 */
  emptySince?: number | null;
  /** 每个座位的占座；旧存档没有这个字段 */
  holds?: (Hold | null)[];
}

/** 入座带入：自己选 40～200 个大盲，默认 100 个。 */
export const BUY_IN_BB = 100;
export const MIN_BUY_IN_BB = 40;
export const MAX_BUY_IN_BB = 200;
/** 开桌可选的盲注 */
export const BLIND_LEVELS: [number, number][] = [[5, 10], [10, 20], [25, 50], [50, 100], [100, 200], [200, 400]];
export const TURN_MS = 10_000;
/** 点了空位选带入时占座多久 */
export const HOLD_MS = 10_000;
/** 玩家开的桌没有真人超过这么久就收掉 */
export const EMPTY_TABLE_MS = 30_000;
const AWAY_TURN_MS = 5_000;
/** 断线超过这么久，下一手开始前自动离桌 */
const AWAY_KICK_MS = 60_000;
const START_DELAY_MS = 1_500;
const SHOWDOWN_PAUSE_MS = 6_000;
const FOLD_WIN_PAUSE_MS = 3_000;

const BOT_NAMES = ["bot-紧凶", "bot-松鱼", "bot-跟注站", "bot-诈唬王", "bot-老实人"];

/** 筹码按美元写：1 个筹码 = $1，播报、动作和报错里都这样写。 */
export function chips(n: number): string {
  return `$${n.toLocaleString("en-US")}`;
}

export class TableRoom {
  constructor(public s: RoomState) {}

  static create(config: RoomConfig): TableRoom {
    const room = new TableRoom({
      config,
      seats: Array(SEATS).fill(null),
      handNo: 0,
      street: "idle",
      button: -1,
      deck: [],
      board: [],
      currentBet: 0,
      minRaise: config.bb,
      toAct: -1,
      deadline: null,
      nextHandAt: null,
      say: null,
      cashouts: [],
    });
    room.syncBots(0);
    return room;
  }

  // ---------- 查询 ----------

  seatOf(userId: number): number {
    return this.s.seats.findIndex((x) => x?.userId === userId);
  }

  /** 真人数量（不含正在离桌的） */
  humans(): number {
    return this.s.seats.filter((x) => x && !x.bot && !x.leaving).length;
  }

  seated(): number {
    return this.s.seats.filter((x) => x && !x.leaving).length;
  }

  private get inProgress(): boolean {
    return this.s.street !== "idle" && this.s.street !== "showdown";
  }

  nextWake(): number | null {
    const closeAt = this.emptyFrom() === null ? null : this.emptyFrom()! + EMPTY_TABLE_MS;
    const holdEnd = this.holds().reduce<number | null>((m, h) => (h && (m === null || h.until < m) ? h.until : m), null);
    const t = [this.s.deadline, this.s.nextHandAt, closeAt, this.idleKickAt(), holdEnd].filter((x): x is number => x !== null);
    return t.length ? Math.min(...t) : null;
  }

  /** 这次能带入的区间；余额不够最低带入返回 null。 */
  buyInRange(balance: number): { min: number; max: number } | null {
    const { bb } = this.s.config;
    const min = MIN_BUY_IN_BB * bb;
    const max = Math.min(MAX_BUY_IN_BB * bb, balance);
    return max >= min ? { min, max } : null;
  }

  /** 按余额和想带的数目定下带入；不想带多少就带默认的 100 个大盲。返回筹码数或者错误。 */
  pickBuyIn(balance: number, want?: number): number | string {
    const range = this.buyInRange(balance);
    if (!range) return `筹码不够：这张桌最少要带 ${chips(MIN_BUY_IN_BB * this.s.config.bb)} 入座`;
    if (want === undefined) return Math.min(BUY_IN_BB * this.s.config.bb, range.max);
    const amount = Math.floor(Number(want));
    if (!Number.isFinite(amount) || amount < range.min || amount > range.max) {
      return `带入要在 ${chips(range.min)} 到 ${chips(range.max)} 之间`;
    }
    return amount;
  }

  /** 没在打牌时，掉线最久的那个人该被请离桌的时刻（打牌时由两手之间的 cleanup 处理）。 */
  private idleKickAt(): number | null {
    if (this.inProgress || this.s.nextHandAt !== null) return null;
    const t = this.s.seats.filter((x) => x && !x.bot && x.away !== null).map((x) => x!.away! + AWAY_KICK_MS);
    return t.length ? Math.min(...t) : null;
  }

  /** 玩家开的桌已经空了多久的起点；不是玩家开的桌、有真人或还有筹码没结算时为 null。 */
  private emptyFrom(): number | null {
    if (!this.s.config.temporary) return null;
    return this.s.emptySince ?? null;
  }

  /** 宿主每次存档前调用：记下空桌的起点。 */
  checkEmpty(now: number) {
    if (!this.s.config.temporary) return;
    const anyone = this.s.seats.some((x) => x && !x.bot) || this.s.cashouts.length > 0 || this.holds().some(Boolean);
    if (anyone) this.s.emptySince = null;
    else this.s.emptySince ??= now;
  }

  /** 玩家开的桌空了够久，可以收掉了。 */
  closable(now: number): boolean {
    const from = this.emptyFrom();
    return from !== null && now >= from + EMPTY_TABLE_MS;
  }

  canSit(userId: number, seat: number): string | null {
    if (!Number.isInteger(seat) || seat < 0 || seat >= SEATS) return "没有这个座位";
    if (this.seatOf(userId) >= 0) return "你已经在这张桌上了";
    if (this.s.seats[seat]) return "这个座位有人了";
    const hold = this.holds()[seat];
    if (hold && hold.userId !== userId) return "这个座位有人正在买入";
    return null;
  }

  private holds(): (Hold | null)[] {
    return (this.s.holds ??= Array(SEATS).fill(null));
  }

  // ---------- 玩家操作 ----------

  sit(player: Player, seat: number, stack: number, now: number): string | null {
    const err = this.canSit(player.userId, seat);
    if (err) return err;
    this.s.seats[seat] = this.blankSeat(player, false, stack);
    this.release(player.userId);
    this.syncBots(now);
    this.scheduleStart(now);
    return null;
  }

  /** 占座：点了空位先占 10 秒，选好带入再坐下。同一个人在一张桌只占一个座位。 */
  hold(player: Player, seat: number, now: number): string | null {
    const err = this.canSit(player.userId, seat);
    if (err) return err;
    this.release(player.userId);
    this.holds()[seat] = { ...player, start: now, until: now + HOLD_MS };
    return null;
  }

  release(userId: number) {
    const holds = this.holds();
    holds.forEach((h, i) => h?.userId === userId && (holds[i] = null));
  }

  /** 赢了没摊牌（别人都弃了）时亮牌给大家看：which 0 第一张，1 第二张，2 两张。 */
  show(userId: number, which: number): string | null {
    const i = this.seatOf(userId);
    const seat = this.s.seats[i];
    if (!seat) return "你没有坐在这张桌上";
    if (this.s.street !== "showdown" || !seat.inHand || seat.folded || !seat.hole.length) return "现在不能亮牌";
    if (![0, 1, 2].includes(which)) return "看不懂的操作";
    seat.showMask = (seat.showMask ?? 0) | (which === 2 ? 3 : 1 << which);
    return null;
  }

  /** 离桌：不在牌局里立刻结算；在牌局里先弃牌，这手结束后结算。 */
  leave(userId: number, now: number): string | null {
    const i = this.seatOf(userId);
    if (i < 0) return "你没有坐在这张桌上";
    const seat = this.s.seats[i]!;
    if (seat.leaving) return null;
    seat.leaving = true;
    if (!this.inProgress || !seat.inHand) {
      if (this.s.street === "showdown" && seat.inHand) return null; // 摊牌展示完再走
      this.standUp(i);
      this.syncBots(now);
      return null;
    }
    if (!seat.folded) this.foldOutOfTurn(i, now);
    return null;
  }

  act(userId: number, action: "fold" | "check" | "call" | "raise", amount: number | undefined, now: number): string | null {
    const i = this.seatOf(userId);
    if (i < 0) return "你没有坐在这张桌上";
    if (!this.inProgress || this.s.toAct !== i) return "还没轮到你";
    this.s.seats[i]!.timeouts = 0;
    return this.apply(i, action, amount, now);
  }

  /** 重新连上时带来最新的牌背（在商场换了之后） */
  setBack(userId: number, back: string | undefined) {
    const i = this.seatOf(userId);
    if (i >= 0 && back) this.s.seats[i]!.back = back;
  }

  setAway(userId: number, away: boolean, now: number) {
    const i = this.seatOf(userId);
    if (i < 0) return;
    this.s.seats[i]!.away = away ? (this.s.seats[i]!.away ?? now) : null;
  }

  ackCashout(ref: string) {
    this.s.cashouts = this.s.cashouts.filter((c) => c.ref !== ref);
  }

  /** 时钟推进：处理超时、机器人行动、开下一手。宿主在 nextWake() 时刻调用。 */
  tick(now: number) {
    for (let guard = 0; guard < 100; guard++) {
      if (this.inProgress && this.s.deadline !== null && now >= this.s.deadline) {
        const i = this.s.toAct;
        const seat = this.s.seats[i]!;
        if (seat.bot) {
          const d = botDecide(this.s, i, this.legal(i)!);
          this.apply(i, d.action, d.amount, now);
        } else {
          seat.timeouts += 1;
          if (seat.timeouts >= 2) seat.leaving = true;
          this.apply(i, this.legal(i)!.canCheck ? "check" : "fold", undefined, now);
        }
        continue;
      }
      if (!this.inProgress && this.s.nextHandAt !== null && now >= this.s.nextHandAt) {
        this.s.nextHandAt = null;
        this.cleanup(now);
        if (this.eligible().length >= 2) this.startHand(now);
        else {
          this.s.street = "idle";
          this.s.board = [];
          this.s.say = null;
        }
        continue;
      }
      const holds = this.holds();
      if (holds.some((h) => h && now >= h.until)) {
        holds.forEach((h, i) => h && now >= h.until && (holds[i] = null));
        continue;
      }
      // 一个人坐着等开局时掉线：没有下一手来清理，到点直接请离桌
      const kick = this.idleKickAt();
      if (kick !== null && now >= kick) {
        this.s.seats.forEach((x, i) => x && !x.bot && x.away !== null && now - x.away >= AWAY_KICK_MS && this.standUp(i));
        this.syncBots(now);
        continue;
      }
      return;
    }
  }

  // ---------- 视图 ----------

  legal(i: number): Legal | null {
    const seat = this.s.seats[i];
    if (!seat || !this.inProgress || this.s.toAct !== i) return null;
    const toCall = Math.min(this.s.currentBet - seat.bet, seat.stack);
    const maxTo = seat.bet + seat.stack;
    return {
      canCheck: seat.bet >= this.s.currentBet,
      toCall: Math.max(0, toCall),
      canRaise: seat.mayRaise && maxTo > this.s.currentBet,
      minRaiseTo: Math.min(this.s.currentBet + this.s.minRaise, maxTo),
      maxRaiseTo: maxTo,
    };
  }

  view(userId: number | null, now: number): TableView {
    const you = userId === null ? -1 : this.seatOf(userId);
    const seats = this.s.seats.map((x, i): SeatView | null => {
      if (!x) return null;
      let cards: (Card | null)[] = [];
      if (x.inHand && x.hole.length) {
        const mask = x.shown ? 3 : (x.showMask ?? 0);
        if (i === you || x.shown) cards = x.hole;
        else if (!x.folded) cards = x.hole.map((c, k) => (mask >> k) & 1 ? c : null);
      }
      return {
        login: x.login,
        avatarUrl: x.avatarUrl,
        bot: x.bot,
        stack: x.stack,
        bet: x.bet,
        inHand: x.inHand,
        folded: x.folded,
        allIn: x.allIn,
        cards,
        back: x.back ?? null,
        showMask: x.shown ? 3 : (x.showMask ?? 0),
        away: x.away !== null,
        leaving: x.leaving,
        last: x.last,
        won: x.won,
        hand: x.hand,
      };
    });
    const youSeat = you >= 0 && !this.s.seats[you]!.leaving ? you : null;
    return {
      no: this.s.config.no,
      blinds: [this.s.config.sb, this.s.config.bb],
      bots: this.s.config.bots,
      handNo: this.s.handNo,
      street: this.s.street,
      button: this.s.button,
      board: this.s.board,
      pot: this.s.seats.reduce((sum, x) => sum + (x?.committed ?? 0), 0),
      seats,
      toAct: this.inProgress ? this.s.toAct : -1,
      deadline: this.inProgress ? this.s.deadline : null,
      ...this.turnClock(),
      serverNow: now,
      you: youSeat,
      legal: youSeat === null ? null : this.legal(youSeat),
      say: this.s.say,
      holds: this.holds().map((h) => h && { login: h.login, start: h.start, until: h.until, you: h.userId === userId }),
    };
  }

  /** 倒计时圈：机器人想一两秒就出手，圈按正常行动时长画，免得一闪而过。 */
  private turnClock(): { turnStart: number | null; turnMs: number | null } {
    if (!this.inProgress || this.s.deadline === null) return { turnStart: null, turnMs: null };
    const start = this.s.turnStart ?? this.s.deadline - TURN_MS;
    return { turnStart: start, turnMs: this.s.seats[this.s.toAct]?.bot ? TURN_MS : this.s.deadline - start };
  }

  // ---------- 内部 ----------

  private blankSeat(p: Player, bot: boolean, stack: number): RoomSeat {
    return {
      ...p,
      bot,
      stack,
      inHand: false,
      folded: false,
      allIn: false,
      bet: 0,
      committed: 0,
      acted: false,
      mayRaise: true,
      hole: [],
      shown: false,
      last: null,
      won: 0,
      hand: null,
      away: null,
      leaving: false,
      timeouts: 0,
    };
  }

  private standUp(i: number) {
    const seat = this.s.seats[i]!;
    if (!seat.bot && seat.stack > 0) {
      this.s.cashouts.push({
        userId: seat.userId,
        amount: seat.stack,
        ref: `t${this.s.config.no}:cashout:${seat.userId}:${this.s.handNo}:${crypto.randomUUID()}`,
      });
    }
    this.s.seats[i] = null;
  }

  private eligible(): number[] {
    const out: number[] = [];
    this.s.seats.forEach((x, i) => x && x.stack > 0 && !x.leaving && out.push(i));
    return out;
  }

  private scheduleStart(now: number) {
    if (!this.inProgress && this.s.nextHandAt === null && this.eligible().length >= 2) {
      this.s.nextHandAt = now + START_DELAY_MS;
    }
  }

  /** 机器人桌：真人越少机器人越多（凑够 4 人），没有真人就都走。只在两手之间调整。 */
  private syncBots(now: number) {
    if (this.inProgress) return;
    const { config } = this.s;
    const names = config.fixedBots ?? (config.bots ? BOT_NAMES : []);
    if (!names.length) return;
    const want = config.fixedBots ? names.length : this.humans() ? Math.max(0, 4 - this.humans()) : 0;
    let bots = this.s.seats.filter((x) => x?.bot).length;
    for (let i = SEATS - 1; i >= 0 && bots > want; i--) {
      if (this.s.seats[i]?.bot) (this.s.seats[i] = null), bots--;
    }
    for (const name of names) {
      if (bots >= want) break;
      if (this.s.seats.some((x) => x?.login === name)) continue;
      const free = this.s.seats.findIndex((x, i) => !x && !this.holds()[i]);
      if (free < 0) break;
      const id = -1 - names.indexOf(name);
      this.s.seats[free] = this.blankSeat({ userId: id, login: name, avatarUrl: null }, true, BUY_IN_BB * config.bb);
      bots++;
    }
    this.scheduleStart(now);
  }

  /** 两手之间：结算离桌和输光的人，机器人补码。 */
  private cleanup(now: number) {
    this.s.seats.forEach((x, i) => {
      if (!x) return;
      if (!x.bot && x.away !== null && now - x.away > AWAY_KICK_MS) x.leaving = true;
      if (x.leaving) return this.standUp(i);
      // 在这张桌输光了：先站起来，座位替他占 10 秒，有余额的话可以原位再买入
      if (!x.bot && x.stack === 0) {
        this.standUp(i);
        this.holds()[i] = { userId: x.userId, login: x.login, avatarUrl: x.avatarUrl, start: now, until: now + HOLD_MS };
        return;
      }
      if (x.bot && x.stack < MIN_BUY_IN_BB * this.s.config.bb) x.stack = BUY_IN_BB * this.s.config.bb;
      Object.assign(x, {
        inHand: false, folded: false, allIn: false, bet: 0, committed: 0, acted: false, mayRaise: true,
        hole: [], shown: false, showMask: 0, last: null, won: 0, hand: null,
      });
    });
    this.syncBots(now);
  }

  /** 从 from 往后（顺时针）找第一个满足条件的座位，不含 from 自己。 */
  private nextSeat(from: number, ok: (i: number) => boolean): number {
    for (let k = 1; k <= SEATS; k++) {
      const i = (from + k + SEATS) % SEATS;
      if (ok(i)) return i;
    }
    return -1;
  }

  private startHand(now: number) {
    const { sb, bb } = this.s.config;
    const players = this.eligible();
    this.s.handNo += 1;
    this.s.deck = shuffle(newDeck());
    this.s.board = [];
    this.s.say = null;
    for (const i of players) this.s.seats[i]!.inHand = true;
    const inHand = (i: number) => !!this.s.seats[i]?.inHand;

    this.s.button = this.nextSeat(this.s.button, inHand);
    const headsUp = players.length === 2;
    const sbSeat = headsUp ? this.s.button : this.nextSeat(this.s.button, inHand);
    const bbSeat = this.nextSeat(sbSeat, inHand);
    this.pay(sbSeat, sb);
    this.s.seats[sbSeat]!.last = "小盲";
    this.pay(bbSeat, bb);
    this.s.seats[bbSeat]!.last = "大盲";
    this.s.currentBet = bb;
    this.s.minRaise = bb;

    for (let round = 0; round < 2; round++) {
      let i = sbSeat;
      do {
        this.s.seats[i]!.hole.push(this.s.deck.pop()!);
        i = this.nextSeat(i, inHand);
      } while (i !== sbSeat);
    }

    this.s.street = "preflop";
    this.moveOn(bbSeat, now);
  }

  private pay(i: number, amount: number) {
    const seat = this.s.seats[i]!;
    const x = Math.min(amount, seat.stack);
    seat.stack -= x;
    seat.bet += x;
    seat.committed += x;
    if (seat.stack === 0) seat.allIn = true;
  }

  private live(): number[] {
    const out: number[] = [];
    this.s.seats.forEach((x, i) => x?.inHand && !x.folded && out.push(i));
    return out;
  }

  /** 下一个要行动的人；没人需要再行动返回 -1。 */
  private findNext(from: number): number {
    const canAct = this.live().filter((i) => !this.s.seats[i]!.allIn);
    const lone = canAct.length === 1 ? this.s.seats[canAct[0]]! : null;
    if (canAct.length === 0 || (lone && lone.bet >= this.s.currentBet)) return -1;
    return this.nextSeat(from, (i) => {
      const x = this.s.seats[i];
      return !!x && x.inHand && !x.folded && !x.allIn && (!x.acted || x.bet < this.s.currentBet);
    });
  }

  private moveOn(from: number, now: number): void {
    if (this.live().length === 1) return this.winByFold(now);
    const next = this.findNext(from);
    if (next === -1) return this.endStreet(now);
    this.s.toAct = next;
    const seat = this.s.seats[next]!;
    this.s.turnStart = now;
    this.s.deadline = now + (seat.bot ? 700 + Math.random() * 1100 : seat.away !== null ? AWAY_TURN_MS : TURN_MS);
  }

  private apply(i: number, action: "fold" | "check" | "call" | "raise", amount: number | undefined, now: number): string | null {
    const seat = this.s.seats[i]!;
    const legal = this.legal(i)!;
    switch (action) {
      case "fold":
        seat.folded = true;
        seat.last = "弃牌";
        break;
      case "check":
        if (!legal.canCheck) return "现在不能过牌";
        seat.last = "过牌";
        break;
      case "call":
        if (legal.canCheck) {
          seat.last = "过牌";
          break;
        }
        this.pay(i, legal.toCall);
        seat.last = seat.allIn ? "全下" : "跟注";
        break;
      case "raise": {
        if (!legal.canRaise) return "现在不能加注";
        const to = Math.floor(Number(amount));
        if (!Number.isFinite(to) || to > legal.maxRaiseTo || to < legal.minRaiseTo) {
          return `加注要在 ${chips(legal.minRaiseTo)} 到 ${chips(legal.maxRaiseTo)} 之间`;
        }
        const before = this.s.currentBet;
        this.pay(i, to - seat.bet);
        const size = to - before;
        this.s.currentBet = to;
        const full = size >= this.s.minRaise;
        if (full) this.s.minRaise = size;
        for (const j of this.live()) {
          if (j === i) continue;
          const o = this.s.seats[j]!;
          o.acted = false;
          if (full) o.mayRaise = true;
        }
        seat.last = seat.allIn ? "全下" : before === 0 ? `下注 ${chips(to)}` : `加注到 ${chips(to)}`;
        break;
      }
      default:
        return "看不懂的操作";
    }
    seat.acted = true;
    seat.mayRaise = false;
    this.moveOn(i, now);
    return null;
  }

  private foldOutOfTurn(i: number, now: number) {
    const seat = this.s.seats[i]!;
    if (this.s.toAct === i) {
      this.apply(i, "fold", undefined, now);
      return;
    }
    seat.folded = true;
    seat.last = "弃牌";
    if (this.live().length === 1) this.winByFold(now);
    else if (this.findNext(i) === -1) this.endStreet(now);
  }

  private endStreet(now: number): void {
    for (const x of this.s.seats) {
      if (!x) continue;
      x.bet = 0;
      x.acted = false;
      x.mayRaise = true;
      if (x.inHand && !x.folded && !x.allIn) x.last = null;
    }
    this.s.currentBet = 0;
    this.s.minRaise = this.s.config.bb;
    this.s.toAct = -1;
    this.s.deadline = null;

    const order: Street[] = ["preflop", "flop", "turn", "river"];
    const k = order.indexOf(this.s.street);
    if (k === 3) return this.showdown(now);
    this.s.deck.pop(); // 烧一张
    const n = k === 0 ? 3 : 1;
    for (let j = 0; j < n; j++) this.s.board.push(this.s.deck.pop()!);
    this.s.street = order[k + 1];

    const next = this.findNext(this.s.button);
    if (next === -1) return this.endStreet(now); // 都全下了，直接发完
    this.moveOn(this.s.button, now);
  }

  private winByFold(now: number) {
    const [w] = this.live();
    const seat = this.s.seats[w]!;
    const pot = this.s.seats.reduce((sum, x) => sum + (x?.committed ?? 0), 0);
    seat.stack += pot;
    seat.won = pot;
    this.finish(now, FOLD_WIN_PAUSE_MS, `${seat.login} 赢下底池 ${chips(pot)}`);
  }

  private showdown(now: number) {
    const live = this.live();
    const scores = new Map<number, number>();
    for (const i of live) {
      const seat = this.s.seats[i]!;
      seat.shown = true;
      const sc = bestScore([...seat.hole, ...this.s.board]);
      scores.set(i, sc);
      seat.hand = handName(sc);
    }
    const contrib = this.s.seats.map((x) => x?.committed ?? 0);
    const folded = this.s.seats.map((x) => !x || !x.inHand || x.folded);
    // 从庄家左手边开始顺时针，零头先给离庄家最近的赢家
    const order = Array.from({ length: SEATS }, (_, k) => (this.s.button + 1 + k) % SEATS);
    for (const pot of buildPots(contrib, folded)) {
      const best = Math.max(...pot.eligible.map((i) => scores.get(i)!));
      const winners = order.filter((i) => pot.eligible.includes(i) && scores.get(i) === best);
      const share = Math.floor(pot.amount / winners.length);
      let rest = pot.amount - share * winners.length;
      for (const i of winners) {
        const x = share + (rest-- > 0 ? 1 : 0);
        this.s.seats[i]!.stack += x;
        this.s.seats[i]!.won += x;
      }
    }
    const top = live.filter((i) => this.s.seats[i]!.won > 0).sort((a, b) => this.s.seats[b]!.won - this.s.seats[a]!.won);
    const say = top
      .map((i) => `${this.s.seats[i]!.login} 以${this.s.seats[i]!.hand}赢下 ${chips(this.s.seats[i]!.won)}`)
      .join("，");
    this.s.street = "showdown";
    this.finish(now, SHOWDOWN_PAUSE_MS, say);
  }

  private finish(now: number, pause: number, say: string) {
    this.s.street = "showdown";
    this.s.toAct = -1;
    this.s.deadline = null;
    this.s.say = say;
    this.s.nextHandAt = now + pause;
  }
}

/**
 * 按每人投入切出主池和边池。弃牌的人投入的筹码照样进池，但没资格分。
 * 某一层只有弃牌的人（正常打不出来），筹码并进下一层。
 */
export function buildPots(contrib: number[], folded: boolean[]): { amount: number; eligible: number[] }[] {
  const levels = [...new Set(contrib.filter((c) => c > 0))].sort((a, b) => a - b);
  const pots: { amount: number; eligible: number[] }[] = [];
  let prev = 0;
  let carry = 0;
  for (const level of levels) {
    let amount = carry;
    const eligible: number[] = [];
    contrib.forEach((c, i) => {
      if (c < level) return;
      amount += level - prev;
      if (!folded[i]) eligible.push(i);
    });
    prev = level;
    if (!eligible.length) {
      carry = amount;
      continue;
    }
    carry = 0;
    const last = pots[pots.length - 1];
    // 资格相同的相邻层合并成一个池
    if (last && last.eligible.join() === eligible.join()) last.amount += amount;
    else pots.push({ amount, eligible });
  }
  if (carry && pots.length) pots[pots.length - 1].amount += carry;
  return pots;
}
