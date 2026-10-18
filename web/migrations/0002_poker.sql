-- 德州牌桌：桌号、盲注、是否机器人练习桌；seated 由牌桌实时回写，给大厅显示人数
CREATE TABLE poker_tables (
  no INTEGER PRIMARY KEY,
  sb INTEGER NOT NULL,
  bb INTEGER NOT NULL,
  bots INTEGER NOT NULL DEFAULT 0,
  seated INTEGER NOT NULL DEFAULT 0,
  created_by INTEGER REFERENCES users (id) ON DELETE SET NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- 和前端演示一致的 12 张桌，四种盲注轮着来，每轮第一张是机器人练习桌
INSERT INTO poker_tables (no, sb, bb, bots) VALUES
  (1001, 5, 10, 1), (1002, 10, 20, 0), (1003, 50, 100, 0), (1004, 200, 400, 0),
  (1005, 5, 10, 1), (1006, 10, 20, 0), (1007, 50, 100, 0), (1008, 200, 400, 0),
  (1009, 5, 10, 1), (1010, 10, 20, 0), (1011, 50, 100, 0), (1012, 200, 400, 0);

-- 买入、离桌结算按 ref 去重，牌桌重试写账时不会记两次
CREATE UNIQUE INDEX points_ledger_ref ON points_ledger (ref) WHERE ref IS NOT NULL;
