-- 谁坐在哪几张桌：牌桌实时回写，大厅据此让同时坐几张桌的人在后台连着这些桌（轮到行动时提醒）
CREATE TABLE poker_seats (
  table_no INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  PRIMARY KEY (table_no, user_id)
);
CREATE INDEX poker_seats_user ON poker_seats (user_id);
