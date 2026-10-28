-- 个人主页 @ 后面的订阅：App 传上来的各服务账号的套餐（PUT /api/v1/accounts）。
-- 每台设备（上传令牌）一份，每次整份替换；account 是 App 端对账号（邮箱等）做的摘要，
-- 只用来在几台设备之间认出同一个账号、不重复计数，不存邮箱。
CREATE TABLE user_accounts (
  token_id INTEGER NOT NULL REFERENCES api_tokens (id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  app TEXT NOT NULL,
  account TEXT NOT NULL,
  plan TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  PRIMARY KEY (token_id, app, account)
);
CREATE INDEX user_accounts_user ON user_accounts (user_id);
