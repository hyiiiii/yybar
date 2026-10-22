import { describe, expect, it } from "vitest";
import { bestScore, handName, type Card } from "../src/shared/poker/cards";
import { longestStreak } from "../src/shared/achievements";
import { BOT_BUY_IN_BB, BOT_CASH_OUT_BB, buildPots, CATCH_UP_HANDS, EMPTY_TABLE_MS, HOLD_MS, RUNOUT_STEP_MS, TABLE_BOTS, TableRoom, TURN_MS, type RoomState } from "../src/shared/poker/room";

const c = (s: string): Card => {
  const r = { T: 10, J: 11, Q: 12, K: 13, A: 14 }[s[0]] ?? Number(s[0]);
  return { r, s: "sgdc".indexOf(s[1]) };
};
const cards = (s: string) => s.split(" ").map(c);

describe("hand evaluation", () => {
  it("names hands", () => {
    expect(handName(bestScore(cards("As Ks Qs Js Ts 2d 3c")))).toBe("皇家同花顺");
    expect(handName(bestScore(cards("5s 4d 3c 2h Ad Kd Kc")))).toBe("顺子");
    expect(handName(bestScore(cards("9s 9d 9c 2h 2d Kd Qc")))).toBe("葫芦");
    expect(handName(bestScore(cards("9s 8s 2s 5s Ks Kd Qc")))).toBe("同花");
    expect(handName(bestScore(cards("9s 9d 5c 5h 2d 2c Ac")))).toBe("两对");
  });
  it("compares kickers and splits ties", () => {
    const board = "Ah Kd 7c 4s 2h";
    expect(bestScore(cards(`As Qd ${board}`))).toBeGreaterThan(bestScore(cards(`Ac Jd ${board}`)));
    expect(bestScore(cards("2c 3d Ts Jd Qs Kh Ad"))).toBe(bestScore(cards("4c 5d Ts Jd Qs Kh Ad")));
    // A2345 是最小的顺子
    expect(bestScore(cards("As 2d 3c 4h 5d Kc Kd"))).toBeLessThan(bestScore(cards("6s 2d 3c 4h 5d Kc Kd")));
  });
});

describe("side pots", () => {
  it("splits main and side pots, folded chips stay in", () => {
    // 0 全下 50；1、2 各投 200；3 投 30 后弃牌
    expect(buildPots([50, 200, 200, 30, 0, 0], [false, false, false, true, true, true])).toEqual([
      { amount: 50 * 3 + 30, eligible: [0, 1, 2] },
      { amount: 300, eligible: [1, 2] },
    ]);
  });
});

/** 伪造一个能控制牌序的牌桌：deck 从末尾发牌。 */
function rig(room: TableRoom, order: string) {
  const s = room.s as RoomState;
  s.deck = cards(order).reverse();
}

/** 都全下之后剩下的街按节奏发：一直往后拨时钟，直到发完 */
function runOut(room: TableRoom) {
  while (room.s.runoutAt) room.tick(room.s.runoutAt);
}

/** 桌上筹码总数：牌局中是剩余 + 已投入，摊牌后底池已经分到各人手里。 */
function total(room: TableRoom) {
  const settled = room.s.street === "showdown";
  return room.s.seats.reduce((sum, x) => sum + (x ? x.stack + (settled ? 0 : x.committed) : 0), 0);
}

describe("table flow", () => {
  const p = (id: number) => ({ userId: id, login: `u${id}`, avatarUrl: null });

  it("plays a heads-up hand to showdown and conserves chips", () => {
    const room = TableRoom.create({ no: 1, sb: 5, bb: 10, bots: false });
    expect(room.sit(p(1), 0, 1000, 0)).toBeNull();
    expect(room.sit(p(2), 3, 1000, 0)).toBeNull();
    room.tick(10_000);
    expect(room.s.street).toBe("preflop");
    // 两人桌：庄家是小盲，翻牌前先说话
    const btn = room.s.button;
    const other = btn === 0 ? 3 : 0;
    const uid = (i: number) => room.s.seats[i]!.userId;
    expect(room.s.toAct).toBe(btn);
    expect(room.act(uid(btn), "call", undefined, 10_001)).toBeNull();
    expect(room.act(uid(other), "check", undefined, 10_002)).toBeNull();
    expect(room.s.street).toBe("flop");
    expect(room.s.toAct).toBe(other);
    // 换街时动作清掉，但上一条街的（包括最后一个人的过牌）放在 prev 里给网页多留一会儿
    const seen = room.view(null, 10_002).seats;
    expect(seen[other]).toMatchObject({ last: null, prev: "过牌", acts: 1 });
    expect(seen[btn]).toMatchObject({ last: null, prev: "跟注" });
    expect(room.act(uid(other), "raise", 20, 10_003)).toBeNull();
    expect(room.view(null, 10_003).seats[other]).toMatchObject({ last: "下注 $20", prev: null, acts: 2 });
    expect(room.act(uid(btn), "raise", 25, 10_004)).toMatch(/加注要在/);
    expect(room.act(uid(btn), "raise", 60, 10_004)).toBeNull();
    expect(room.act(uid(other), "call", undefined, 10_005)).toBeNull();
    expect(room.s.street).toBe("turn");
    expect(total(room)).toBe(2000);
    for (const street of ["turn", "river"]) {
      expect(room.s.street).toBe(street);
      room.act(uid(other), "check", undefined, 10_006);
      room.act(uid(btn), "check", undefined, 10_007);
    }
    expect(room.s.street).toBe("showdown");
    expect(total(room)).toBe(2000);
    // 别人的暗牌摊牌前不下发
    room.tick(100_000);
    const v = room.view(1, 100_001);
    const opp = v.seats[v.you === 0 ? 3 : 0]!;
    expect(opp.cards.every((x) => x === null)).toBe(true);
  });

  it("handles all-in side pots and pays the right winners", () => {
    const room = TableRoom.create({ no: 1, sb: 5, bb: 10, bots: false });
    room.sit(p(1), 0, 100, 0);
    room.sit(p(2), 1, 500, 0);
    room.sit(p(3), 2, 500, 0);
    room.s.button = 2; // 下一手庄家在 0：0 庄、1 小盲、2 大盲
    room.s.nextHandAt = 1;
    room.tick(1);
    expect(room.s.button).toBe(0);
    // 重新发一副定好的牌：发牌从小盲开始，每人一张轮两圈
    room.s.seats.forEach((x) => x && (x.hole = []));
    rig(room, "As Kc 2d Ah Kd 7c  9s Qs Jd 3c  8h 4s  5d 6h".replace(/\s+/g, " "));
    const order = [1, 2, 0];
    for (let k = 0; k < 2; k++) for (const i of order) room.s.seats[i]!.hole.push(room.s.deck.pop()!);
    // 1: As Ah, 2: Kc Kd, 0: 2d 7c
    expect(room.s.toAct).toBe(0);
    room.act(1, "raise", 100, 2); // 0 全下 100
    room.act(2, "raise", 300, 3);
    room.act(3, "call", undefined, 4);
    expect(room.s.street).toBe("flop");
    room.act(2, "check", undefined, 5);
    room.act(3, "raise", 200, 6); // 3 全下
    room.act(2, "call", undefined, 7);
    runOut(room);
    expect(room.s.street).toBe("showdown");
    expect(total(room)).toBe(1100);
    // 公共牌 Qs Jd 3c 4s 6h，1 号座的 AA 主池边池都赢
    expect(room.s.seats[1]!.stack).toBe(1100);
    expect(room.s.seats[1]!.sideOnly).toBe(false);
    expect(room.s.seats[0]!.stack).toBe(0);
  });

  it("pays side pots like the screenshot hand: trips take main, equal pairs split the last side pot", () => {
    const room = TableRoom.create({ no: 1, sb: 5, bb: 10, bots: false });
    room.sit(p(1), 0, 5000, 0); // BTN
    room.sit(p(2), 1, 1000, 0); // SB
    room.sit(p(3), 2, 300, 0); // BB
    room.sit(p(4), 3, 5000, 0); // CO
    room.s.button = 3;
    room.s.nextHandAt = 1;
    room.tick(1);
    expect(room.s.button).toBe(0);
    room.s.seats.forEach((x) => x && (x.hole = []));
    // 发牌从小盲开始：SB、BB、CO、BTN 各一张轮两圈；公共牌 8 6 Q 8 A（中间烧牌）
    rig(room, "9d Kc Jg 9g 8s 3c Kg Ks 2s 8g 6d Qc 2d 8c 2c As");
    for (let k = 0; k < 2; k++) for (const i of [1, 2, 3, 0]) room.s.seats[i]!.hole.push(room.s.deck.pop()!);
    room.act(4, "raise", 2000, 2); // CO
    room.act(1, "call", undefined, 3); // BTN
    room.act(2, "call", undefined, 4); // SB 全下 1000
    room.act(3, "call", undefined, 5); // BB 全下 300
    while (room.s.street !== "showdown") room.act(room.s.seats[room.s.toAct]!.userId, "check", undefined, 6);
    const seat = (i: number) => room.s.seats[i]!;
    expect(seat(1).hand).toBe("三条");
    expect(seat(1).won).toBe(1200 + 2100); // 主池 + 第一个边池
    expect(seat(2).won).toBe(0); // BB 的一对 8 带 A K Q 也一样大，但它只有资格争主池
    expect([seat(0).won, seat(3).won]).toEqual([1000, 1000]); // 一样大，平分最后的边池
    expect([seat(0).sideOnly, seat(3).sideOnly, seat(1).sideOnly]).toEqual([true, true, false]);
    expect(total(room)).toBe(11300);
  });

  it("deals the rest of the board one street at a time after everyone is all-in", () => {
    const room = TableRoom.create({ no: 1, sb: 5, bb: 10, bots: false });
    room.sit(p(1), 0, 500, 0);
    room.sit(p(2), 1, 500, 0);
    room.tick(2000);
    const a = room.s.seats[room.s.toAct]!.userId;
    const b = a === 1 ? 2 : 1;
    room.act(a, "raise", 500, 3000); // 翻牌前全下
    room.act(b, "call", undefined, 3001);
    // 翻牌马上发，两个人的牌都亮出来；转牌、河牌按节奏一条一条来
    expect(room.s.street).toBe("flop");
    expect(room.s.board).toHaveLength(3);
    expect(room.view(null, 3001).seats.filter(Boolean).every((x) => x!.cards.every(Boolean))).toBe(true);
    expect(room.nextWake()).toBe(3001 + RUNOUT_STEP_MS);
    room.tick(3001 + RUNOUT_STEP_MS - 1);
    expect(room.s.board).toHaveLength(3);
    room.tick(3001 + RUNOUT_STEP_MS);
    expect(room.s.street).toBe("turn");
    expect(room.s.board).toHaveLength(4);
    room.tick(3001 + 2 * RUNOUT_STEP_MS);
    expect(room.s.board).toHaveLength(5);
    expect(room.s.street).toBe("river");
    room.tick(3001 + 3 * RUNOUT_STEP_MS);
    expect(room.s.street).toBe("showdown");
    expect(total(room)).toBe(1000);
  });

  it("returns an uncalled bet instead of paying it out as a win", () => {
    const room = TableRoom.create({ no: 1, sb: 5, bb: 10, bots: false });
    room.sit(p(1), 0, 1000, 0);
    room.sit(p(2), 1, 400, 0);
    room.sit(p(3), 2, 2000, 0);
    room.s.button = 2; // 下一手：0 庄、1 小盲、2 大盲
    room.s.nextHandAt = 1;
    room.tick(1);
    room.s.seats.forEach((x) => x && (x.hole = []));
    // 发牌从小盲开始：1、2、0 各一张，轮两圈；公共牌 Q 9 J 3 3（照截图那手）
    rig(room, "8s 2d 4c Kh Td 5c  7h Qs 9d Jc  6s 3h  2c 3d".replace(/\s+/g, " "));
    for (let k = 0; k < 2; k++) for (const i of [1, 2, 0]) room.s.seats[i]!.hole.push(room.s.deck.pop()!);
    // 1: 8s Kh（一对 3 带 K），2: 2d Td（一对 3 带 Q），0: 4c 5c
    room.act(1, "fold", undefined, 2);
    room.act(2, "raise", 400, 3); // 小盲全下 400
    room.act(3, "raise", 2000, 4); // 大盲全下 2000，多出来的 1600 没人跟
    runOut(room);
    expect(room.s.street).toBe("showdown");
    expect(room.s.seats[1]!.stack).toBe(800);
    expect(room.s.seats[1]!.won).toBe(800);
    // 没人跟的部分原样退回，不算赢
    expect(room.s.seats[2]!.won).toBe(0);
    expect(room.s.seats[2]!.stack).toBe(1600);
    expect(total(room)).toBe(3400);
  });

  it("records preflop stats: VPIP, PFR, 3-bet chances and 3-bets", () => {
    const room = TableRoom.create({ no: 1, sb: 5, bb: 10, bots: false });
    room.sit(p(1), 0, 1000, 0);
    room.sit(p(2), 1, 1000, 0);
    room.sit(p(3), 2, 1000, 0);
    room.s.button = 2; // 下一手：0 庄、1 小盲、2 大盲；三人桌庄家先说话
    room.s.nextHandAt = 1;
    room.tick(1);
    room.act(1, "raise", 30, 2); // 庄家开局加注
    room.act(2, "raise", 90, 3); // 小盲 3-bet
    room.act(3, "fold", undefined, 4); // 大盲面对两次加注，不算 3-bet 机会
    room.act(1, "call", undefined, 5);
    room.act(2, "check", undefined, 6);
    room.act(1, "fold", undefined, 7);
    const by = Object.fromEntries(room.s.stats!.map((x) => [x.userId, x]));
    expect(by[1]).toMatchObject({ won: false, vpip: true, pfr: true, tbOpp: false, tb: false });
    expect(by[2]).toMatchObject({ won: true, vpip: true, pfr: true, tbOpp: true, tb: true });
    expect(by[3]).toMatchObject({ won: false, vpip: false, pfr: false, tbOpp: false, tb: false });
    room.ackStats(3);
    expect(room.s.stats).toEqual([]);
  });

  it("returns chips on leave and refuses to act out of turn", () => {
    const room = TableRoom.create({ no: 1, sb: 5, bb: 10, bots: false });
    room.sit(p(1), 0, 1000, 0);
    expect(room.leave(1, 1)).toBeNull();
    expect(room.s.cashouts).toEqual([expect.objectContaining({ userId: 1, amount: 1000 })]);
    room.sit(p(1), 0, 1000, 2);
    room.sit(p(2), 1, 1000, 2);
    room.tick(5000);
    const notTurn = room.s.toAct === 0 ? 2 : 1;
    expect(room.act(notTurn, "check", undefined, 5001)).toBe("还没轮到你");
    room.leave(notTurn, 5002); // 牌局中离桌：先弃牌，对手直接赢
    expect(room.s.street).toBe("showdown");
    room.tick(20_000);
    expect(room.s.seats.filter(Boolean)).toHaveLength(1);
    expect(room.s.cashouts.at(-1)!.userId).toBe(notTurn);
    expect(total(room) + room.s.cashouts.at(-1)!.amount).toBe(2000);
  });

  it("times out to check or fold, and stands up after two timeouts", () => {
    const room = TableRoom.create({ no: 1, sb: 5, bb: 10, bots: false });
    room.sit(p(1), 0, 1000, 0);
    room.sit(p(2), 1, 1000, 0);
    room.tick(2000);
    const first = room.s.toAct;
    const v = room.view(1, 2000);
    expect(v.turnMs).toBe(TURN_MS);
    expect(v.turnStart).toBe(2000);
    room.tick(2000 + TURN_MS - 1);
    expect(room.s.toAct).toBe(first);
    room.tick(2000 + TURN_MS);
    // 两人桌翻牌前庄家要补小盲，超时就是弃牌
    expect(room.s.seats[first]!.folded).toBe(true);
    expect(room.s.seats[first]!.timeouts).toBe(1);
  });

  it("lets players pick a buy-in between 40 and 200 big blinds", () => {
    const room = TableRoom.create({ no: 1, sb: 5, bb: 10, bots: false });
    expect(room.pickBuyIn(5000)).toBe(1000);
    expect(room.pickBuyIn(600)).toBe(600);
    expect(room.pickBuyIn(5000, 1500)).toBe(1500);
    expect(room.pickBuyIn(5000, 2500)).toMatch(/带入要在 \$400 到 \$2,000 之间/);
    expect(room.pickBuyIn(5000, 300)).toMatch(/带入要在/);
    expect(room.pickBuyIn(1200, 1500)).toMatch(/\$1,200/);
    expect(room.pickBuyIn(399)).toMatch(/筹码不够/);
  });

  it("closes a player-opened table after it sits empty", () => {
    const room = TableRoom.create({ no: 1, sb: 5, bb: 10, bots: false, temporary: true });
    room.checkEmpty(0);
    expect(room.nextWake()).toBe(EMPTY_TABLE_MS);
    room.sit(p(1), 0, 1000, 1000);
    room.checkEmpty(1000);
    expect(room.closable(EMPTY_TABLE_MS * 2)).toBe(false);
    room.leave(1, 2000);
    room.checkEmpty(2000);
    // 筹码还没写回账户之前不收桌
    expect(room.closable(2000 + EMPTY_TABLE_MS)).toBe(false);
    room.ackCashout(room.s.cashouts[0].ref);
    room.checkEmpty(3000);
    expect(room.closable(3000 + EMPTY_TABLE_MS - 1)).toBe(false);
    expect(room.closable(3000 + EMPTY_TABLE_MS)).toBe(true);
    // 一个人坐着等开局时掉线，一分钟后被请离桌，桌子随后收掉
    room.sit(p(2), 0, 1000, 10_000);
    room.checkEmpty(10_000);
    room.setAway(2, true, 11_000);
    expect(room.nextWake()).toBe(71_000);
    room.tick(71_000);
    expect(room.seated()).toBe(0);
    expect(room.s.cashouts).toEqual([expect.objectContaining({ userId: 2, amount: 1000 })]);
    // 系统的桌不收
    const fixed = TableRoom.create({ no: 2, sb: 5, bb: 10, bots: false });
    fixed.checkEmpty(0);
    expect(fixed.closable(EMPTY_TABLE_MS * 10)).toBe(false);
  });

  it("holds a seat for 10 seconds while picking a buy-in", () => {
    const room = TableRoom.create({ no: 1, sb: 5, bb: 10, bots: false });
    expect(room.hold(p(1), 2, 0)).toBeNull();
    expect(room.hold(p(2), 2, 1)).toMatch(/正在买入/);
    expect(room.sit(p(2), 2, 1000, 1)).toMatch(/正在买入/);
    expect(room.view(2, 1).holds[2]).toEqual({ login: "u1", avatarUrl: null, start: 0, until: HOLD_MS, you: false });
    expect(room.view(1, 1).holds[2]!.you).toBe(true);
    // 换个座位占：原来那个放开
    expect(room.hold(p(1), 4, 2)).toBeNull();
    expect(room.view(1, 2).holds[2]).toBeNull();
    expect(room.nextWake()).toBe(2 + HOLD_MS);
    room.tick(2 + HOLD_MS);
    expect(room.view(1, 3).holds.every((h) => h === null)).toBe(true);
    // 占着的人自己能坐下，坐下后占座清掉
    room.hold(p(1), 0, 20_000);
    expect(room.sit(p(1), 0, 1000, 20_001)).toBeNull();
    expect(room.view(1, 20_001).holds[0]).toBeNull();
  });

  it("holds the seat for a busted player to buy back in", () => {
    const room = TableRoom.create({ no: 1, sb: 5, bb: 10, bots: false });
    room.sit(p(1), 0, 1000, 0);
    room.sit(p(2), 1, 1000, 0);
    room.tick(2000);
    room.s.seats[0]!.stack = 0; // 假装 1 号这手输光了
    room.s.street = "showdown";
    room.s.nextHandAt = 3000;
    room.tick(3000);
    expect(room.s.seats[0]).toBeNull();
    expect(room.view(1, 3000).holds[0]).toEqual({ login: "u1", avatarUrl: null, start: 3000, until: 3000 + HOLD_MS, you: true });
    expect(room.sit(p(3), 0, 1000, 3001)).toMatch(/正在买入/);
    expect(room.sit(p(1), 0, 800, 3002)).toBeNull();
    expect(room.s.seats[0]!.stack).toBe(800);
  });

  it("lets the winner show cards after everyone folds", () => {
    const room = TableRoom.create({ no: 1, sb: 5, bb: 10, bots: false });
    room.sit(p(1), 0, 1000, 0);
    room.sit(p(2), 1, 1000, 0);
    room.tick(2000);
    const actor = room.s.seats[room.s.toAct]!.userId;
    const other = actor === 1 ? 2 : 1;
    expect(room.show(other, 0)).toMatch(/现在不能亮牌/);
    room.act(actor, "fold", undefined, 2001);
    expect(room.s.street).toBe("showdown");
    expect(room.show(actor, 0)).toMatch(/现在不能亮牌/); // 弃牌的人不能亮
    expect(room.view(actor, 2002).seats[room.seatOf(other)]!.cards).toEqual([null, null]);
    expect(room.show(other, 1)).toBeNull();
    const seen = room.view(actor, 2003).seats[room.seatOf(other)]!;
    expect(seen.cards[0]).toBeNull();
    expect(seen.cards[1]).toEqual(room.s.seats[room.seatOf(other)]!.hole[1]);
    expect(seen.showMask).toBe(2);
    room.show(other, 2);
    expect(room.view(actor, 2004).seats[room.seatOf(other)]!.cards.every(Boolean)).toBe(true);
    // 下一手清掉
    room.tick(20_000);
    expect(room.view(actor, 20_001).seats[room.seatOf(other)]!.showMask).toBe(0);
  });

  it("applies items: time card once per turn, peek and run-out after the hand", () => {
    const room = TableRoom.create({ no: 1, sb: 5, bb: 10, bots: false });
    room.sit(p(1), 0, 1000, 0);
    room.sit(p(2), 1, 1000, 0);
    room.tick(2000);
    const actor = room.s.seats[room.s.toAct]!.userId;
    const other = actor === 1 ? 2 : 1;
    expect(room.canUseItem(other, "timecard")).toMatch(/轮到你时/);
    const deadline = room.s.deadline!;
    expect(room.useItem(actor, "timecard", 2001)).toBeNull();
    expect(room.s.deadline).toBe(deadline + 10_000);
    expect(room.view(actor, 2002).turnMs).toBe(TURN_MS + 10_000);
    expect(room.canUseItem(actor, "timecard")).toMatch(/已经加过时/);
    expect(room.canUseItem(actor, "peek")).toMatch(/一手结束后/);
    // 记下这时候剩下的牌，算出发发看应该看到什么：先烧一张、翻三张，再烧一张翻一张，再烧一张翻一张
    const deck = [...room.s.deck];
    const expected = [deck.at(-2), deck.at(-3), deck.at(-4), deck.at(-6), deck.at(-8)];
    room.act(actor, "fold", undefined, 2003);
    expect(room.s.street).toBe("showdown");
    // 弃牌的人也能偷偷看赢家没亮的牌
    expect(room.useItem(actor, "peek", 2004)).toBeNull();
    const v = room.view(actor, 2005);
    expect(v.peek![room.seatOf(other)]).toEqual(room.s.seats[room.seatOf(other)]!.hole);
    expect(room.view(other, 2005).peek).toBeNull(); // 别人看不到
    expect(room.useItem(other, "runout", 2006)).toBeNull();
    expect(room.view(other, 2007).runout).toEqual(expected);
    expect(room.view(actor, 2007).runout).toBeNull();
    // 全桌都知道谁用了什么
    expect(v.events.map((e) => e.what)).toEqual(["timecard", "peek"]);
    expect(room.view(actor, 2008).events.at(-1)).toMatchObject({ kind: "item", what: "runout" });
  });

  it("sends emotes the player owns, not too fast", () => {
    const room = TableRoom.create({ no: 1, sb: 5, bb: 10, bots: false });
    room.sit(p(1), 0, 1000, 0);
    expect(room.emote(1, "cool", ["happy"], 100)).toMatch(/还没有这个表情/);
    expect(room.emote(1, "happy", ["happy"], 100)).toBeNull();
    expect(room.emote(1, "happy", ["happy"], 200)).toMatch(/慢一点/);
    expect(room.emote(2, "happy", ["happy"], 300)).toMatch(/坐下才能/);
    expect(room.view(null, 300).events).toEqual([expect.objectContaining({ kind: "emote", seat: 0, what: "happy" })]);
    expect(room.view(null, 9000).events).toEqual([]);
  });

  it("keeps three bots playing at the bot table, never side by side", () => {
    const room = TableRoom.create({ no: 1000, sb: 1, bb: 2, bots: true });
    // 没有真人也坐着三个机器人：0、2、4 号，各带 $100
    expect(room.s.seats.map((x) => (x?.bot ? x.login : null))).toEqual([TABLE_BOTS[0], null, TABLE_BOTS[1], null, TABLE_BOTS[2], null]);
    expect(room.s.seats.filter(Boolean).map((x) => x!.stack)).toEqual([100, 100, 100]);
    room.sit(p(1), 3, 1_000_000, 0);
    expect(room.seated()).toBe(4);
    const apart = () => room.s.seats.every((x, i) => !x?.bot || !room.s.seats[(i + 1) % 6]?.bot);
    let now = 0;
    for (let n = 0; n < 4000 && room.s.handNo < 40; n++) {
      now += 500;
      // 真人总是跟注或过牌
      if (room.s.seats[room.s.toAct]?.userId === 1) room.act(1, "call", undefined, now);
      room.tick(now);
      expect(room.s.seats.every((x) => !x || x.stack >= 0)).toBe(true);
      expect(apart()).toBe(true);
      // 宿主按 nextWake 排闹钟，时刻要是整毫秒
      expect(Number.isInteger(room.nextWake() ?? 0)).toBe(true);
    }
    expect(room.s.handNo).toBe(40);
    // 真人走了机器人照样打
    room.leave(1, now);
    const hands = room.s.handNo;
    for (let n = 0; n < 400; n++) room.tick((now += 500));
    expect(room.s.handNo).toBeGreaterThan(hands);
    expect(room.vacant()).toBe(false); // 离桌的筹码还没写回账户
    room.ackCashout(room.s.cashouts[0].ref);
    expect(room.vacant()).toBe(true);
  });

  it("bot table: broke bots buy back in for $100, bots above $200 step away for a hand", () => {
    const room = TableRoom.create({ no: 1000, sb: 1, bb: 2, bots: true });
    const [a, b] = [room.s.seats[0]!, room.s.seats[2]!];
    a.stack = 1;
    b.stack = BOT_CASH_OUT_BB * 2 + 60;
    room.tick(room.s.nextHandAt!);
    expect(room.s.handNo).toBe(1);
    // 不够一个大盲算输光，补到 $100；赢到 $260 的离桌，这一手只有两个机器人打
    expect(a.stack + a.committed).toBe(BOT_BUY_IN_BB * 2);
    expect(room.s.seats[2]).toBeNull();
    let now = room.s.nextHandAt ?? 2000;
    for (let n = 0; n < 400 && room.s.handNo < 2; n++) room.tick((now += 500));
    // 打完一手回到原来的座位，带 $100
    const back = room.s.seats[2]!;
    expect(back.login).toBe(TABLE_BOTS[1]);
    expect(back.stack + back.committed).toBe(100);
  });

  it("a bot that had to sit elsewhere moves back to its own seat once it frees up", () => {
    const room = TableRoom.create({ no: 1000, sb: 1, bb: 2, bots: true });
    // 2 号座位当时被人占着，bot-002 坐到了 1 号，挨着 bot-001
    room.s.seats[1] = room.s.seats[2];
    room.s.seats[2] = null;
    room.tick(room.s.nextHandAt!);
    expect(room.s.seats.map((x) => x?.login ?? null)).toEqual([TABLE_BOTS[0], null, TABLE_BOTS[1], null, TABLE_BOTS[2], null]);
  });

  it("bot table catches up on the hands it missed while nobody was watching", () => {
    const room = TableRoom.create({ no: 1000, sb: 1, bb: 2, bots: true });
    room.tick(room.s.nextHandAt!);
    const apart = () => room.s.seats.every((x, i) => !x?.bot || !room.s.seats[(i + 1) % 6]?.bot);
    // 停了一小时：一手一手真打到现在，接着从现在往下打
    let now = 2000;
    room.pause(now);
    room.pause(now + 5000); // 重复停手不改起点
    now += 60 * 60_000;
    room.resume(now);
    expect(room.s.pausedAt).toBeNull();
    expect(room.s.handNo).toBeGreaterThan(60);
    expect(room.nextWake()!).toBeGreaterThan(now);
    expect(apart()).toBe(true);
    // 停了一整天：真打 CATCH_UP_HANDS 手，其余只加手数，计时挪到现在之后
    const before = room.s.handNo;
    room.pause(now);
    now += 24 * 3600_000;
    room.resume(now);
    expect(room.s.handNo - before).toBeGreaterThan(CATCH_UP_HANDS + 1000);
    expect(room.nextWake()!).toBeGreaterThan(now);
    expect(room.nextWake()! - now).toBeLessThan(10_000);
    expect(room.s.seats.every((x) => !x || x.stack >= 0)).toBe(true);
    // 补完接着正常打
    const h = room.s.handNo;
    for (let n = 0; n < 200 && room.s.handNo < h + 3; n++) room.tick((now = room.nextWake()!));
    expect(room.s.handNo).toBe(h + 3);
    // 没停过的桌 resume 什么都不做
    const fresh = TableRoom.create({ no: 1000, sb: 1, bb: 2, bots: true });
    fresh.resume(10_000);
    expect(fresh.s.handNo).toBe(0);
  });

  it("sends bots away when a bot table becomes a regular one", () => {
    const room = TableRoom.create({ no: 1001, sb: 1, bb: 2, bots: true });
    room.s.config.bots = false;
    room.tick(room.s.nextHandAt!);
    expect(room.seated()).toBe(0);
    expect(room.s.street).toBe("idle");
  });
});

describe("achievements", () => {
  it("finds the longest run of consecutive days", () => {
    expect(longestStreak([])).toBe(0);
    expect(longestStreak(["2026-10-01"])).toBe(1);
    expect(longestStreak(["2026-09-29", "2026-09-30", "2026-10-01", "2026-10-03", "2026-10-04"])).toBe(3);
    // 跨月、跨年
    expect(longestStreak(["2025-12-30", "2025-12-31", "2026-01-01", "2026-01-02"])).toBe(4);
  });

  it("records a big pot for the winner at the table", () => {
    const room = TableRoom.create({ no: 1, sb: 100, bb: 200, bots: false });
    room.sit({ userId: 1, login: "u1", avatarUrl: null }, 0, 20_000, 0);
    room.sit({ userId: 2, login: "u2", avatarUrl: null }, 1, 20_000, 0);
    room.tick(2000);
    const a = room.s.seats[room.s.toAct]!.userId;
    const b = a === 1 ? 2 : 1;
    room.act(a, "raise", 12_000, 2001);
    room.act(b, "call", undefined, 2002);
    for (let k = 0; k < 3; k++) {
      room.act(room.s.seats[room.s.toAct]!.userId, "check", undefined, 2003);
      room.act(room.s.seats[room.s.toAct]!.userId, "check", undefined, 2004);
    }
    expect(room.s.street).toBe("showdown");
    // 底池 $24,000：赢家（平分就两个人各 $12,000）都算大赢家
    const winners = room.s.seats.filter((x) => x && x.won >= 10_000).map((x) => x!.userId);
    expect(winners.length).toBeGreaterThan(0);
    expect(room.s.unlocks).toEqual(winners.map((userId) => ({ userId, id: "big_pot" })));
    for (const w of winners) room.ackUnlock(w, "big_pot");
    expect(room.s.unlocks).toEqual([]);
  });
});
