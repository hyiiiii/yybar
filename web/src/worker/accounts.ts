// 个人主页 @ 后面的订阅：App 把各服务账号的套餐传上来（不带邮箱，只带账号摘要），主页按 服务 + 套餐 汇总，
// 同一服务同一套餐的几个账号显示成「× n」。
import { APPS, type UsageApp } from "./usage";
import { isoDay } from "./util";

export const ACCOUNT_LIMITS = {
  perUpload: 50,
  planLength: 40,
  /** 一台设备这么多天没再上传，它传过的账号就不算了（换了电脑、卸了 App）。订阅随用量一起传，手动传得少也够用 */
  staleDays: 90,
};

export interface AccountRow {
  app: UsageApp;
  /** App 端对账号做的摘要（十六进制），只用来跨设备去重 */
  account: string;
  plan: string;
}

export interface PlanSummary {
  app: UsageApp;
  plan: string;
  count: number;
}

export class AccountsError extends Error {}

/** App 传的设备 id（这台电脑固定的一个 UUID）；旧版 App 不带，为 null */
export function parseDevice(body: unknown): string | null {
  const device = (body as { device?: unknown } | null)?.device;
  if (device == null) return null;
  if (typeof device !== "string" || !/^[0-9a-f-]{8,64}$/.test(device)) throw new AccountsError("device 不合法");
  return device;
}

/** 校验 App 传的 { accounts: [{ app, account, plan }] }；同一 (服务, 账号) 只留第一条 */
export function parseAccounts(body: unknown): AccountRow[] {
  const list = (body as { accounts?: unknown } | null)?.accounts;
  if (!Array.isArray(list)) throw new AccountsError("accounts 必须是数组");
  if (list.length > ACCOUNT_LIMITS.perUpload) throw new AccountsError(`一次最多 ${ACCOUNT_LIMITS.perUpload} 个账号`);
  const rows: AccountRow[] = [];
  const seen = new Set<string>();
  list.forEach((item, i) => {
    const { app, account, plan } = (item ?? {}) as Record<string, unknown>;
    if (typeof app !== "string" || !(APPS as readonly string[]).includes(app)) throw new AccountsError(`第 ${i + 1} 个账号的 app 不认识`);
    if (typeof account !== "string" || !/^[0-9a-f]{8,64}$/.test(account)) throw new AccountsError(`第 ${i + 1} 个账号的 account 不合法`);
    const name = typeof plan === "string" ? plan.replace(/\s+/g, " ").trim() : "";
    // 套餐名只是一个短标签：不收控制字符和尖括号
    if (!name || name.length > ACCOUNT_LIMITS.planLength || /[\u0000-\u001f<>]/.test(name)) throw new AccountsError(`第 ${i + 1} 个账号的 plan 不合法`);
    const key = `${app}|${account}`;
    if (seen.has(key)) return;
    seen.add(key);
    rows.push({ app: app as UsageApp, account, plan: name });
  });
  return rows;
}

/**
 * 这台设备的账号整份替换成这次传的。带设备 id 时换掉这台设备上次传的（不管当时用的哪个令牌，重新连接网站会换令牌），
 * 顺手清掉旧版 App 不带设备 id 传的行；不带时（旧版 App）按令牌替换。
 */
export async function saveAccounts(db: D1Database, userId: number, tokenId: number, rows: AccountRow[], device: string | null = null) {
  const clear = device
    ? db.prepare("DELETE FROM user_accounts WHERE user_id = ? AND (device = ? OR device = '' OR token_id = ?)").bind(userId, device, tokenId)
    : db.prepare("DELETE FROM user_accounts WHERE token_id = ?").bind(tokenId);
  await db.batch([
    clear,
    ...rows.map((r) =>
      db
        .prepare("INSERT INTO user_accounts (token_id, user_id, device, app, account, plan) VALUES (?, ?, ?, ?, ?, ?)")
        .bind(tokenId, userId, device ?? "", r.app, r.account, r.plan),
    ),
  ]);
}

/**
 * 主页上的订阅：几台设备传的账号按 (服务, 账号) 去重（同一账号取最近一次传的套餐），再按 (服务, 套餐) 计数。
 * 撤销了的令牌、90 天没再传的设备不算。按服务顺序排，同一服务里账号多的在前。
 */
export async function plansOf(db: D1Database, userId: number, now = new Date()): Promise<PlanSummary[]> {
  const since = `${isoDay(new Date(now.getTime() - ACCOUNT_LIMITS.staleDays * 86400_000))}T00:00:00.000Z`;
  const { results } = await db
    .prepare(
      `SELECT app, plan, COUNT(*) AS count FROM (
         SELECT a.app, a.account, a.plan, MAX(a.updated_at) AS updated_at
         FROM user_accounts a JOIN api_tokens t ON t.id = a.token_id
         WHERE a.user_id = ? AND t.revoked_at IS NULL AND a.updated_at >= ?
         GROUP BY a.app, a.account
       ) GROUP BY app, plan`,
    )
    .bind(userId, since)
    .all<PlanSummary>();
  return results.sort((a, b) => APPS.indexOf(a.app) - APPS.indexOf(b.app) || b.count - a.count || a.plan.localeCompare(b.plan));
}
