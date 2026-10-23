-- 成就改成自己领：解锁时只记一行，等用户在成就页点「领取」才发奖励（points_ledger，ref 仍是 'ach:<用户>:<成就>'）。
-- claimed_at 为空 = 解锁了还没领。以前解锁的成就当时已经自动发过奖励，都当作领过。
ALTER TABLE user_achievements ADD COLUMN claimed_at TEXT;
UPDATE user_achievements SET claimed_at = unlocked_at;
