import { describe, expect, it } from "vitest";
import { bestScore, handName, type Card } from "../src/shared/poker/cards";
import { buildPots, TableRoom, type RoomState } from "../src/shared/poker/room";

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
    room.tick(2000 + 24_000);
    expect(room.s.toAct).toBe(first);
    room.tick(2000 + 25_000);
    // 两人桌翻牌前庄家要补小盲，超时就是弃牌
    expect(room.s.seats[first]!.folded).toBe(true);
    expect(room.s.seats[first]!.timeouts).toBe(1);
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
