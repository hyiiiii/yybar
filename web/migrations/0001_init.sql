-- 用户：一律通过 GitHub 登录创建
CREATE TABLE users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  github_id INTEGER NOT NULL UNIQUE,
  login TEXT NOT NULL,
  name TEXT,
  avatar_url TEXT,
  show_on_board INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX users_login ON users (login COLLATE NOCASE);

-- 网页登录会话；id 存 cookie 值的 SHA-256
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  expires_at TEXT NOT NULL
);
CREATE INDEX sessions_user ON sessions (user_id);

-- App 上传用的令牌；只存 SHA-256
CREATE TABLE api_tokens (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  label TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  last_used_at TEXT,
  revoked_at TEXT
);
CREATE INDEX api_tokens_user ON api_tokens (user_id);

-- 每日用量：(用户, 本地日期, 服务, 模型) 一行；上传时整天覆盖
-- 花费以微美元（1e-6 USD）整数存储，避免浮点误差
CREATE TABLE daily_usage (
  user_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  day TEXT NOT NULL,
  app TEXT NOT NULL,
  model TEXT NOT NULL,
  input_tokens INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL,
  cache_read_tokens INTEGER NOT NULL,
  cache_creation_tokens INTEGER NOT NULL,
  cost_micro INTEGER NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  PRIMARY KEY (user_id, day, app, model)
);
CREATE INDEX daily_usage_day ON daily_usage (day);

-- 积分流水：花费换来的积分按用量实时计算，这里只记其他变动（以后德州的输赢）
CREATE TABLE points_ledger (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  delta INTEGER NOT NULL,
  reason TEXT NOT NULL,
  ref TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX points_ledger_user ON points_ledger (user_id);
