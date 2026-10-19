-- 成就：解锁时记一行，同时往 points_ledger 记奖励（reason = 'achievement'，ref = 'ach:<用户>:<成就>'，不会重复发）
CREATE TABLE user_achievements (
  user_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  id TEXT NOT NULL,
  unlocked_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  PRIMARY KEY (user_id, id)
);

-- 戴在名字后面的徽章（某个已解锁成就的 id），没戴是 NULL
ALTER TABLE users ADD COLUMN badge TEXT;
