import { addDays, isoDay, parseCostMicro } from "./util";
import { serverCostMicro, type ModelPrice } from "../shared/pricing";

/** 和 yybar App 的 UsageApp 一致。Gemini 没有 token 和花费，只有回答次数（answers）。 */
export const APPS = ["codex", "claude", "grok", "grokBot", "gemini", "agy"] as const;
export type UsageApp = (typeof APPS)[number];

export const LIMITS = {
  daysPerRequest: 120,
  entriesPerDay: 300,
  modelLength: 120,
  maxTokens: 1e12,
  /** 单日总花费上限（美元，App 报的和服务端算的都看）。超过视为异常数据，整个请求拒收。 */
  maxDailyCostUSD: 5000,
  earliestDay: "2023-01-01",
};

export interface UsageRow {
  day: string;
  app: UsageApp;
  model: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
  /** App 报上来的花费（微美元）。只作对照和 Grok 封顶用，真正算筹码的花费由服务端按价格表算（saveUpload） */
  clientCostMicro: number;
  /** 回答次数（Gemini 用；别的服务是 0） */
  answers: number;
}

export interface ParsedUpload {
  days: string[];
  rows: UsageRow[];
}

export class UploadError extends Error {}

function tokenCount(v: unknown, field: string, where: string): number {
  if (typeof v !== "number" || !Number.isInteger(v) || v < 0 || v > LIMITS.maxTokens) {
    throw new UploadError(`${where}: ${field} 必须是非负整数`);
  }
  return v;
}

/**
 * 校验上传内容。格式：
 * { days: [{ day: "2026-10-17", entries: [{ app, model, inputTokens, outputTokens,
 *   cacheReadTokens, cacheCreationTokens, costUSD: "1.23" }] }] }
 * 每个 day 是那一天的完整汇总；每一天的每个服务记一份，量变多了才换（见 saveUpload），App 只传今天以前、已经过完的天。
 */
export function parseUpload(body: unknown, today = isoDay(new Date())): ParsedUpload {
  if (!body || typeof body !== "object" || !Array.isArray((body as { days?: unknown }).days)) {
    throw new UploadError("缺少 days 数组");
  }
  const days = (body as { days: unknown[] }).days;
  if (days.length > LIMITS.daysPerRequest) throw new UploadError(`一次最多上传 ${LIMITS.daysPerRequest} 天`);

  // 只收已经过完的天：App 传的是用户本地的昨天及以前，任何时区的「本地昨天」都不晚于 UTC 今天
  const latest = today;
  const seen = new Set<string>();
  const rows: UsageRow[] = [];

  for (const d of days) {
    if (!d || typeof d !== "object") throw new UploadError("days 里的元素必须是对象");
    const { day, entries } = d as { day?: unknown; entries?: unknown };
    if (typeof day !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(day) || isoDay(new Date(`${day}T00:00:00Z`)) !== day) {
      throw new UploadError(`日期格式不对：${String(day)}`);
    }
    if (day < LIMITS.earliestDay || day > latest) throw new UploadError(`日期超出范围：${day}`);
    if (seen.has(day)) throw new UploadError(`日期重复：${day}`);
    seen.add(day);
    if (!Array.isArray(entries)) throw new UploadError(`${day}: 缺少 entries 数组`);
    if (entries.length > LIMITS.entriesPerDay) throw new UploadError(`${day}: 条目过多`);

    const byKey = new Map<string, UsageRow>();
    let dayCost = 0;
    for (const e of entries) {
      if (!e || typeof e !== "object") throw new UploadError(`${day}: 条目必须是对象`);
      const r = e as Record<string, unknown>;
      if (!APPS.includes(r.app as UsageApp)) throw new UploadError(`${day}: 未知的 app ${String(r.app)}`);
      if (typeof r.model !== "string" || !r.model.trim() || r.model.length > LIMITS.modelLength) {
        throw new UploadError(`${day}: model 不合法`);
      }
      const costMicro = parseCostMicro(r.costUSD);
      if (costMicro === null) throw new UploadError(`${day}: costUSD 必须是非负十进制数`);
      const row: UsageRow = {
        day,
        app: r.app as UsageApp,
        model: r.model.trim(),
        inputTokens: tokenCount(r.inputTokens, "inputTokens", day),
        outputTokens: tokenCount(r.outputTokens, "outputTokens", day),
        cacheReadTokens: tokenCount(r.cacheReadTokens, "cacheReadTokens", day),
        cacheCreationTokens: tokenCount(r.cacheCreationTokens, "cacheCreationTokens", day),
        clientCostMicro: costMicro,
        answers: r.answers === undefined ? 0 : tokenCount(r.answers, "answers", day),
      };
      dayCost += costMicro;
      // 同一 (app, model) 出现多次时合并
      const key = `${row.app}\u0000${row.model}`;
      const prev = byKey.get(key);
      if (prev) {
        prev.inputTokens += row.inputTokens;
        prev.outputTokens += row.outputTokens;
        prev.cacheReadTokens += row.cacheReadTokens;
        prev.cacheCreationTokens += row.cacheCreationTokens;
        prev.clientCostMicro += row.clientCostMicro;
        prev.answers += row.answers;
      } else {
        byKey.set(key, row);
      }
    }
    if (dayCost > LIMITS.maxDailyCostUSD * 1_000_000) {
      throw new UploadError(`${day}: 单日花费超过 $${LIMITS.maxDailyCostUSD}，疑似异常数据`);
    }
    rows.push(...byKey.values());
  }
  return { days: [...seen], rows };
}

/** 「我的」页的上传记录：最近收到的 limit 天，每天最后一次什么时候传上来的、多少 token、多少花费。
 * 上传标记按（日期, 服务）记，用量也按服务对上，不然一天传了几个服务 token 会被算几遍 */
export async function uploadHistory(db: D1Database, userId: number, limit = 10) {
  const { results } = await db
    .prepare(
      `SELECT u.day, MAX(u.uploaded_at) AS uploaded_at,
         COALESCE(SUM(d.input_tokens + d.output_tokens + d.cache_read_tokens + d.cache_creation_tokens), 0) AS tokens,
         COALESCE(SUM(d.cost_micro), 0) AS cost_micro
       FROM usage_uploads u LEFT JOIN daily_usage d ON d.user_id = u.user_id AND d.day = u.day AND d.app = u.app
       WHERE u.user_id = ? GROUP BY u.day ORDER BY u.day DESC LIMIT ?`,
    )
    .bind(userId, limit)
    .all<{ day: string; uploaded_at: string; tokens: number; cost_micro: number }>();
  return results;
}

export interface UploadedPair {
  day: string;
  app: string;
  /** 传了多少：token 总数（Gemini 是回答次数）。App 那边这一天的量比它多时会再传一次 */
  total: number;
  /** 这一天这个服务按服务端价格算的花费（微美元） */
  costMicro: number;
}

/** 这个用户已经上传过的（日期, 服务），按日期升序。 */
export async function uploadedPairs(db: D1Database, userId: number, from = "0000-00-00", to = "9999-99-99"): Promise<UploadedPair[]> {
  const { results } = await db
    .prepare(
      `SELECT u.day, u.app, u.total, COALESCE(SUM(d.cost_micro), 0) AS costMicro
       FROM usage_uploads u LEFT JOIN daily_usage d ON d.user_id = u.user_id AND d.day = u.day AND d.app = u.app
       WHERE u.user_id = ? AND u.day BETWEEN ? AND ? GROUP BY u.day, u.app ORDER BY u.day, u.app`,
    )
    .bind(userId, from, to)
    .all<UploadedPair>();
  return results;
}

/** 一行用量算进「传了多少」的量：token 总数加回答次数（Gemini 只有回答次数） */
const sizeOf = (r: UsageRow) => r.inputTokens + r.outputTokens + r.cacheReadTokens + r.cacheCreationTokens + r.answers;

/**
 * 每一天的每个服务记一份：没传过的（日期, 服务）收下并标记、记下传了多少；传过的只有这次的量更多时
 * （App 新找到了这一天的会话，比如新加了一个 Codex 目录）才整份换成新的，一样多或更少就跳过。
 * 所以同一天传几次、从几台电脑传，筹码都只算一份（量最多的那份）；以后 App 新支持了某个服务，以前的日子还能把这个服务补上。
 * 删旧的、写新的、改标记在同一个事务里，条件都按标记里记的量判断：并发的两次上传不会叠加，量少的那次不会盖掉量多的。
 * 返回这次有新内容收下（或换掉）的日期，和整天都没变、全部跳过的日期。
 */
export async function saveUpload(db: D1Database, userId: number, upload: ParsedUpload): Promise<{ accepted: string[]; skipped: string[] }> {
  if (upload.days.length === 0) return { accepted: [], skipped: [] };
  // 花费按服务端的价格表现算（App 里可以自己改价），App 报的另存一列
  const prices = await loadPrices(db);
  const cost = new Map(upload.rows.map((r) => [r, serverCostMicro(r, prices)]));
  for (const day of upload.days) {
    const total = upload.rows.reduce((s, r) => s + (r.day === day ? cost.get(r)! : 0), 0);
    if (total > LIMITS.maxDailyCostUSD * 1_000_000) throw new UploadError(`${day}: 单日花费超过 $${LIMITS.maxDailyCostUSD}，疑似异常数据`);
  }
  const sorted = [...upload.days].sort();
  const done = new Map((await uploadedPairs(db, userId, sorted[0], sorted[sorted.length - 1])).map((p) => [`${p.day}|${p.app}`, p.total]));
  // 标记里记的量比这次少（或还没标记）才动：删掉旧的、写这次的、把标记改成这次的量
  const clear = db.prepare(
    `DELETE FROM daily_usage WHERE user_id = ?1 AND day = ?2 AND app = ?3
       AND EXISTS (SELECT 1 FROM usage_uploads WHERE user_id = ?1 AND day = ?2 AND app = ?3 AND total < ?4)`,
  );
  const insert = db.prepare(
    `INSERT OR IGNORE INTO daily_usage (user_id, day, app, model, input_tokens, output_tokens,
       cache_read_tokens, cache_creation_tokens, cost_micro, answers, client_cost_micro)
     SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11
     WHERE NOT EXISTS (SELECT 1 FROM usage_uploads WHERE user_id = ?1 AND day = ?2 AND app = ?3 AND total >= ?12)`,
  );
  const mark = db.prepare(
    `INSERT INTO usage_uploads (user_id, day, app, total) VALUES (?1, ?2, ?3, ?4)
     ON CONFLICT (user_id, day, app) DO UPDATE SET total = excluded.total, uploaded_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
     WHERE usage_uploads.total < excluded.total`,
  );
  const stmts: D1PreparedStatement[] = [];
  const accepted: string[] = [];
  const skipped: string[] = [];
  for (const day of upload.days) {
    const apps = [...new Set(upload.rows.filter((r) => r.day === day).map((r) => r.app))];
    const changed = apps.filter((app) => {
      const before = done.get(`${day}|${app}`);
      return before === undefined || upload.rows.reduce((s, r) => s + (r.day === day && r.app === app ? sizeOf(r) : 0), 0) > before;
    });
    if (apps.length && !changed.length) skipped.push(day);
    if (changed.length) accepted.push(day);
    for (const app of changed) {
      const rows = upload.rows.filter((r) => r.day === day && r.app === app);
      const total = rows.reduce((s, r) => s + sizeOf(r), 0);
      stmts.push(clear.bind(userId, day, app, total));
      for (const r of rows) {
        stmts.push(insert.bind(userId, r.day, r.app, r.model, r.inputTokens, r.outputTokens, r.cacheReadTokens, r.cacheCreationTokens, cost.get(r)!, r.answers, r.clientCostMicro, total));
      }
      stmts.push(mark.bind(userId, day, app, total));
    }
  }
  // batch 在一个事务里执行，失败会整体回滚
  if (stmts.length) await db.batch(stmts);
  return { accepted, skipped };
}

/** 服务端的模型价格表（model_prices），网页上「总花费」旁边的问号也用它 */
export async function loadPrices(db: D1Database): Promise<ModelPrice[]> {
  const { results } = await db
    .prepare("SELECT model, vendor, input, output, cache_read, cache_write, billed FROM model_prices ORDER BY vendor, model")
    .all<ModelPrice>();
  return results;
}
