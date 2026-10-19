# yybar 网站

用 GitHub 登录，接收 yybar App 上传的每日 token 用量和花费，做排行榜和积分。跑在 Cloudflare Workers 上，数据库是 D1（SQLite）。

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
- 占座：点空位先占 10 秒，别人看到的是灰色头像加一圈橙色倒计时，抢不走；10 秒内没坐下就放开。
- 带入：点空位后用滑杆选带多少入座，40～200 个大盲（不超过余额），默认 100 个。余额判断和扣款是同一条 SQL，同时在几张桌入座也不会扣成负数。
- 离桌：不在牌局里马上结算；牌局中离桌先弃牌，这手结束后把剩余筹码退回余额。买入和退回都记在 `points_ledger`（`buyin` / `cashout`），按 `ref` 去重，写失败会存着重试。
- 计时：每次行动 10 秒，轮到谁，谁的头像外圈有一圈绿条慢慢缩短；超时能过牌就过牌、否则弃牌；连续两次超时自动离桌。掉线的人轮到时只等 5 秒，掉线超过 1 分钟，下一手开始前自动离桌。
- 机器人练习桌：有真人坐下就补机器人，凑够 4 个人；真人走光机器人也走。机器人的筹码不进任何账户。
- 座位：圆盘里是位置（BTN / SB / BB…），名字和余额在下面的小牌子上，刚才的动作是头上的小标签。入座后桌子转一圈把你转到下方，座位沿着桌子滑过去；庄家按钮换庄时也是滑过去的。左右两个座位的下注放在桌面里。
- 赢家：头像一圈金光，牌子上是 WIN、赢了多少和牌型。别人都弃牌赢下时，自己的牌可以点一张亮一张，或者「两张都亮」。离桌要再点一次确认。
- 多桌：可以同时坐几张桌。坐着的桌记在 `poker_seats`（牌桌实时回写），`GET /api/tables` 登录时带上 `mine`；前端在后台连着这些桌，不算掉线。轮到你在别的桌行动时，右下角铃铛晃动、亮红点，手机上震动（`navigator.vibrate`，iOS Safari 不支持）；点铃铛回到那张桌。
- 发牌员不说话，会眨眼、东张西望、招手、洗牌、蹦一下；登录后桌子上方有一句问候（「✱ 又开工了，hyi」）。
- 加注：滑杆在最小加注和全下之间按小盲取整，旁边有 2.5x / 3x、半池、底池几个快捷额度。
- 开桌：点右下角加号，选盲注（$5/$10、$10/$20、$25/$50、$50/$100、$100/$200、$200/$400）和带入，开好后自动入座。接口是 `POST /api/tables {"blinds":[小盲,大盲]}`，桌号接在最后，每人最多同时开 3 张。`GET /api/tables` 列出所有桌、在座人数和是不是玩家开的（`temporary`）。
- 空桌收掉：玩家开的桌没有真人坐着（离桌的筹码也都退回了）超过 30 秒，牌桌就从大厅删掉、存档清空，还连着的人会被送回默认桌；开了却一直没人连上去的桌，2 分钟后在 `GET /api/tables` 时顺手清掉。初始 12 张桌不会收。
- 预览版（`npm run build:demo`）没有服务端，同一套牌局逻辑直接在浏览器里跑，其他座位是机器人；预览里自己开的桌放三个机器人陪打。
- 过渡动画：下注的筹码从座位推出来，弃牌时两张牌往桌心收走，动作文字和底池数字轻轻弹一下；系统设置了减少动态效果时不播。

## 已知局限

用量是在用户自己的 Mac 上统计的，网站无法验证真伪。目前只有格式校验和单日上限，排行榜可能被伪造的数据刷榜。
