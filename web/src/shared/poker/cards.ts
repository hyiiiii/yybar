// 牌、洗牌和比牌。前后端共用：服务端用来发牌结算，预览版在浏览器里跑同一套逻辑。

/** r：2…14（14 = A）；s：0 GPT、1 Claude、2 Gemini、3 Grok（对应 ♠♥♦♣）。 */
export interface Card {
  r: number;
  s: number;
}

export function newDeck(): Card[] {
  const deck: Card[] = [];
  for (let s = 0; s < 4; s++) for (let r = 2; r <= 14; r++) deck.push({ r, s });
  return deck;
}

/** 均匀随机数 [0, n)，用 crypto 取随机，拒绝采样避免取模偏差。 */
function randomInt(n: number): number {
  const limit = Math.floor(0x1_0000_0000 / n) * n;
  const buf = new Uint32Array(1);
  for (;;) {
    crypto.getRandomValues(buf);
    if (buf[0] < limit) return buf[0] % n;
  }
}

export function shuffle<T>(items: T[], rand: (n: number) => number = randomInt): T[] {
  const a = items.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = rand(i + 1);
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

export const HAND_NAMES = ["高牌", "一对", "两对", "三条", "顺子", "同花", "葫芦", "四条", "同花顺"];

/**
 * 5 张牌的牌力：牌型 × 15^5 + 依次比较的点数。数值越大越强，相等即平分。
 */
function score5(cards: Card[]): number {
  const ranks = cards.map((c) => c.r).sort((a, b) => b - a);
  const flush = cards.every((c) => c.s === cards[0].s);
  const uniq = [...new Set(ranks)];
  let straightHigh = 0;
  if (uniq.length === 5) {
    if (ranks[0] - ranks[4] === 4) straightHigh = ranks[0];
    else if (ranks[0] === 14 && ranks[1] === 5) straightHigh = 5; // A2345
  }
  const counts = new Map<number, number>();
  for (const r of ranks) counts.set(r, (counts.get(r) ?? 0) + 1);
  // 先按张数、再按点数排序，例如葫芦 KKK22 → [K, 2]
  const groups = [...counts.entries()].sort((a, b) => b[1] - a[1] || b[0] - a[0]);
  const kickers = groups.map((g) => g[0]);
  const shape = groups.map((g) => g[1]).join("");

  let cat: number;
  let tie: number[];
  if (straightHigh && flush) (cat = 8), (tie = [straightHigh]);
  else if (shape === "41") (cat = 7), (tie = kickers);
  else if (shape === "32") (cat = 6), (tie = kickers);
  else if (flush) (cat = 5), (tie = ranks);
  else if (straightHigh) (cat = 4), (tie = [straightHigh]);
  else if (shape === "311") (cat = 3), (tie = kickers);
  else if (shape === "221") (cat = 2), (tie = kickers);
  else if (shape === "2111") (cat = 1), (tie = kickers);
  else (cat = 0), (tie = ranks);

  let v = cat;
  for (let i = 0; i < 5; i++) v = v * 15 + (tie[i] ?? 0);
  return v;
}

export function category(score: number): number {
  return Math.floor(score / 15 ** 5);
}

/** 5～7 张牌里挑最好的 5 张。 */
export function bestScore(cards: Card[]): number {
  if (cards.length <= 5) return score5(cards);
  let best = 0;
  const pick: Card[] = [];
  const walk = (from: number) => {
    if (pick.length === 5) {
      best = Math.max(best, score5(pick));
      return;
    }
    for (let i = from; i <= cards.length - (5 - pick.length); i++) {
      pick.push(cards[i]);
      walk(i + 1);
      pick.pop();
    }
  };
  walk(0);
  return best;
}

export function handName(score: number): string {
  const cat = category(score);
  if (cat === 8 && Math.floor(score / 15 ** 4) % 15 === 14) return "皇家同花顺";
  return HAND_NAMES[cat];
}
