// 模型价格：花费由服务端按自己的价格表（D1 的 model_prices）和上传的 token 数现算，不用 App 报上来的花费——
// App 里可以自己改模型价格，照单全收的话改个离谱的价就能刷筹码。价格表的初始值和 App 内置的官方价格一致
// （迁移 0012_model_prices.sql），之后要改价直接改这张表，网页上「总花费」旁边的问号能看到整张表。

/** 价格表的一行：美元 / 百万 token。model 以 * 结尾是前缀，例如 grok-* 是所有 Grok 模型 */
export interface ModelPrice {
  model: string;
  /** 显示时按厂商分组 */
  vendor: "anthropic" | "openai" | "google" | "xai";
  input: number;
  output: number;
  cache_read: number;
  cache_write: number;
  /**
   * 1 = 日志里记的是服务商的实际扣费（Grok）：收 App 报的花费，但不超过按这一行的价格算出来的数。
   * 0 = 只按价格算，App 报的花费不管。
   */
  billed: number;
}

/** 用来算花费的一条用量（字段和上传的一样） */
export interface PricedUsage {
  app: string;
  model: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
  /** App 报上来的花费（微美元） */
  clientCostMicro: number;
}

/** Grok Bot 只有合计 token、Gemini 只有回答次数，都算不出花费 */
export const UNPRICED_APPS = ["grokBot", "gemini"];

/** 查价用的模型名：小写，去掉 openai/、xai/ 前缀，@ 后面的版本和末尾的日期（和 App 的 Pricing.normalize 一样） */
export function normalizeModel(model: string): string {
  return model
    .trim()
    .toLowerCase()
    .replace(/^(openai|xai)\//, "")
    .replace(/@.*$/, "")
    .replace(/-\d{4}-\d{2}-\d{2}$|-\d{8}$/, "");
}

/** 找这个模型的价格：先找完全一样的，再找最长的前缀（grok-*）；找不到返回 undefined */
export function findPrice(model: string, prices: ModelPrice[]): ModelPrice | undefined {
  const m = normalizeModel(model);
  return (
    prices.find((p) => p.model === m) ??
    prices
      .filter((p) => p.model.endsWith("*") && m.startsWith(p.model.slice(0, -1)))
      .sort((a, b) => b.model.length - a.model.length)[0]
  );
}

/** 按价格表算一条用量的花费（微美元）：token 数 × 美元 / 百万 token 正好是微美元。找不到价格的模型是 0 */
export function serverCostMicro(u: PricedUsage, prices: ModelPrice[]): number {
  if (UNPRICED_APPS.includes(u.app)) return 0;
  const p = findPrice(u.model, prices);
  if (!p) return 0;
  const listed = Math.round(u.inputTokens * p.input + u.outputTokens * p.output + u.cacheReadTokens * p.cache_read + u.cacheCreationTokens * p.cache_write);
  return p.billed ? Math.min(u.clientCostMicro, listed) : listed;
}
