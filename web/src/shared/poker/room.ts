// 一张德州牌桌的完整状态机：入座、离桌、发牌、下注、边池、摊牌。
// 纯逻辑，不碰网络和存储：服务端的 Durable Object 和预览版的本地牌桌都包一层用它。
// 状态是普通 JSON，可以直接存进 Durable Object 的存储。

import { bestScore, handName, newDeck, randomInt, shuffle, type Card } from "./cards";
import { botDecide } from "./bot";
import { SEATS, type Legal, type SeatView, type Street, type TableEvent, type TableView } from "./types";
import { TIME_CARD_MS, type ItemId } from "../cosmetics";
import { BIG_POT } from "../achievements";

export interface RoomConfig {
  no: number;
  sb: number;
  bb: number;
  /** 机器人桌：三个机器人隔一个座位坐着一直打，有没有真人都一样（见 TABLE_BOTS） */
  bots: boolean;
  /** 预览版用：固定这几个机器人一直坐着打，不管有没有真人 */
  fixedBots?: string[];
  /** 玩家开的桌：没有真人坐着一段时间后收掉 */
  temporary?: boolean;
  /** 这张桌在大厅里开出来的时刻（D1 的 created_at）。桌号被重新用上时，靠它认出存档是上一张桌留下的 */
  since?: string;
}

export interface Player {
  userId: number;
  login: string;
  avatarUrl: string | null;
  /** 商场里换上的牌背、牌面，同桌的人都看得到；机器人和旧存档没有 */
  back?: string;
  face?: string;
  /** 戴在名字后面的成就徽章（最多 3 个） */
  badges?: string[];
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
  /** 这次行动用过加时卡了 */
  extended?: boolean;
  /** 这手结束后用了偷偷看 / 发发看 */
  peeked?: boolean;
  runout?: Card[] | null;
  /** 上次发表情的时刻，防刷屏 */
  lastEmote?: number;
  /** 这手只赢到边池（没赢主池），WIN 牌子上注明 */
  sideOnly?: boolean;
  /** 这一手翻牌前的统计：主动入池、翻前加注、面对一次加注（有机会 3-bet）、3-bet */
  pf?: { vpip: boolean; pfr: boolean; tbOpp: boolean; tb: boolean };
  last: string | null;
  /** 上一条街最后的动作：进入下一条街时 last 清掉、挪到这里，网页在头顶再留一会儿（不然最后一个行动的人的动作根本看不到） */
  prev?: string | null;
  /** 这一手行动了几次：网页拿它当头顶标签的 key，每次行动都重新弹一下（字一样也弹） */
  acts?: number;
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

/** 一个人打完一手的统计：手数、赢没赢、VPIP、PFR、3-bet 机会和 3-bet */
export interface HandStat {
  userId: number;
  won: boolean;
  vpip: boolean;
  pfr: boolean;
  tbOpp: boolean;
  tb: boolean;
  /** 这一手的输赢：赢到的 - 投进去的（没被跟的部分已经退回） */
  net?: number;
  /** 这一手结束的日子（UTC，YYYY-MM-DD） */
  day?: string;
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
  /** 没人能再行动（都全下了）时，下一条街什么时候发；旧存档没有 */
  runoutAt?: number | null;
  say: string | null;
  /** 待写回账户的筹码；宿主写成功后调用 ackCashout */
  cashouts: Cashout[];
  /** 玩家开的桌从这一刻起没有真人；旧存档没有这个字段 */
  emptySince?: number | null;
  /** 每个座位的占座；旧存档没有这个字段 */
  holds?: (Hold | null)[];
  /** 机器人桌上赢够离桌的机器人：打完第几手之后再回来 */
  botBreaks?: Record<string, number>;
  /** 机器人桌没人看、停手的时刻；有人回来时从这里补打 */
  pausedAt?: number | null;
  /** 机器人今天（UTC 日期，和全站的「今天」一致）每手输赢加起来是多少，按名字记 */
  botDay?: { day: string; net: Record<string, number> };
  /** 这一手翻牌前已经有几次加注（大盲不算） */
  pfRaises?: number;
  /** 打完的手的统计，宿主写进 poker_stats 后调用 ackStats */
  stats?: HandStat[];
  /** 牌桌上达成的成就（大赢家、同花顺），宿主写进账户后调用 ackUnlock */
  unlocks?: { userId: number; id: "big_pot" | "full_house" | "quads" | "straight_flush" }[];
  /** 最近几秒的桌面事件（用了道具、发了表情），推给所有人 */
  events?: TableEvent[];
  eventSeq?: number;
  /** 每个人上次扔番茄、送玫瑰的时刻（按 userId），防刷屏 */
  throwAt?: Record<number, number>;
  /** 每个人上次掷骰子的时间 */
  rollAt?: Record<number, number>;
}

/** 入座带入：自己选 40～200 个大盲，默认 100 个。 */
export const BUY_IN_BB = 100;
export const MIN_BUY_IN_BB = 40;
export const MAX_BUY_IN_BB = 200;
/** 开桌可选的盲注 */
export const BLIND_LEVELS: [number, number][] = [[1, 2], [2, 5], [5, 10], [10, 20], [25, 50], [50, 100], [100, 200], [200, 400]];
export const TURN_MS = 15_000;
/** 桌面事件保留多久 */
const EVENT_MS = 8_000;
/** 两次表情至少隔多久 */
const EMOTE_GAP_MS = 1_500;
/** 同一个人两次扔番茄 / 送玫瑰至少隔多久（五连发自己要飞一秒多） */
const THROW_GAP_MS = 2_000;
/** 同一个人两次掷骰子至少隔多久 */
const ROLL_GAP_MS = 2_000;
/** 点了空位选带入时占座多久 */
export const HOLD_MS = 10_000;
/** 玩家开的桌没有真人超过这么久就收掉 */
export const EMPTY_TABLE_MS = 30_000;
const AWAY_TURN_MS = 5_000;
/** 断线超过这么久，下一手开始前自动离桌 */
const AWAY_KICK_MS = 60_000;
const START_DELAY_MS = 1_500;
/** 都全下之后，一条街一条街按这个节奏发，不一下子发完 */
export const RUNOUT_STEP_MS = 2_400;
const SHOWDOWN_PAUSE_MS = 9_000;
const FOLD_WIN_PAUSE_MS = 5_000;

/** 机器人桌上的三个机器人（C、G、D）；坐 BOT_SEATS 里对应的座位：隔一个座位坐，互相不挨着 */
export const TABLE_BOTS = ["bot-C", "bot-G", "bot-D"];
export const BOT_SEATS = [0, 2, 4];
/** 机器人桌的机器人带 50 个大盲（1/2 的桌就是 $100）；输光了再带 50 个，
 *  赢到 100 个大盲（$200）以上就离桌，歇一手再带 50 个回来 */
export const BOT_BUY_IN_BB = 50;
export const BOT_CASH_OUT_BB = 100;
/** 补打时最多真打几手（几十毫秒）；停得再久，多出来的只把手数往前加，筹码早就打乱了 */
export const CATCH_UP_HANDS = 500;
/** 机器人桌一手大约多久，算停手期间错过了几手（机器人每次想 1.5～3 秒，模拟下来平均 29 秒一手） */
const BOT_HAND_MS = 29_000;
/** 摊牌亮出这些牌型解锁对应成就 */
const HAND_UNLOCKS: Record<string, "full_house" | "quads" | "straight_flush"> = { 葫芦: "full_house", 四条: "quads", 同花顺: "straight_flush", 皇家同花顺: "straight_flush" };

/** 时刻所在的日期（UTC），全站的「今天」都按这个算 */
const dayOf = (now: number) => new Date(now).toISOString().slice(0, 10);

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
    room.syncBots();
    room.scheduleStart(0);
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
    const t = [this.s.deadline, this.s.nextHandAt, this.s.runoutAt ?? null, closeAt, this.idleKickAt(), holdEnd].filter((x): x is number => x !== null);
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

  /** 桌上没有真人、没人在占座、也没有没结算的筹码（机器人可以还坐着）。 */
  vacant(): boolean {
    return !(this.s.seats.some((x) => x && !x.bot) || this.s.cashouts.length > 0 || this.holds().some(Boolean));
  }

  /** 机器人桌没人看：停手，记下停在什么时候。宿主之后不再排闹钟。 */
  pause(now: number) {
    this.s.pausedAt ??= now;
  }

  /**
   * 有人回来（连上来或闹钟响了）：把停手这段时间补打上，看起来就像一直在打。
   * 按原来的节奏一手一手真打，最多 CATCH_UP_HANDS 手；停得更久的，剩下的时间只把手数往前加，
   * 再把各种计时挪到现在，从这里接着打。
   */
  resume(now: number) {
    const from = this.s.pausedAt;
    if (from === undefined || from === null) return;
    this.s.pausedAt = null;
    const start = this.s.handNo;
    let t = from;
    // 一手大约十次 tick；guard 防着哪里漏清计时器时在这里空转
    for (let guard = 0; guard < CATCH_UP_HANDS * 40 && this.s.handNo - start < CATCH_UP_HANDS; guard++) {
      const next = this.nextWake();
      if (next === null || next > now) return;
      t = Math.max(t, next);
      this.tick(t);
    }
    if ((this.nextWake() ?? Infinity) > now) return;
    const shift = now - t;
    this.s.handNo += Math.floor(shift / BOT_HAND_MS);
    for (const k of ["deadline", "turnStart", "nextHandAt", "runoutAt"] as const) {
      const v = this.s[k];
      if (typeof v === "number") this.s[k] = v + shift;
    }
    this.s.events = [];
  }

  /** 宿主每次存档前调用：记下空桌的起点。 */
  checkEmpty(now: number) {
    if (!this.s.config.temporary) return;
    if (!this.vacant()) this.s.emptySince = null;
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
    this.syncBots();
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

  /** 一手结束后亮牌给大家看：赢了没摊牌（别人都弃了）的、中途弃了牌的都可以。which 0 第一张，1 第二张，2 两张。 */
  show(userId: number, which: number): string | null {
    const i = this.seatOf(userId);
    const seat = this.s.seats[i];
    if (!seat) return "你没有坐在这张桌上";
    if (this.s.street !== "showdown" || !seat.inHand || !seat.hole.length) return "现在不能亮牌";
    if (![0, 1, 2].includes(which)) return "看不懂的操作";
    seat.showMask = (seat.showMask ?? 0) | (which === 2 ? 3 : 1 << which);
    return null;
  }

  /** 道具现在能不能用；能用返回 null，不能用返回原因。 */
  canUseItem(userId: number, item: ItemId): string | null {
    const i = this.seatOf(userId);
    const seat = this.s.seats[i];
    if (!seat) return "你没有坐在这张桌上";
    switch (item) {
      case "timecard":
        if (!this.inProgress || this.s.toAct !== i) return "轮到你时才能用加时卡";
        return seat.extended ? "这次行动已经加过时了" : null;
      case "peek":
        if (this.s.street !== "showdown" || !seat.inHand) return "一手结束后才能偷偷看";
        if (seat.peeked) return "这手已经看过了";
        return this.s.seats.some((x, j) => j !== i && x?.inHand && x.hole.length && !x.shown && (x.showMask ?? 0) !== 3)
          ? null
          : "没有没亮出来的牌";
      case "runout":
        if (this.s.street !== "showdown" || !seat.inHand) return "一手结束后才能发发看";
        if (seat.runout) return "这手已经看过了";
        return this.s.board.length < 5 ? null : "公共牌已经发完了";
      default:
        return "没有这个道具";
    }
  }

  /** 用道具（宿主已经扣掉库存）。偷偷看、发发看只有自己看得到，但会告诉全桌。 */
  useItem(userId: number, item: ItemId, now: number): string | null {
    const err = this.canUseItem(userId, item);
    if (err) return err;
    const i = this.seatOf(userId);
    const seat = this.s.seats[i]!;
    if (item === "timecard") {
      seat.extended = true;
      this.s.deadline! += TIME_CARD_MS;
    } else if (item === "peek") seat.peeked = true;
    else seat.runout = this.runoutCards();
    this.event({ kind: "item", seat: i, login: seat.login, what: item }, now);
    return null;
  }

  /** 发表情；owned 是这个人有的表情 */
  emote(userId: number, id: string, owned: string[], now: number): string | null {
    const i = this.seatOf(userId);
    const seat = this.s.seats[i];
    if (!seat) return "坐下才能发表情";
    if (!owned.includes(id)) return "还没有这个表情";
    if (seat.lastEmote && now - seat.lastEmote < EMOTE_GAP_MS) return "慢一点";
    seat.lastEmote = now;
    this.event({ kind: "emote", seat: i, login: seat.login, what: id }, now);
    return null;
  }

  /** 扔番茄、送玫瑰前检查：目标座位上有人、不能扔给自己、别扔太快。扣钱由宿主在这之后、throwAt() 之前做 */
  canThrow(userId: number, target: number, now: number): string | null {
    if (!Number.isInteger(target) || !this.s.seats[target]) return "那个座位上没有人";
    if (this.s.seats[target]!.userId === userId) return "不能扔给自己";
    const last = this.s.throwAt?.[userId];
    if (last && now - last < THROW_GAP_MS) return "慢一点";
    return null;
  }

  /** 扔番茄、送玫瑰：在对方头像那里播动画；from 是扔的人的座位（旁观就是 null） */
  throwAt(thrower: { userId: number; login: string }, target: number, item: "tomato" | "rose", n: 1 | 5, now: number): string | null {
    const err = this.canThrow(thrower.userId, target, now);
    if (err) return err;
    this.s.throwAt = { ...Object.fromEntries(Object.entries(this.s.throwAt ?? {}).filter(([, t]) => now - t < THROW_GAP_MS)), [thrower.userId]: now };
    const from = this.seatOf(thrower.userId);
    this.event({ kind: "throw", seat: target, login: thrower.login, what: `${item}:${n}`, from: from >= 0 ? from : null }, now);
    return null;
  }

  /** 掷骰子：0–100 的随机数，坐着的、旁观的都能掷，全桌都看得到。数在服务端出，谁也改不了 */
  roll(user: { userId: number; login: string }, now: number, rand: (n: number) => number = randomInt): string | null {
    const last = this.s.rollAt?.[user.userId];
    if (last && now - last < ROLL_GAP_MS) return "慢一点";
    this.s.rollAt = { ...Object.fromEntries(Object.entries(this.s.rollAt ?? {}).filter(([, t]) => now - t < ROLL_GAP_MS)), [user.userId]: now };
    this.event({ kind: "roll", seat: this.seatOf(user.userId), login: user.login, what: String(rand(101)) }, now);
    return null;
  }

  private event(e: Omit<TableEvent, "id" | "at">, now: number) {
    const id = (this.s.eventSeq = (this.s.eventSeq ?? 0) + 1);
    this.s.events = [...(this.s.events ?? []).filter((x) => now - x.at < EVENT_MS).slice(-9), { ...e, id, at: now }];
  }

  /** 这手没发完的公共牌：照着发牌的顺序（先烧一张）从剩下的牌里往后数 */
  private runoutCards(): Card[] {
    const deck = [...this.s.deck];
    const board = [...this.s.board];
    while (board.length < 5) {
      deck.pop();
      for (let n = board.length === 0 ? 3 : 1; n > 0; n--) board.push(deck.pop()!);
    }
    return board.slice(this.s.board.length);
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
      this.syncBots();
      this.scheduleStart(now);
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

  /** 重新连上时带来最新的牌背、牌面（在商场换了之后） */
  setLook(userId: number, back: string | undefined, face: string | undefined, badges?: string[]) {
    const i = this.seatOf(userId);
    if (i < 0) return;
    if (badges) this.s.seats[i]!.badges = badges;
    if (back) this.s.seats[i]!.back = back;
    if (face) this.s.seats[i]!.face = face;
  }

  setAway(userId: number, away: boolean, now: number) {
    const i = this.seatOf(userId);
    if (i < 0) return;
    this.s.seats[i]!.away = away ? (this.s.seats[i]!.away ?? now) : null;
  }

  ackStats(n: number) {
    this.s.stats = (this.s.stats ?? []).slice(n);
  }

  ackUnlock(userId: number, id: string) {
    this.s.unlocks = (this.s.unlocks ?? []).filter((u) => u.userId !== userId || u.id !== id);
  }

  ackCashout(ref: string) {
    this.s.cashouts = this.s.cashouts.filter((c) => c.ref !== ref);
  }

  /** 时钟推进：处理超时、机器人行动、开下一手。宿主在 nextWake() 时刻调用。 */
  tick(now: number) {
    for (let guard = 0; guard < 100; guard++) {
      if (this.inProgress && this.s.runoutAt && now >= this.s.runoutAt) {
        this.s.runoutAt = null;
        this.endStreet(now);
        continue;
      }
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
        this.syncBots();
        this.scheduleStart(now);
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
        // 弃了牌的人一手结束后自己亮了才给别人看（没亮的那张是背面）；没亮就什么都不给
        else if (!x.folded || mask) cards = x.hole.map((c, k) => (mask >> k) & 1 ? c : null);
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
        face: x.face ?? null,
        badges: x.badges ?? [],
        sidePot: !!x.sideOnly,
        showMask: x.shown ? 3 : (x.showMask ?? 0),
        away: x.away !== null,
        leaving: x.leaving,
        last: x.last,
        prev: x.last ? null : (x.prev ?? null),
        acts: x.acts ?? 0,
        won: x.won,
        hand: x.hand,
        today: x.bot ? (this.s.botDay?.day === dayOf(now) ? (this.s.botDay.net[x.login] ?? 0) : 0) : null,
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
      holds: this.holds().map((h) => h && { login: h.login, avatarUrl: h.avatarUrl, start: h.start, until: h.until, you: h.userId === userId }),
      events: (this.s.events ?? []).filter((e) => now - e.at < EVENT_MS),
      // 偷偷看：别人没亮的底牌（弃了的也算）；发发看：没翻出来的公共牌。都只给用的人
      peek: you >= 0 && this.s.seats[you]!.peeked && this.s.street === "showdown"
        ? this.s.seats.map((x, j) => (j !== you && x?.inHand && x.hole.length ? x.hole : null))
        : null,
      runout: you >= 0 && this.s.street === "showdown" ? (this.s.seats[you]!.runout ?? null) : null,
      canUse: you >= 0
        ? { timecard: !this.canUseItem(userId!, "timecard"), peek: !this.canUseItem(userId!, "peek"), runout: !this.canUseItem(userId!, "runout") }
        : null,
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

  /**
   * 机器人入座、离座，只在两手之间调整：机器人桌上 TABLE_BOTS 一直坐着打，有没有真人都一样；
   * 预览版的 fixedBots 也一直坐着；别的桌没有机器人（桌子改成真人桌时，留下的机器人请走）。
   * 补了人要不要排开局由调用的地方决定：两手之间的 cleanup 之后马上就开，不用再排。
   */
  private syncBots() {
    if (this.inProgress) return;
    const { config } = this.s;
    const names = config.fixedBots ?? (config.bots ? TABLE_BOTS : []);
    this.s.seats.forEach((x, i) => x?.bot && !names.includes(x.login) && (this.s.seats[i] = null));
    // 机器人桌上被挤到别处（自己的座位当时有人占）的机器人，自己的座位空出来就坐回去，三个机器人又隔开了
    if (!config.fixedBots) {
      names.forEach((name, k) => {
        const at = this.s.seats.findIndex((x) => x?.bot && x.login === name);
        const home = BOT_SEATS[k];
        if (at >= 0 && at !== home && !this.s.seats[home] && !this.holds()[home]) {
          this.s.seats[home] = this.s.seats[at];
          this.s.seats[at] = null;
        }
      });
    }
    const breaks = (this.s.botBreaks ??= {});
    // 歇着的机器人一般等一手再回来；剩下的人不够开局时马上回来，桌子不会停住
    const short = this.eligible().length < 2;
    names.forEach((name, k) => {
      if (this.s.seats.some((x) => x?.bot && x.login === name)) return;
      if (!short && (breaks[name] ?? 0) > this.s.handNo) return;
      const seat = this.botSeat(k);
      if (seat < 0) return;
      delete breaks[name];
      const buyIn = (config.fixedBots ? BUY_IN_BB : BOT_BUY_IN_BB) * config.bb;
      const bot = (this.s.seats[seat] = this.blankSeat({ userId: -1 - k, login: name, avatarUrl: null }, true, buyIn));
      if (!config.fixedBots && this.s.handNo > 0) bot.last = `带入 ${chips(buyIn)}`;
    });
  }

  /** 第 k 个机器人坐哪：机器人桌上先坐自己的座位（BOT_SEATS），被真人占了就找一个两边都不是机器人的空位，再没有就随便一个空位。 */
  private botSeat(k: number): number {
    const free = (i: number) => !this.s.seats[i] && !this.holds()[i];
    const all = [...Array(SEATS).keys()];
    if (this.s.config.fixedBots) return all.find(free) ?? -1;
    if (free(BOT_SEATS[k])) return BOT_SEATS[k];
    const bot = (i: number) => !!this.s.seats[(i + SEATS) % SEATS]?.bot;
    return all.find((i) => free(i) && !bot(i - 1) && !bot(i + 1)) ?? all.find(free) ?? -1;
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
      let rebuy = false;
      if (x.bot) {
        const { bb, fixedBots } = this.s.config;
        if (fixedBots) {
          if (x.stack < MIN_BUY_IN_BB * bb) x.stack = BUY_IN_BB * bb;
        } else if (x.stack > BOT_CASH_OUT_BB * bb) {
          // 赢够了：离桌歇一手，再带 50 个大盲回来（syncBots）
          this.standUp(i);
          (this.s.botBreaks ??= {})[x.login] = this.s.handNo + 1;
          return;
        } else if (x.stack < bb) {
          x.stack = BOT_BUY_IN_BB * bb;
          rebuy = true;
        }
      }
      Object.assign(x, {
        inHand: false, folded: false, allIn: false, bet: 0, committed: 0, acted: false, mayRaise: true,
        hole: [], shown: false, showMask: 0, peeked: false, runout: null, pf: undefined, sideOnly: false, last: null, prev: null, acts: 0, won: 0, hand: null,
      });
      if (rebuy) x.last = `带入 ${chips(x.stack)}`;
    });
    this.syncBots();
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
    this.s.pfRaises = 0;
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
    seat.extended = false;
    // 取整毫秒：宿主按这个时刻排闹钟，带小数的话闹钟会在差零点几毫秒时响，什么都做不了
    this.s.deadline = now + (seat.bot ? Math.round(1_500 + Math.random() * 1_500) : seat.away !== null ? AWAY_TURN_MS : TURN_MS);
  }

  private apply(i: number, action: "fold" | "check" | "call" | "raise", amount: number | undefined, now: number): string | null {
    const seat = this.s.seats[i]!;
    const legal = this.legal(i)!;
    const raisesBefore = this.s.pfRaises ?? 0;
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
    // 翻牌前的统计：跟注或加注算主动入池（大盲过牌不算），面对正好一次加注时有 3-bet 机会
    if (this.s.street === "preflop") {
      const pf = (seat.pf ??= { vpip: false, pfr: false, tbOpp: false, tb: false });
      if (raisesBefore === 1) pf.tbOpp = true;
      if (action === "call" && !legal.canCheck) pf.vpip = true;
      if (action === "raise") {
        pf.vpip = pf.pfr = true;
        if (raisesBefore === 1) pf.tb = true;
        this.s.pfRaises = raisesBefore + 1;
      }
    }
    seat.acted = true;
    seat.mayRaise = false;
    seat.acts = (seat.acts ?? 0) + 1;
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
    seat.acts = (seat.acts ?? 0) + 1;
    if (this.live().length === 1) this.winByFold(now);
    else if (this.findNext(i) === -1) this.endStreet(now);
  }

  private endStreet(now: number): void {
    for (const x of this.s.seats) {
      if (!x) continue;
      x.bet = 0;
      x.acted = false;
      x.mayRaise = true;
      x.prev = null;
      if (x.inHand && !x.folded && !x.allIn) {
        x.prev = x.last;
        x.last = null;
      }
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
    if (next === -1) {
      // 没人能再行动了（都全下了）：把牌亮出来，剩下的街隔一会儿发一条，按节奏翻
      for (const i of this.live()) this.s.seats[i]!.shown = true;
      this.s.runoutAt = now + RUNOUT_STEP_MS;
      return;
    }
    this.moveOn(this.s.button, now);
  }

  /**
   * 没人跟的下注退回：投入最多的人比第二多的人多出来的部分，没有人能跟，原样还给他，不算赢。
   * 不退的话，边池里只有他一个人有资格，会被当成「赢」显示出来。
   */
  private returnUncalled() {
    const order = this.s.seats
      .map((x, i) => ({ i, c: x?.committed ?? 0 }))
      .sort((a, b) => b.c - a.c);
    const [top, second] = order;
    const extra = top.c - (second?.c ?? 0);
    if (extra <= 0) return;
    const seat = this.s.seats[top.i]!;
    seat.committed -= extra;
    seat.bet = Math.max(0, seat.bet - extra);
    seat.stack += extra;
  }

  private winByFold(now: number) {
    this.returnUncalled();
    const [w] = this.live();
    const seat = this.s.seats[w]!;
    const pot = this.s.seats.reduce((sum, x) => sum + (x?.committed ?? 0), 0);
    seat.stack += pot;
    seat.won = pot;
    this.finish(now, FOLD_WIN_PAUSE_MS, `${seat.login} 赢下底池 ${chips(pot)}`);
  }

  private showdown(now: number) {
    this.returnUncalled();
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
    const mainWinners = new Set<number>();
    buildPots(contrib, folded).forEach((pot, k) => {
      const best = Math.max(...pot.eligible.map((i) => scores.get(i)!));
      const winners = order.filter((i) => pot.eligible.includes(i) && scores.get(i) === best);
      if (k === 0) winners.forEach((i) => mainWinners.add(i));
      const share = Math.floor(pot.amount / winners.length);
      let rest = pot.amount - share * winners.length;
      for (const i of winners) {
        const x = share + (rest-- > 0 ? 1 : 0);
        this.s.seats[i]!.stack += x;
        this.s.seats[i]!.won += x;
      }
    });
    for (const i of live) this.s.seats[i]!.sideOnly = this.s.seats[i]!.won > 0 && !mainWinners.has(i);
    const top = live.filter((i) => this.s.seats[i]!.won > 0).sort((a, b) => this.s.seats[b]!.won - this.s.seats[a]!.won);
    const say = top
      .map((i) => `${this.s.seats[i]!.login} 以${this.s.seats[i]!.hand}赢下 ${chips(this.s.seats[i]!.won)}`)
      .join("，");
    this.s.street = "showdown";
    this.finish(now, SHOWDOWN_PAUSE_MS, say);
  }

  private finish(now: number, pause: number, say: string) {
    this.s.runoutAt = null;
    // 牌桌上的成就：一手赢 $10,000 以上、摊牌亮出葫芦 / 四条 / 同花顺；每个真人这一手的统计
    for (const x of this.s.seats) {
      if (!x || x.bot || !x.inHand) continue;
      const pf = x.pf ?? { vpip: false, pfr: false, tbOpp: false, tb: false };
      (this.s.stats ??= []).push({ userId: x.userId, won: x.won > 0, ...pf, net: x.won - x.committed, day: dayOf(now) });
      if (x.won >= BIG_POT) (this.s.unlocks ??= []).push({ userId: x.userId, id: "big_pot" });
      const shownHand = x.shown && x.hand ? HAND_UNLOCKS[x.hand] : undefined;
      if (shownHand) (this.s.unlocks ??= []).push({ userId: x.userId, id: shownHand });
    }
    // 机器人这一手的输赢（赢到的减去投进去的）记进今天的账；补打的手按补打时的时刻算哪天
    const day = dayOf(now);
    if (this.s.botDay?.day !== day) this.s.botDay = { day, net: {} };
    for (const x of this.s.seats) {
      if (x?.bot && x.inHand) this.s.botDay.net[x.login] = (this.s.botDay.net[x.login] ?? 0) + x.won - x.committed;
    }
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
