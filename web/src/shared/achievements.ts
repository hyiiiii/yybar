// 成就：达成后在成就页自己领筹码（第一次登录 $500，其他 $100），领了徽章就能戴在名字后面。
// 大部分按用量和流水算（打开网站时检查），「大赢家」「葫芦」「四条」「同花顺」由牌桌在一手结束时记下。
// 订阅的几个（Claude Pro / Max、GPT Plus / Pro）按 App 传上来的订阅算（个人主页 @ 后面那一排，免费的不算）。

import type { Text } from "./cosmetics";

export type AchievementId =
  | "first_login"
  | "streak_7"
  | "streak_30"
  | "streak_365"
  | "top_today"
  | "first_sit"
  | "first_purchase"
  | "tokens_100m"
  | "tokens_1b"
  | "tokens_10b"
  | "spend_1k"
  | "spend_10k"
  | "claude_pro"
  | "claude_max"
  | "gpt_plus"
  | "gpt_pro"
  | "big_pot"
  | "full_house"
  | "quads"
  | "straight_flush";

export interface Achievement {
  id: AchievementId;
  name: Text;
  how: Text;
  /** 奖励的筹码 */
  reward: number;
  /** 徽章上的字和配色档次 */
  badge: { label: string; tier: "bronze" | "silver" | "gold" | "clay" | "ink" | "claude" | "gpt" };
  /** 有进度条的成就：目标值（连续天数、token 数、美元） */
  target?: number;
}

export const ACHIEVEMENTS: Achievement[] = [
  { id: "first_login", name: { zh: "第一次登录！", en: "First Login!" }, how: { zh: "登录 yybar 网站。", en: "Sign in to the yybar website." }, reward: 500, badge: { label: "Hi", tier: "bronze" } },
  { id: "first_sit", name: { zh: "入座", en: "Take a Seat" }, how: { zh: "第一次在 Bar 里坐下。", en: "Sit at a table in the Bar for the first time." }, reward: 100, badge: { label: "♠", tier: "bronze" } },
  { id: "first_purchase", name: { zh: "剁手", en: "Retail Therapy" }, how: { zh: "在商场买第一件东西。", en: "Buy your first thing in the shop." }, reward: 100, badge: { label: "$", tier: "bronze" } },
  { id: "streak_7", name: { zh: "连续 7 天 work", en: "7-Day Work Streak" }, how: { zh: "连续 7 天都有用量上传。", en: "Usage uploaded 7 days in a row." }, reward: 100, badge: { label: "7", tier: "silver" }, target: 7 },
  { id: "streak_30", name: { zh: "连续 30 天 work", en: "30-Day Work Streak" }, how: { zh: "连续 30 天都有用量上传。", en: "Usage uploaded 30 days in a row." }, reward: 100, badge: { label: "30", tier: "gold" }, target: 30 },
  { id: "streak_365", name: { zh: "连续 365 天 work", en: "365-Day Work Streak" }, how: { zh: "整整一年，一天没歇。", en: "A full year without a day off." }, reward: 100, badge: { label: "365", tier: "clay" }, target: 365 },
  { id: "top_today", name: { zh: "今天 token 第一！", en: "Today's #1!" }, how: { zh: "某一天烧的 token 是全站第一。", en: "Burn the most tokens on the site in a day." }, reward: 100, badge: { label: "#1", tier: "gold" } },
  { id: "tokens_100m", name: { zh: "一亿 token", en: "100M Tokens" }, how: { zh: "累计烧掉 1 亿 token。", en: "Burn 100 million tokens in total." }, reward: 100, badge: { label: "100M", tier: "silver" }, target: 100_000_000 },
  { id: "tokens_1b", name: { zh: "十亿 token", en: "1B Tokens" }, how: { zh: "累计烧掉 10 亿 token。", en: "Burn 1 billion tokens in total." }, reward: 100, badge: { label: "1B", tier: "gold" }, target: 1_000_000_000 },
  { id: "tokens_10b", name: { zh: "百亿 token", en: "10B Tokens" }, how: { zh: "累计烧掉 100 亿 token。", en: "Burn 10 billion tokens in total." }, reward: 100, badge: { label: "10B", tier: "ink" }, target: 10_000_000_000 },
  { id: "spend_1k", name: { zh: "千刀俱乐部", en: "$1K Club" }, how: { zh: "累计 AI 花费到 $1,000。", en: "Reach $1,000 in total AI spend." }, reward: 100, badge: { label: "$1K", tier: "ink" }, target: 1_000 },
  { id: "spend_10k", name: { zh: "万刀俱乐部", en: "$10K Club" }, how: { zh: "累计 AI 花费到 $10,000。", en: "Reach $10,000 in total AI spend." }, reward: 100, badge: { label: "$10K", tier: "gold" }, target: 10_000 },
  { id: "claude_pro", name: { zh: "Claude Pro", en: "Claude Pro" }, how: { zh: "订阅 Claude Pro（yybar App 里有 Claude Pro 账号）。", en: "Subscribe to Claude Pro (a Claude Pro account in the yybar app)." }, reward: 100, badge: { label: "Pro", tier: "claude" } },
  { id: "claude_max", name: { zh: "Claude Max", en: "Claude Max" }, how: { zh: "订阅 Claude Max 或 Ultra。", en: "Subscribe to Claude Max or Ultra." }, reward: 100, badge: { label: "Max", tier: "claude" } },
  { id: "gpt_plus", name: { zh: "GPT Plus", en: "GPT Plus" }, how: { zh: "订阅 ChatGPT Plus（yybar App 里有 Plus 的 Codex 账号）。", en: "Subscribe to ChatGPT Plus (a Plus Codex account in the yybar app)." }, reward: 100, badge: { label: "Plus", tier: "gpt" } },
  { id: "gpt_pro", name: { zh: "GPT Pro", en: "GPT Pro" }, how: { zh: "订阅 ChatGPT Pro（Pro Lite / Pro / Pro Max 都算）。", en: "Subscribe to ChatGPT Pro (Pro Lite, Pro or Pro Max)." }, reward: 100, badge: { label: "Pro", tier: "gpt" } },
  { id: "big_pot", name: { zh: "大赢家", en: "Big Pot" }, how: { zh: "一手赢下 $10,000 以上。", en: "Win $10,000 or more in one hand." }, reward: 100, badge: { label: "BIG", tier: "clay" } },
  { id: "full_house", name: { zh: "葫芦！", en: "Full House!" }, how: { zh: "摊牌时亮出葫芦。", en: "Show down a full house." }, reward: 100, badge: { label: "FH", tier: "silver" } },
  { id: "quads", name: { zh: "四条！", en: "Quads!" }, how: { zh: "摊牌时亮出四条。", en: "Show down four of a kind." }, reward: 100, badge: { label: "4K", tier: "gold" } },
  { id: "straight_flush", name: { zh: "同花顺！", en: "Straight Flush!" }, how: { zh: "摊牌时亮出同花顺（皇家同花顺也算）。", en: "Show down a straight flush (royal counts)." }, reward: 100, badge: { label: "SF", tier: "ink" } },
];

/** 一手赢这么多算「大赢家」 */
export const BIG_POT = 10_000;

export function findAchievement(id: string): Achievement | undefined {
  return ACHIEVEMENTS.find((a) => a.id === id);
}

/** 一串日期（YYYY-MM-DD，升序、不重复）里最长的连续天数 */
export function longestStreak(days: string[]): number {
  let best = 0, run = 0, prev = 0;
  for (const d of days) {
    const t = Date.parse(`${d}T00:00:00Z`) / 86_400_000;
    run = t - prev === 1 ? run + 1 : 1;
    prev = t;
    best = Math.max(best, run);
  }
  return best;
}

/** 最多同时戴几个徽章 */
export const MAX_BADGES = 3;

/** users.badges 存的 JSON 数组读出来；坏数据当没戴 */
export function parseBadges(raw: string | null | undefined): string[] {
  try {
    const v = JSON.parse(raw ?? "[]");
    return Array.isArray(v) ? v.filter((x) => typeof x === "string").slice(0, MAX_BADGES) : [];
  } catch {
    return [];
  }
}
