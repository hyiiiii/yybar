-- 成就：解锁时记一行，同时往 points_ledger 记奖励（reason = 'achievement'，ref = 'ach:<用户>:<成就>'，不会重复发）
CREATE TABLE user_achievements (
  user_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  id TEXT NOT NULL,
  unlocked_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  PRIMARY KEY (user_id, id)
);

-- 戴在名字后面的成就徽章：已解锁成就 id 的 JSON 数组，最多 3 个
ALTER TABLE users ADD COLUMN badges TEXT NOT NULL DEFAULT '[]';

-- 德州统计：牌桌每打完一手往这里加。VPIP = vpip / hands，PFR = pfr / hands，3B = threebet / threebet_opp
CREATE TABLE poker_stats (
  user_id INTEGER PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
  hands INTEGER NOT NULL DEFAULT 0,
  wins INTEGER NOT NULL DEFAULT 0,
  vpip INTEGER NOT NULL DEFAULT 0,
  pfr INTEGER NOT NULL DEFAULT 0,
  threebet_opp INTEGER NOT NULL DEFAULT 0,
  threebet INTEGER NOT NULL DEFAULT 0
);
