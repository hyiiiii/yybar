-- 每个用户哪些日期的用量已经上传过：每一天只收第一次，之后再传这一天整天跳过，不会重复算筹码。
CREATE TABLE usage_uploads (
  user_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  day TEXT NOT NULL,
  uploaded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  PRIMARY KEY (user_id, day)
);
-- 以前（整天覆盖时）已经有用量的日期也算上传过
INSERT OR IGNORE INTO usage_uploads (user_id, day) SELECT DISTINCT user_id, day FROM daily_usage;
