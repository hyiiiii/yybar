-- 商场：用户正在用的牌背和牌面（买过什么记在 points_ledger，reason = 'shop'，ref = 'shop:<用户>:<种类>:<款式>'）
ALTER TABLE users ADD COLUMN card_back TEXT NOT NULL DEFAULT 'classic';
ALTER TABLE users ADD COLUMN card_face TEXT NOT NULL DEFAULT 'classic';
