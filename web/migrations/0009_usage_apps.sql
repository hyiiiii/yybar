-- 用量多三个服务：Grok Bot、Gemini、Antigravity（和 yybar App 的 UsageApp 一致）。
-- Gemini 没有 token 和花费，只记回答次数。
ALTER TABLE daily_usage ADD COLUMN answers INTEGER NOT NULL DEFAULT 0;

-- 上传标记从「每天」改成「每天的每个服务」：以后 App 新支持了某个服务，已经传过的日子还能把它补上，
-- 每个服务每天仍只算一次。以前标过的日子当作 Codex / Claude / Grok 都传过了（那时只收这三家）。
CREATE TABLE usage_uploads_v2 (
  user_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  day TEXT NOT NULL,
  app TEXT NOT NULL,
  uploaded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  PRIMARY KEY (user_id, day, app)
);
INSERT OR IGNORE INTO usage_uploads_v2 (user_id, day, app, uploaded_at)
  SELECT u.user_id, u.day, a.app, u.uploaded_at
  FROM usage_uploads u, (SELECT 'codex' AS app UNION ALL SELECT 'claude' UNION ALL SELECT 'grok') a;
DROP TABLE usage_uploads;
ALTER TABLE usage_uploads_v2 RENAME TO usage_uploads;
