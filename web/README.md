# yybar 网站

用 GitHub 登录，接收 yybar App 上传的每日 token 用量和花费，做排行榜和积分。跑在 Cloudflare Workers 上，数据库是 D1（SQLite）。

## 结构

| 路径 | 内容 |
|---|---|
| `src/worker/` | 后端（Hono）：GitHub 登录、会话、上传令牌、用量接口、排行榜 |
| `src/client/` | 前端（React + Vite），构建到 `dist/` 由 Worker 的静态资源托管 |
| `migrations/` | D1 表结构 |
| `test/` | 上传校验的单元测试 |

## 本地开发

```sh
cd web
npm install
echo 'DEV_LOGIN=1' > .dev.vars        # 本地免 GitHub 登录：/auth/dev-login?login=alice
npm run db:migrate:local
npm run dev                            # http://localhost:8787
npm test && npm run typecheck
```

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
- 以后德州的输赢记在 `points_ledger`，余额 = 花费积分 + 流水合计。
- 积分只能这样获得，不能充值、购买或兑现。

## 已知局限

用量是在用户自己的 Mac 上统计的，网站无法验证真伪。目前只有格式校验和单日上限，排行榜可能被伪造的数据刷榜。
