export interface Env {
  DB: D1Database;
  ASSETS: Fetcher;
  /** 每张德州牌桌一个 Durable Object，按桌号取 */
  TABLES: DurableObjectNamespace<import("./table").PokerTable>;
  APP_URL: string;
  GITHUB_CLIENT_ID?: string;
  GITHUB_CLIENT_SECRET?: string;
  /** 仅本地开发：设为 "1" 时开放 /auth/dev-login，免 GitHub 登录。 */
  DEV_LOGIN?: string;
}

export interface UserRow {
  id: number;
  github_id: number;
  login: string;
  name: string | null;
  avatar_url: string | null;
  show_on_board: number;
  created_at: string;
}

export type AppEnv = { Bindings: Env; Variables: { user: UserRow } };
