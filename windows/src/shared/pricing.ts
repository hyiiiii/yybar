// 价格相关的小工具（与后台 `usage/pricing.rs` 同一套规则）。

import type { ModelPrice, StateSnapshot, UsageApp } from "./types";

/** 归一化模型名：去 `openai/` 前缀；剥 `@日期`、`-YYYYMMDD` / `-YYYY-MM-DD` 后缀；小写。 */
export function normalizeModel(model: string): string {
  let m = model.startsWith("openai/") ? model.slice(7) : model;
  const at = m.indexOf("@");
  if (at >= 0) m = m.slice(0, at);
  m = m.replace(/-\d{4}-\d{2}-\d{2}$/, "");
  if (m === model || !/-\d{4}-\d{2}-\d{2}$/.test(model)) m = m.replace(/-\d{8}$/, "");
  return m.toLowerCase();
}

export function priceFor(state: StateSnapshot, key: string): ModelPrice | undefined {
  return state.prices.custom[key] ?? state.prices.builtin[key];
}

/** 费用能不能显示：Grok 的费用来自日志算已知；其他服务有价格或有正数费用才算。 */
export function hasDisplayableCost(state: StateSnapshot, app: UsageApp, model: string, cost: number): boolean {
  return app === "grok" || cost > 0 || priceFor(state, normalizeModel(model)) != null;
}

/** 费用按价格表算的服务（模型价格页列出）。Grok 费用来自日志，不列。 */
export const pricedApps: UsageApp[] = ["codex", "claude", "agy"];
