import type { Card } from "./cards";

export const SEATS = 6;

export type Street = "idle" | "preflop" | "flop" | "turn" | "river" | "showdown";

/** 客户端发给牌桌的消息。amount 是这一轮下注到的总额（加注到多少），单位筹码。 */
export type ClientMsg =
  /** buyIn：带入多少筹码，不填按 100 个大盲 */
  | { t: "sit"; seat: number; buyIn?: number }
  | { t: "leave" }
  /** 点了空位先占座，选好带入再 sit；取消就 release */
  | { t: "hold"; seat: number }
  | { t: "release" }
  /** 赢了没摊牌时亮牌：0 第一张，1 第二张，2 两张 */
  | { t: "show"; which: number }
  /** 用道具、发表情 */
  | { t: "item"; item: "timecard" | "peek" | "runout" }
  | { t: "emote"; id: string }
  | { t: "act"; action: "fold" | "check" | "call" | "raise"; amount?: number }
  | { t: "ping" };

export interface SeatView {
  login: string;
  avatarUrl: string | null;
  bot: boolean;
  stack: number;
  bet: number;
  inHand: boolean;
  folded: boolean;
  allIn: boolean;
  /** 只有自己的牌和摊牌亮出来的牌有值；别人的暗牌是 null，没拿牌是空数组 */
  cards: (Card | null)[];
  /** 这个人的牌背、牌面款式（商场里换的），null 是默认款 */
  back: string | null;
  face: string | null;
  /** 戴在名字后面的成就徽章（最多 3 个） */
  badges: string[];
  away: boolean;
  leaving: boolean;
  /** 刚才的动作，例如「跟注」「加注到 300」 */
  last: string | null;
  /** 亮给大家的牌：第 1 位第一张，第 2 位第二张；摊牌是 3 */
  showMask: number;
  /** 这手只赢到边池（没赢主池） */
  sidePot: boolean;
  /** 本手赢到的筹码（摊牌后） */
  won: number;
  hand: string | null;
}

export interface Legal {
  canCheck: boolean;
  /** 跟注还需要补多少（已封顶到自己剩余筹码） */
  toCall: number;
  canRaise: boolean;
  /** 合法的「加注到」区间；只能全下时两者相等 */
  minRaiseTo: number;
  maxRaiseTo: number;
}

export interface TableView {
  no: number;
  blinds: [number, number];
  bots: boolean;
  handNo: number;
  street: Street;
  button: number;
  board: Card[];
  /** 已经收进底池的 + 这一轮桌上的下注 */
  pot: number;
  seats: (SeatView | null)[];
  toAct: number;
  /** 当前行动截止时间（毫秒时间戳，服务器时钟） */
  deadline: number | null;
  /** 这次行动从什么时候开始、一共多长（毫秒），画倒计时圈用 */
  turnStart: number | null;
  turnMs: number | null;
  serverNow: number;
  you: number | null;
  legal: Legal | null;
  /** 牌局播报，例如「nightowl 以两对赢下 1,200」 */
  say: string | null;
  /** 每个座位的占座（有人点了空位正在选带入） */
  holds: ({ login: string; avatarUrl: string | null; start: number; until: number; you: boolean } | null)[];
  /** 最近几秒的桌面事件：谁用了道具、谁发了表情 */
  events: TableEvent[];
  /** 自己用偷偷看看到的别人的底牌（按座位），没用是 null */
  peek: (Card[] | null)[] | null;
  /** 自己用发发看看到的、没翻出来的公共牌 */
  runout: Card[] | null;
  /** 自己的道具现在能不能用（不管有没有库存） */
  canUse: { timecard: boolean; peek: boolean; runout: boolean } | null;
}

export interface TableEvent {
  id: number;
  at: number;
  kind: "item" | "emote";
  seat: number;
  login: string;
  /** 道具 id 或表情 id */
  what: string;
}

/** closed：玩家开的桌没人了，已经收掉 */
export type ServerMsg = { t: "state"; view: TableView } | { t: "error"; msg: string } | { t: "pong" } | { t: "closed" };
