-- 2026-11 的新模型价格（和 App 内置价格表 Core/Usage/Pricing.swift 一致）：
-- Claude Fable 5.2，GPT-6.2 Astra / Sol，GPT-6.1 Terra（OpenAI 官方价格页 2026-11-19 查；cache_write 用 30 分钟写入价）。
-- 以前表里没有这几个模型，上传的这几个模型的花费记的是 0；加价格后按新价重算这几行，筹码跟着补上。
INSERT OR REPLACE INTO model_prices (model, vendor, input, output, cache_read, cache_write, billed) VALUES
  ('claude-fable-5-2', 'anthropic', 8, 40, 0.20, 10, 0),
  ('gpt-6.2-astra', 'openai', 8, 40, 0.40, 10, 0),
  ('gpt-6.2-sol', 'openai', 2, 10, 0.10, 2.5, 0),
  ('gpt-6.1-terra', 'openai', 1, 5, 0.05, 1.25, 0);

UPDATE daily_usage SET cost_micro = (
  SELECT CAST(ROUND(daily_usage.input_tokens * p.input + daily_usage.output_tokens * p.output + daily_usage.cache_read_tokens * p.cache_read + daily_usage.cache_creation_tokens * p.cache_write) AS INTEGER)
  FROM model_prices p
  WHERE p.model = LOWER(CASE WHEN daily_usage.model LIKE 'openai/%' THEN SUBSTR(daily_usage.model, 8) ELSE daily_usage.model END)
)
WHERE app NOT IN ('grokBot', 'gemini')
  AND LOWER(CASE WHEN model LIKE 'openai/%' THEN SUBSTR(model, 8) ELSE model END)
      IN ('claude-fable-5-2', 'gpt-6.2-astra', 'gpt-6.2-sol', 'gpt-6.1-terra');
