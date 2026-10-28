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
  /** 商场里换上的牌背、牌面 */
  card_back: string;
  card_face: string;
  /** 戴在名字后面的成就徽章（JSON 数组，最多 3 个） */
  badges: string;
}

/** tokenId：App 接口（requireApiToken）里这次请求用的上传令牌，一台设备一个 */
export type AppEnv = { Bindings: Env; Variables: { user: UserRow; tokenId: number } };
