-- 商场：用户正在用的牌背和牌面。买过的牌背、牌面、表情记在 points_ledger
-- （reason = 'shop'，ref = 'shop:<用户>:<种类>:<款式>'）
ALTER TABLE users ADD COLUMN card_back TEXT NOT NULL DEFAULT 'bicyle-red';
ALTER TABLE users ADD COLUMN card_face TEXT NOT NULL DEFAULT 'classic';

-- 道具库存：加时卡、偷偷看、发发看，按个数买，牌桌上用掉就减一
CREATE TABLE user_items (
  user_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  item TEXT NOT NULL,
  qty INTEGER NOT NULL DEFAULT 0 CHECK (qty >= 0),
  PRIMARY KEY (user_id, item)
);
