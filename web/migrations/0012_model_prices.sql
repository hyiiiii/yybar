-- 模型价格表放到服务端：上传的花费按这里的价格和 token 数现算（src/shared/pricing.ts），不再用 App 报上来的——
-- App 里可以自己改模型价格，照单全收的话改个离谱的价就能刷筹码。
-- 单位：美元 / 百万 token（token 数 × 单价正好是微美元）。model 是查价用的模型名（小写，去掉 openai/、xai/ 前缀和日期），
-- 以 * 结尾的是前缀。billed = 1 的（Grok）日志里记的是 xAI 的实际扣费：收 App 报的花费，但不超过按这一行算出来的数。
-- 初始价格和 App 内置的价格表（Core/Usage/Pricing.swift，2026-10 的官方价）一致；Grok 的上限用 Grok 4 的公开价。
CREATE TABLE model_prices (
  model TEXT PRIMARY KEY,
  vendor TEXT NOT NULL,
  input REAL NOT NULL,
  output REAL NOT NULL,
  cache_read REAL NOT NULL,
  cache_write REAL NOT NULL,
  billed INTEGER NOT NULL DEFAULT 0
);

INSERT INTO model_prices (model, vendor, input, output, cache_read, cache_write, billed) VALUES
  ('claude-fable-5-1', 'anthropic', 10, 50, 0.25, 12.50, 0),
  ('claude-fable-5', 'anthropic', 10, 50, 1.00, 12.50, 0),
  ('claude-opus-5-5', 'anthropic', 4, 20, 0.20, 5, 0),
  ('claude-opus-5', 'anthropic', 5, 25, 0.50, 6.25, 0),
  ('claude-opus-4-8', 'anthropic', 5, 25, 0.50, 6.25, 0),
  ('claude-opus-4-7', 'anthropic', 5, 25, 0.50, 6.25, 0),
  ('claude-opus-4-6', 'anthropic', 5, 25, 0.50, 6.25, 0),
  ('claude-opus-4-5', 'anthropic', 5, 25, 0.50, 6.25, 0),
  ('claude-opus-4-1', 'anthropic', 15, 75, 1.50, 18.75, 0),
  ('claude-opus-4', 'anthropic', 15, 75, 1.50, 18.75, 0),
  ('claude-sonnet-5-5', 'anthropic', 2, 10, 0.10, 2.50, 0),
  ('claude-sonnet-5', 'anthropic', 2, 10, 0.20, 2.50, 0),
  ('claude-sonnet-4-7', 'anthropic', 3, 15, 0.30, 3.75, 0),
  ('claude-sonnet-4-6', 'anthropic', 3, 15, 0.30, 3.75, 0),
  ('claude-sonnet-4-5', 'anthropic', 3, 15, 0.30, 3.75, 0),
  ('claude-sonnet-4', 'anthropic', 3, 15, 0.30, 3.75, 0),
  ('claude-haiku-4-5', 'anthropic', 1, 5, 0.10, 1.25, 0),
  ('claude-haiku-4', 'anthropic', 0.8, 4, 0.08, 1.0, 0),
  ('gpt-5', 'openai', 1.25, 10, 0.125, 0, 0),
  ('gpt-5-mini', 'openai', 0.25, 2, 0.025, 0, 0),
  ('gpt-5-nano', 'openai', 0.05, 0.40, 0.005, 0, 0),
  ('gpt-5-codex', 'openai', 1.25, 10, 0.125, 0, 0),
  ('gpt-5.1', 'openai', 1.25, 10, 0.125, 0, 0),
  ('gpt-5.1-codex', 'openai', 1.25, 10, 0.125, 0, 0),
  ('gpt-5.2', 'openai', 1.25, 10, 0.125, 0, 0),
  ('gpt-5.3', 'openai', 1.25, 10, 0.125, 0, 0),
  ('gpt-5.4', 'openai', 2.50, 15, 0.25, 0, 0),
  ('gpt-5.4-codex', 'openai', 2.50, 15, 0.25, 0, 0),
  ('gpt-5.5', 'openai', 5, 30, 0.50, 0, 0),
  ('gpt-5.5-codex', 'openai', 5, 30, 0.50, 0, 0),
  ('gpt-5.5-pro', 'openai', 5, 30, 0.50, 0, 0),
  ('gpt-5.6', 'openai', 4, 20, 0.40, 5, 0),
  ('gpt-5.6-sol', 'openai', 4, 20, 0.40, 5, 0),
  ('gpt-5.6-terra', 'openai', 2, 12, 0.20, 2.5, 0),
  ('gpt-5.6-luna', 'openai', 0.2, 1.2, 0.02, 0.25, 0),
  ('gpt-6-astra', 'openai', 10, 50, 1, 12.5, 0),
  ('gpt-6.1-sol', 'openai', 2, 10, 0.10, 2.5, 0),
  ('gpt-6-sol', 'openai', 2, 10, 0.20, 2.5, 0),
  ('gpt-6-luna', 'openai', 0.10, 0.50, 0.01, 0.125, 0),
  ('gemini-4-argon', 'google', 2, 10, 0.10, 0, 0),
  ('gemini-3.8-flash', 'google', 0.75, 3.75, 0.075, 0, 0),
  ('gemini-3.6-flash', 'google', 0.75, 3.75, 0.075, 0, 0),
  ('gemini-3.5-flash-lite', 'google', 0.30, 2.50, 0.03, 0, 0),
  ('gemini-3.1-pro-preview', 'google', 2, 12, 0.20, 0, 0),
  ('gemini-3.1-pro', 'google', 2, 12, 0.20, 0, 0),
  ('gemini-3.1-flash-lite', 'google', 0.25, 1.50, 0.025, 0, 0),
  ('gemini-3-flash-preview', 'google', 0.50, 3, 0.05, 0, 0),
  ('gemini-3-flash', 'google', 0.50, 3, 0.05, 0, 0),
  ('gemini-2.5-pro', 'google', 1.25, 10, 0.125, 0, 0),
  ('gemini-2.5-flash', 'google', 0.30, 2.50, 0.03, 0, 0),
  ('codex-mini-latest', 'openai', 1.50, 6, 0.375, 0, 0),
  ('grok-*', 'xai', 3, 15, 0.75, 0, 1);

-- App 报上来的花费另存一列，只作对照和 Grok 封顶用；cost_micro 改成按上面的价格重算
ALTER TABLE daily_usage ADD COLUMN client_cost_micro INTEGER NOT NULL DEFAULT 0;
UPDATE daily_usage SET client_cost_micro = cost_micro;
UPDATE daily_usage SET cost_micro = CASE
  WHEN app IN ('grokBot', 'gemini') THEN 0
  ELSE COALESCE((
    SELECT CASE WHEN p.billed = 1 THEN MIN(daily_usage.client_cost_micro, CAST(ROUND(daily_usage.input_tokens * p.input + daily_usage.output_tokens * p.output + daily_usage.cache_read_tokens * p.cache_read + daily_usage.cache_creation_tokens * p.cache_write) AS INTEGER)) ELSE CAST(ROUND(daily_usage.input_tokens * p.input + daily_usage.output_tokens * p.output + daily_usage.cache_read_tokens * p.cache_read + daily_usage.cache_creation_tokens * p.cache_write) AS INTEGER) END
    FROM model_prices p
    WHERE p.model = LOWER(CASE WHEN daily_usage.model LIKE 'openai/%' THEN SUBSTR(daily_usage.model, 8) WHEN daily_usage.model LIKE 'xai/%' THEN SUBSTR(daily_usage.model, 5) ELSE daily_usage.model END)
       OR (p.model LIKE '%*' AND LOWER(CASE WHEN daily_usage.model LIKE 'openai/%' THEN SUBSTR(daily_usage.model, 8) WHEN daily_usage.model LIKE 'xai/%' THEN SUBSTR(daily_usage.model, 5) ELSE daily_usage.model END) LIKE REPLACE(p.model, '*', '%'))
    ORDER BY p.model LIKE '%*', LENGTH(p.model) DESC
    LIMIT 1
  ), 0)
END;
