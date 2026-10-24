-- 大厅布告栏：每张桌现在连着几个真人（在座的和旁观的，同一个账号开几个页面算一个），牌桌在有人连上 / 断开时写回。
ALTER TABLE poker_tables ADD COLUMN online INTEGER NOT NULL DEFAULT 0;
