-- 每人每天（UTC）在牌桌上的输赢：每手结束记一笔「赢到的 - 投进去的」，给财富榜的「今日输赢」用
CREATE TABLE poker_daily (
  user_id INTEGER NOT NULL,
  day TEXT NOT NULL,
  net INTEGER NOT NULL DEFAULT 0,
  hands INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, day)
);
CREATE INDEX poker_daily_day ON poker_daily (day);
