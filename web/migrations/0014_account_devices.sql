-- 订阅按设备替换：App 每次上传带上这台电脑固定的设备 id，网站把这台设备上次传的（不管当时用的哪个上传令牌）整份换掉。
-- 以前按上传令牌替换：重新连接网站会拿到新令牌，旧令牌没撤销的话它传过的旧订阅（比如早就退订的 Claude Pro）一直留在主页上。
-- 旧版 App 不带设备 id，记成 ''；带设备 id 的上传会顺手清掉这个用户所有 '' 的行。
ALTER TABLE user_accounts ADD COLUMN device TEXT NOT NULL DEFAULT '';
CREATE INDEX user_accounts_device ON user_accounts (user_id, device);
