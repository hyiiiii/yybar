// 练习桌的机器人：只看自己的牌和公共牌，按粗略牌力 + 一点随机做决定。

import { bestScore, category, type Card } from "./cards";
import type { RoomState } from "./room";
import type { Legal } from "./types";

/** 翻牌前起手牌 0～1 的粗略强度。 */
function preflopStrength([a, b]: Card[]): number {
  const hi = Math.max(a.r, b.r), lo = Math.min(a.r, b.r);
  let v = (hi + lo) / 28;
  if (a.r === b.r) v = 0.55 + (a.r / 14) * 0.45;
  if (a.s === b.s) v += 0.06;
  if (hi - lo === 1) v += 0.04;
  return Math.min(1, v);
}

/** 翻牌后：自己成的牌比公共牌本身强多少。 */
function postflopStrength(hole: Card[], board: Card[]): number {
  const mine = category(bestScore([...hole, ...board]));
  const table = board.length >= 5 ? category(bestScore(board)) : 0;
  const gain = mine - table;
  if (gain <= 0) return 0.15 + Math.max(...hole.map((c) => c.r)) / 60;
  return Math.min(1, 0.35 + mine * 0.13 + gain * 0.05);
}

export function botDecide(s: RoomState, i: number, legal: Legal): { action: "fold" | "check" | "call" | "raise"; amount?: number } {
  const seat = s.seats[i]!;
  const strength = s.board.length ? postflopStrength(seat.hole, s.board) : preflopStrength(seat.hole);
  const pot = s.seats.reduce((sum, x) => sum + (x?.committed ?? 0), 0);
  const r = Math.random();
  const priceOf = legal.toCall / Math.max(1, pot + legal.toCall);

  const raise = (fraction: number) => {
    const target = s.currentBet + Math.max(s.config.bb, Math.round((pot * fraction) / s.config.sb) * s.config.sb);
    const amount = Math.min(legal.maxRaiseTo, Math.max(legal.minRaiseTo, target));
    return { action: "raise" as const, amount };
  };

  if (legal.canRaise && (strength > 0.78 || (strength > 0.6 && r < 0.35) || r < 0.06)) {
    return raise(strength > 0.9 ? 1 : 0.6);
  }
  if (legal.canCheck) return { action: "check" };
  if (strength > priceOf + 0.25 || (legal.toCall <= s.config.bb && r < 0.6)) return { action: "call" };
  return { action: "fold" };
}
