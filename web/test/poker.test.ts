import { describe, expect, it } from "vitest";
import { bestScore, handName, type Card } from "../src/shared/poker/cards";
import { buildPots, EMPTY_TABLE_MS, HOLD_MS, TableRoom, TURN_MS, type RoomState } from "../src/shared/poker/room";

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
    expect(room.act(uid(other), "raise", 20, 10_003)).toBeNull();
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
    expect(room.s.street).toBe("showdown");
    expect(total(room)).toBe(1100);
    // 公共牌 Qs Jd 3c 4s 6h，1 号座的 AA 主池边池都赢
    expect(room.s.seats[1]!.stack).toBe(1100);
    expect(room.s.seats[0]!.stack).toBe(0);
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
    expect(room.view(2, 1).holds[2]).toEqual({ login: "u1", start: 0, until: HOLD_MS, you: false });
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
    expect(room.view(1, 3000).holds[0]).toEqual({ login: "u1", start: 3000, until: 3000 + HOLD_MS, you: true });
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

  it("bots keep a practice table going and chips stay conserved", () => {
    const room = TableRoom.create({ no: 1, sb: 5, bb: 10, bots: true });
    room.sit(p(1), 3, 1_000_000, 0);
    expect(room.seated()).toBe(4);
    let now = 0;
    for (let n = 0; n < 3000; n++) {
      now += 500;
      // 真人总是跟注或过牌
      if (room.s.seats[room.s.toAct]?.userId === 1) room.act(1, "call", undefined, now);
      room.tick(now);
      expect(room.s.seats.every((x) => !x || x.stack >= 0)).toBe(true);
      if (room.s.street === "idle" && room.s.handNo > 0) break;
    }
    expect(room.s.handNo).toBeGreaterThan(10);
  });
});
