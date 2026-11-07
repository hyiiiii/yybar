-- 上传标记记下那一天那个服务传了多少（token 总数，Gemini 是回答次数）：以后 App 那边这一天的量变多了
-- （比如新加了一个 Codex 目录，找到了另一个账号的会话），再传一次就整份换成新的，筹码跟着重算；一样多或更少照旧跳过。
ALTER TABLE usage_uploads ADD COLUMN total INTEGER NOT NULL DEFAULT 0;
UPDATE usage_uploads SET total = COALESCE((
  SELECT SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens + answers)
  FROM daily_usage d WHERE d.user_id = usage_uploads.user_id AND d.day = usage_uploads.day AND d.app = usage_uploads.app
), 0);
