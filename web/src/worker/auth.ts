import { Hono, type Context, type Next } from "hono";
import { deleteCookie, getCookie, setCookie } from "hono/cookie";
import type { AppEnv, Env, UserRow } from "./types";
import { randomToken, sha256 } from "./util";

const SESSION_COOKIE = "yyb_session";
const STATE_COOKIE = "yyb_oauth";
const SESSION_DAYS = 30;

function secureCookie(env: Env) {
  return env.APP_URL.startsWith("https://");
}

/** 只允许站内相对路径，防止开放重定向。 */
function safeNext(next: string | undefined): string {
  return next && next.startsWith("/") && !next.startsWith("//") ? next : "/me";
}

async function upsertGitHubUser(
  db: D1Database,
  gh: { id: number; login: string; name: string | null; avatar_url: string | null },
): Promise<number> {
  const row = await db
    .prepare(
      `INSERT INTO users (github_id, login, name, avatar_url) VALUES (?, ?, ?, ?)
       ON CONFLICT (github_id) DO UPDATE SET login = excluded.login, name = excluded.name, avatar_url = excluded.avatar_url
       RETURNING id`,
    )
    .bind(gh.id, gh.login, gh.name, gh.avatar_url)
    .first<{ id: number }>();
  return row!.id;
}

async function startSession(c: Context<AppEnv>, userId: number) {
  const token = randomToken();
  const expires = new Date(Date.now() + SESSION_DAYS * 86400_000);
  await c.env.DB.prepare("INSERT INTO sessions (id, user_id, expires_at) VALUES (?, ?, ?)")
    .bind(await sha256(token), userId, expires.toISOString())
    .run();
  setCookie(c, SESSION_COOKIE, token, {
    httpOnly: true,
    secure: secureCookie(c.env),
    sameSite: "Lax",
    path: "/",
    expires,
  });
}

export async function sessionUser(c: Context<AppEnv>): Promise<UserRow | null> {
  const token = getCookie(c, SESSION_COOKIE);
  if (!token) return null;
  return c.env.DB.prepare(
    `SELECT u.* FROM sessions s JOIN users u ON u.id = s.user_id
     WHERE s.id = ? AND s.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now')`,
  )
    .bind(await sha256(token))
    .first<UserRow>();
}

/** 网页接口：要求已登录。写操作还要求 JSON 请求体，借浏览器的 CORS 预检挡住跨站表单提交。 */
export async function requireSession(c: Context<AppEnv>, next: Next) {
  const user = await sessionUser(c);
  if (!user) return c.json({ error: "未登录" }, 401);
  if (!["GET", "HEAD", "DELETE"].includes(c.req.method) && !c.req.header("content-type")?.startsWith("application/json")) {
    return c.json({ error: "需要 JSON 请求" }, 415);
  }
  c.set("user", user);
  await next();
}

/** App 接口：Authorization: Bearer <上传令牌>。 */
export async function requireApiToken(c: Context<AppEnv>, next: Next) {
  const header = c.req.header("authorization") ?? "";
  const m = /^Bearer\s+(\S+)$/i.exec(header);
  if (!m) return c.json({ error: "缺少上传令牌" }, 401);
  const hash = await sha256(m[1]);
  const row = await c.env.DB.prepare(
    `SELECT u.*, t.id AS api_token_id FROM api_tokens t JOIN users u ON u.id = t.user_id
     WHERE t.token_hash = ? AND t.revoked_at IS NULL`,
  )
    .bind(hash)
    .first<UserRow & { api_token_id: number }>();
  if (!row) return c.json({ error: "上传令牌无效或已撤销" }, 401);
  const { api_token_id: tokenId, ...user } = row;
  c.executionCtx.waitUntil(
    c.env.DB.prepare("UPDATE api_tokens SET last_used_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE token_hash = ?")
      .bind(hash)
      .run(),
  );
  c.set("user", user);
  c.set("tokenId", tokenId);
  await next();
}

export const authRoutes = new Hono<AppEnv>();

authRoutes.get("/github", (c) => {
  if (!c.env.GITHUB_CLIENT_ID) return c.text("GitHub 登录未配置", 500);
  const state = randomToken(16);
  setCookie(c, STATE_COOKIE, `${state}|${safeNext(c.req.query("next"))}`, {
    httpOnly: true,
    secure: secureCookie(c.env),
    sameSite: "Lax",
    path: "/auth",
    maxAge: 600,
  });
  const url = new URL("https://github.com/login/oauth/authorize");
  url.searchParams.set("client_id", c.env.GITHUB_CLIENT_ID);
  url.searchParams.set("redirect_uri", `${c.env.APP_URL}/auth/github/callback`);
  url.searchParams.set("scope", "read:user");
  url.searchParams.set("state", state);
  url.searchParams.set("allow_signup", "true");
  return c.redirect(url.toString());
});

authRoutes.get("/github/callback", async (c) => {
  const [expected, next] = (getCookie(c, STATE_COOKIE) ?? "").split("|");
  deleteCookie(c, STATE_COOKIE, { path: "/auth" });
  const code = c.req.query("code");
  if (!code || !expected || c.req.query("state") !== expected) return c.text("登录已失效，请重试", 400);

  const tokenRes = await fetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: { accept: "application/json", "content-type": "application/json" },
    body: JSON.stringify({
      client_id: c.env.GITHUB_CLIENT_ID,
      client_secret: c.env.GITHUB_CLIENT_SECRET,
      code,
      redirect_uri: `${c.env.APP_URL}/auth/github/callback`,
    }),
  });
  const tokenJson = (await tokenRes.json()) as { access_token?: string };
  if (!tokenJson.access_token) return c.text("GitHub 授权失败", 400);

  const ghRes = await fetch("https://api.github.com/user", {
    headers: { authorization: `Bearer ${tokenJson.access_token}`, "user-agent": "yybar-web", accept: "application/vnd.github+json" },
  });
  if (!ghRes.ok) return c.text("读取 GitHub 账号失败", 502);
  const gh = (await ghRes.json()) as { id: number; login: string; name: string | null; avatar_url: string | null };
  // GitHub 的 access token 用完即弃，不保存

  const userId = await upsertGitHubUser(c.env.DB, gh);
  await startSession(c, userId);
  return c.redirect(safeNext(next));
});

authRoutes.post("/logout", async (c) => {
  const token = getCookie(c, SESSION_COOKIE);
  if (token) await c.env.DB.prepare("DELETE FROM sessions WHERE id = ?").bind(await sha256(token)).run();
  deleteCookie(c, SESSION_COOKIE, { path: "/" });
  return c.json({ ok: true });
});

// 本地开发用：DEV_LOGIN=1 时可用 /auth/dev-login?login=alice 直接登录一个假账号
authRoutes.get("/dev-login", async (c) => {
  if (c.env.DEV_LOGIN !== "1") return c.notFound();
  const login = c.req.query("login") || "dev";
  let hash = 0;
  for (const ch of login) hash = (hash * 31 + ch.charCodeAt(0)) | 0;
  const userId = await upsertGitHubUser(c.env.DB, { id: -Math.abs(hash) - 1, login, name: login, avatar_url: null });
  // 假账号送 20,000 筹码，方便本地开几个窗口试德州；按 ref 去重只送一次
  await c.env.DB.prepare("INSERT OR IGNORE INTO points_ledger (user_id, delta, reason, ref) VALUES (?, 20000, 'dev-grant', ?)")
    .bind(userId, `dev-grant:${userId}`)
    .run();
  await startSession(c, userId);
  return c.redirect(safeNext(c.req.query("next")));
});
