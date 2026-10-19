// 中英切换：左上角 yybar 旁边的按钮。界面文字用 t(中文, English) 就地写两份；
// 服务端发来的中文（动作、牌型、报错、机器人名字）在这里翻成英文。
import { useCallback, useSyncExternalStore } from "react";
import type { Text } from "../shared/cosmetics";

export type Lang = "zh" | "en";

const KEY = "yyb:lang";
const listeners = new Set<() => void>();

function load(): Lang {
  try {
    const v = localStorage.getItem(KEY);
    if (v === "zh" || v === "en") return v;
  } catch {
    // 预览、隐私模式下可能读不了
  }
  return "zh";
}

let current: Lang = load();
document.documentElement.lang = current === "en" ? "en" : "zh-CN";

export function setLang(lang: Lang) {
  current = lang;
  document.documentElement.lang = lang === "en" ? "en" : "zh-CN";
  try {
    localStorage.setItem(KEY, lang);
  } catch {
    // 存不了就只在这次打开里生效
  }
  listeners.forEach((fn) => fn());
}

export function useLang(): Lang {
  return useSyncExternalStore(
    (fn) => (listeners.add(fn), () => listeners.delete(fn)),
    () => current,
  );
}

/** t("弃牌", "Fold")：按当前语言取一份 */
export function useT() {
  const lang = useLang();
  return useCallback((zh: string, en: string) => (lang === "en" ? en : zh), [lang]);
}

export const pick = (text: Text, lang: Lang) => text[lang];

const EXACT: Record<string, string> = {
  // 动作
  小盲: "Small blind",
  大盲: "Big blind",
  弃牌: "Fold",
  过牌: "Check",
  跟注: "Call",
  全下: "All-in",
  // 牌型
  高牌: "High card",
  一对: "One pair",
  两对: "Two pair",
  三条: "Three of a kind",
  顺子: "Straight",
  同花: "Flush",
  葫芦: "Full house",
  四条: "Four of a kind",
  同花顺: "Straight flush",
  皇家同花顺: "Royal flush",
  // 机器人
  "bot-紧凶": "bot-Nit",
  "bot-松鱼": "bot-Fish",
  "bot-跟注站": "bot-Station",
  "bot-诈唬王": "bot-Bluffer",
  "bot-老实人": "bot-Honest",
  // 报错
  没有这个座位: "No such seat",
  你已经在这张桌上了: "You're already at this table",
  这个座位有人了: "That seat is taken",
  这个座位有人正在买入: "Someone is buying in at that seat",
  你没有坐在这张桌上: "You're not seated here",
  还没轮到你: "It's not your turn",
  现在不能过牌: "You can't check now",
  现在不能加注: "You can't raise now",
  现在不能亮牌: "You can't show now",
  看不懂的操作: "Unknown action",
  先登录再入座: "Sign in to take a seat",
  "筹码不够，刚才可能在别的桌用掉了": "Not enough chips — maybe spent at another table",
  筹码不够: "Not enough chips",
  没有这张桌: "No such table",
  没有这档盲注: "No such blind level",
  没有这件商品: "No such item",
  还没买这一款: "You don't own that yet",
  "和牌桌的连接断了，正在重连…": "Lost connection to the table, reconnecting…",
  轮到你时才能用加时卡: "Time Bank only works on your turn",
  这次行动已经加过时了: "Already extended this turn",
  一手结束后才能偷偷看: "Sneak Peek works after the hand",
  一手结束后才能发发看: "Run It Out works after the hand",
  这手已经看过了: "Already used this hand",
  没有没亮出来的牌: "No hidden cards to see",
  公共牌已经发完了: "The board is already complete",
  没有这个道具: "No such item",
  "这个道具用完了，去商场买一些": "You're out of that item — get more in the shop",
  坐下才能发表情: "Sit down to send emotes",
  还没有这个表情: "You don't own that emote",
  慢一点: "Slow down",
  未登录: "Not signed in",
  还没解锁这个成就: "You haven't unlocked that yet",
};

const PATTERNS: [RegExp, string][] = [
  [/^下注 (.+)$/, "Bet $1"],
  [/^加注到 (.+)$/, "Raise to $1"],
  [/^筹码不够：这张桌最少要带 (.+) 入座$/, "Not enough chips: this table needs at least $1"],
  [/^带入要在 (.+) 到 (.+) 之间$/, "Buy-in must be between $1 and $2"],
  [/^加注要在 (.+) 到 (.+) 之间$/, "Raise must be between $1 and $2"],
  [/^你还坐在 (.+)，离桌后才能开新桌$/, "You're still seated at $1 — leave before opening a new table"],
  [/^每人最多开 (\d+) 张桌$/, "You can open at most $1 tables"],
  [/^请求失败（(\d+)）$/, "Request failed ($1)"],
];

/** 服务端发来的中文翻成当前语言 */
export function tr(text: string, lang: Lang): string {
  if (lang === "zh") return text;
  if (EXACT[text]) return EXACT[text];
  for (const [re, en] of PATTERNS) if (re.test(text)) return text.replace(re, en);
  return text;
}

/** 名字：机器人的中文名翻一下，真人原样 */
export const nameOf = (login: string, lang: Lang) => (login.startsWith("bot-") ? tr(login, lang) : login);
