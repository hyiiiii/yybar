# yybar 网站

用 GitHub 登录，接收 yybar App 上传的每日 token 用量和花费，做排行榜和积分；积分当筹码在 Bar 里打德州、在商场里买牌背牌面。顶栏四个图标入口：Bar（酒杯）、商场（购物车）、排行榜（领奖台）、成就（奖杯）。跑在 Cloudflare Workers 上，数据库是 D1（SQLite）。

## 结构

| 路径 | 内容 |
|---|---|
| `src/worker/` | 后端（Hono）：GitHub 登录、会话、上传令牌、用量接口、排行榜、牌桌接口 |
| `src/worker/table.ts` | 德州牌桌的 Durable Object：每张桌一个，WebSocket 推送、计时、筹码记账 |
| `src/shared/poker/` | 德州牌局逻辑（前后端共用）：发牌、下注、边池、比牌、练习桌机器人 |
| `src/client/` | 前端（React + Vite），构建到 `dist/` 由 Worker 的静态资源托管 |
| `migrations/` | D1 表结构 |
| `test/` | 上传校验、牌局逻辑的单元测试 |

## 本地开发

```sh
cd web
npm install
echo 'DEV_LOGIN=1' > .dev.vars        # 本地免 GitHub 登录：/auth/dev-login?login=alice
npm run db:migrate:local
npm run dev                            # http://localhost:8787
npm test && npm run typecheck
```

本地试多人德州：每个窗口要是不同的登录，用无痕窗口或不同浏览器分别打开
`http://localhost:8787/auth/dev-login?login=alice&next=/table/1002`（把 alice 换成 bob、carol…）。
本地假账号第一次登录会送 20,000 筹码。

## 部署到 Cloudflare

1. 在 GitHub 新建 OAuth App（Settings → Developer settings → OAuth Apps）：
   - Homepage URL：网站地址，例如 `https://yybar.<你的子域>.workers.dev`
   - Authorization callback URL：`<网站地址>/auth/github/callback`
2. 创建数据库，把返回的 `database_id` 填进 `wrangler.jsonc`，同时把 `APP_URL` 改成网站地址：
   ```sh
   npx wrangler login
   npx wrangler d1 create yybar
   ```
3. 设置机密：
   ```sh
   npx wrangler secret put GITHUB_CLIENT_ID
   npx wrangler secret put GITHUB_CLIENT_SECRET
   ```
4. `npm run deploy`（构建前端、执行迁移、发布 Worker）。

线上不要设置 `DEV_LOGIN`。

## App 上传接口

所有请求带 `Authorization: Bearer <上传令牌>`。令牌在网站「我的」页创建，或由 App 走连接流程获得。

**连接流程**：App 打开 `<网站>/connect?state=<随机串>`，用户登录并点「授权」后，浏览器跳到
`yybar://connect?token=<令牌>&state=<原样返回>`，App 校验 state 后保存令牌。

`GET /api/v1/whoami` → `{ "user": { "login", "name", "avatarUrl" } }`，用来确认令牌有效。

`POST /api/v1/usage`

```json
{
  "days": [
    {
      "day": "2026-10-17",
      "entries": [
        { "app": "claude", "model": "claude-sonnet-4.5", "inputTokens": 1200, "outputTokens": 3400,
          "cacheReadTokens": 560000, "cacheCreationTokens": 7800, "costUSD": "12.345678" }
      ]
    }
  ]
}
```

- 字段与 App 里的 `UsageBucket` 一致；`day` 是用户本地日期，`costUSD` 用十进制字符串。
- 每个出现的 `day` 都是那天的**完整快照**：服务端先删掉那天的旧数据再写入，所以重复上传同一天不会重复计数。`entries` 为空表示清空那天。
- 限制：一次最多 120 天、每天 300 条；日期不早于 2023-01-01、不晚于明天；单日总花费超过 $5000 整个请求拒收（422）。

## 排行榜

- 用图标切换两种排法，只列在「我的」里打开了「在排行榜和公开主页上显示我」的人。
- 燃烧 token（火苗）：按时间段（今天 / 7 天 / 30 天 / 总榜）内的 token 数排名，每行带最常用的模型。`GET /api/leaderboard?by=tokens&range=7d`。
- 财富（筹码）：按筹码余额排名（坐在桌上的筹码不算，离桌退回后才算）。`GET /api/leaderboard?by=wealth`。

## 商场

- 用筹码买东西，款式、价格、中英文名都在 `src/shared/cosmetics.ts`。名字都是一眼看得出在玩哪副牌的梗（丹车 / Bicyle、塔里猴 / Tally-Hoo、醇黑 / Purr、潮曦 / Daybrake），不是正版。
- 牌背（7 款）：你的暗牌在同桌所有人眼里都是这一款；你自己屏幕上桌面中间的背面牌也用它。
- 牌面（5 款）：你的牌翻开时用这一款，同桌的人都看得到；公共牌在你屏幕上也用它。
- 牌背、牌面换了之后下次连上牌桌时生效。样式在 `styles.css` 的 `.back-<款式>` / `.card.face-<款式>`。
- 表情（9 个，前 4 个默认就有）：Claude 像素小人，坐在桌上时点手牌下面的笑脸发给全桌，在那个人头上冒一下。两次至少隔 1.5 秒。
- 道具（按个数买，用掉就少一个，存在 `user_items`）：
  - 加时卡：轮到你时多 10 秒，每次行动一张。
  - 偷偷看：一手结束后看别人没亮出来的底牌（弃了的也算）。只有你看得到，发牌员会告诉全桌「某某用了偷偷看」。
  - 发发看：一手提前结束时，按发牌顺序（先烧一张）看还没翻出来的公共牌。同样只有你看得到、全桌会被告知。
  - 三个道具和表情按钮都在你手牌下面。牌桌先检查能不能用，再扣库存，再生效；扣库存时局面变了就退回去。
- 买牌背、牌面、表情记在 `points_ledger`（`reason = 'shop'`，`ref = shop:<用户>:<种类>:<款式>`，同一款不会扣两次）；买道具的扣款和加库存在同一个事务里。正在用的款式在 `users.card_back` / `users.card_face`（迁移 `0004_cosmetics.sql`）。
- 接口：`GET /api/shop`、`POST /api/shop/buy {"kind":"back|face|emote|item","id":…}`、`POST /api/shop/equip {…}`；`GET /api/me` 带 `look`、`items`、`emotes`。牌桌消息：`{"t":"item","item":"timecard|peek|runout"}`、`{"t":"emote","id":…}`。

## 成就

- 达成后送一笔筹码（按 $ 显示），并解锁一个徽章；在成就页挑一个「戴上」，就挂在名字后面（牌桌、排行榜、个人页）。目录在 `src/shared/achievements.ts`。
- 目前 12 个：第一次登录！、入座、剁手、连续 7 / 30 / 365 天 work（有用量上传的连续天数）、今天 token 第一！（某天烧的 token 全站第一，今天和昨天都算，避免时区差一天）、一亿 / 十亿 token、千刀俱乐部（累计花费 $1,000）、大赢家（一手赢 $10,000 以上）、同花顺！（摊牌亮出同花顺）。
- 前面 10 个在打开网站（`/api/me`）和成就页时按用量、流水自动检查；大赢家、同花顺由牌桌在一手结束时记下。解锁记在 `user_achievements`，奖励记在 `points_ledger`（`reason = 'achievement'`，`ref = ach:<用户>:<成就>`），都不会重复发。戴着的徽章在 `users.badge`（迁移 `0005_achievements.sql`）。
- 接口：`GET /api/achievements`（成就、进度、正在戴的徽章）、`POST /api/achievements/wear {"id": … | null}`。

## 中英文

- 左上角 yybar 旁边的「中 / EN」切换，记在浏览器里。界面文字用 `t(中文, English)` 就地写两份；服务端发来的动作、牌型、报错、机器人名字在 `src/client/i18n.tsx` 里翻成英文。

## 积分

- 积分 = 累计记录花费 × 100（$1 = 100 分，向下取整），随上传实时计算。
- 德州的买入和离桌退回记在 `points_ledger`，余额 = 花费积分 + 流水合计。
- 积分只能这样获得，不能充值、购买或兑现。

## 德州牌桌

- 无限注德州，每桌 6 个座位。筹码按美元显示：1 个筹码记作 $1（盲注 5/10 显示成 $5/$10）。桌子存在 D1 的 `poker_tables`，初始 12 张（#1001～#1012），盲注 5/10、10/20、50/100、200/400 轮着来，#1001、#1005、#1009 是机器人练习桌。
- 每张桌一个 Durable Object（`PokerTable`，按桌号取），牌局完全在服务端跑：洗牌用 `crypto.getRandomValues`，别人的底牌在摊牌前不会发到浏览器。
- 连接：`GET /api/tables/<桌号>/ws` 升级为 WebSocket。带登录 cookie 可以入座，没登录只能旁观；只接受本站页面发起的连接。
  - 浏览器发：`{"t":"hold","seat":0-5}`（点空位先占座）、`{"t":"release"}`（不坐了）、`{"t":"sit","seat":0-5,"buyIn":带入筹码}`（不带 `buyIn` 按 100 个大盲）、`{"t":"show","which":0|1|2}`（别人都弃牌赢下时亮第一张 / 第二张 / 两张）、`{"t":"leave"}`、`{"t":"act","action":"fold|check|call|raise","amount":加注到多少}`。
  - 服务端推：`{"t":"state","view":{…}}`（每人看到自己的视角，字段见 `src/shared/poker/types.ts`）、`{"t":"error","msg":"…"}`、`{"t":"closed"}`（玩家开的桌没人了，已收掉）。
- 占座：点空位先占 10 秒，牌子上写「买入中…」，头像变灰，外面一圈橙色倒计时，走过的部分变白；别人抢不走，10 秒内没坐下就放开。
- 输光再买入：在一张桌上筹码输光，下一手开始前站起来，但座位替你占 10 秒（同样是「买入中…」），余额够最低买入就自动弹出买入面板，可以原位再坐下；余额不够直接放开。
- 带入：点空位后用滑杆选带多少入座，40～200 个大盲（不超过余额），默认 100 个。余额判断和扣款是同一条 SQL，同时在几张桌入座也不会扣成负数。
- 离桌：不在牌局里马上结算；牌局中离桌先弃牌，这手结束后把剩余筹码退回余额。买入和退回都记在 `points_ledger`（`buyin` / `cashout`），按 `ref` 去重，写失败会存着重试。
- 计时：每次行动 10 秒，轮到谁，谁的头像外圈有一圈绿条慢慢缩短；超时能过牌就过牌、否则弃牌；连续两次超时自动离桌。掉线的人轮到时只等 5 秒，掉线超过 1 分钟，下一手开始前自动离桌。
- 机器人练习桌：有真人坐下就补机器人，凑够 4 个人；真人走光机器人也走。机器人的筹码不进任何账户。
- 座位：圆盘里是位置（BTN / SB / BB…），名字和余额在下面的小牌子上，刚才的动作是头上的小标签。入座后桌子转起来把你转到下方，座位沿着桌边一格一格走过去；庄家按钮换庄时也是滑过去的。左右两个座位的下注放在桌面里。
- 结算：没人跟的下注（投入最多的人比第二多的人多出来的部分）先原样退回，不算赢，再按主池、边池分。
- 赢家：头像一圈金光，牌子上是 WIN、赢了多少和牌型。别人都弃牌赢下时，点自己的一张牌就把它正面朝上丢到桌面上，再点一张再丢一张（或「两张都亮」）。摊牌时别人的牌翻开有翻牌动画。轮到你行动时自己的牌有一圈光晕。离桌要再点一次确认。
- 多桌：可以同时坐几张桌。坐着的桌记在 `poker_seats`（牌桌实时回写），`GET /api/tables` 登录时带上 `mine`；前端在后台连着这些桌，不算掉线。轮到你在别的桌行动时，右下角铃铛晃动、亮红点，手机上震动（`navigator.vibrate`，iOS Safari 不支持）；点铃铛回到那张桌。
- 发牌员平时不说话，会眨眼、东张西望、招手、洗牌、蹦一下；登录后它冒个气泡打招呼（「又开工了，hyi」），几秒后消失。
- 加注：滑杆在最小加注和全下之间按小盲取整，旁边有 2.5x / 3x、半池、底池几个快捷额度。
- 开桌：点右下角加号，选盲注（$5/$10、$10/$20、$25/$50、$50/$100、$100/$200、$200/$400）和带入，开好后自动入座。接口是 `POST /api/tables {"blinds":[小盲,大盲]}`，桌号接在最后；坐在任何一张桌上时不能开新桌（按 `poker_seats` 判断），每人最多同时开 3 张。`GET /api/tables` 列出所有桌、在座人数和是不是玩家开的（`temporary`）。
- 空桌收掉：玩家开的桌没有真人坐着（离桌的筹码也都退回了）超过 30 秒，牌桌就从大厅删掉、存档清空，还连着的人会被送回默认桌；开了却一直没人连上去的桌，2 分钟后在 `GET /api/tables` 时顺手清掉。初始 12 张桌不会收。
- 预览版（`npm run build:demo`）没有服务端，同一套牌局逻辑直接在浏览器里跑，其他座位是机器人；预览里自己开的桌放三个机器人陪打。
- 过渡动画：下注的筹码从座位推出来，弃牌时两张牌往桌心收走，动作文字和底池数字轻轻弹一下；系统设置了减少动态效果时不播。

## 已知局限

用量是在用户自己的 Mac 上统计的，网站无法验证真伪。目前只有格式校验和单日上限，排行榜可能被伪造的数据刷榜。
