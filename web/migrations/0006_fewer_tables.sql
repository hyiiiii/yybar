-- 默认的桌只留四张：#1000 机器人桌 1/2（三个机器人一直在打），#1001 1/2、#1002 2/5、#1003 5/10。
-- 玩家自己开的桌（created_by 不为空）不动。改过盲注的桌把 created_at 换成现在，
-- 牌桌（Durable Object）据此认出旧存档，没人坐着就从头开。
DELETE FROM poker_tables WHERE created_by IS NULL AND no NOT IN (1001, 1002, 1003);
UPDATE poker_tables SET sb = 1, bb = 2, bots = 0, created_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE no = 1001;
UPDATE poker_tables SET sb = 2, bb = 5, bots = 0, created_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE no = 1002;
UPDATE poker_tables SET sb = 5, bb = 10, bots = 0, created_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE no = 1003;
INSERT INTO poker_tables (no, sb, bb, bots) VALUES (1000, 1, 2, 1);
DELETE FROM poker_seats WHERE table_no NOT IN (SELECT no FROM poker_tables);
