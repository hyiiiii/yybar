import { addDays, isoDay, parseCostMicro } from "./util";

export const APPS = ["codex", "claude", "grok"] as const;
export type UsageApp = (typeof APPS)[number];

export const LIMITS = {
  daysPerRequest: 120,
  entriesPerDay: 300,
  modelLength: 120,
  maxTokens: 1e12,
  /** 单日总花费上限（美元）。超过视为异常数据，整个请求拒收。 */
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
  costMicro: number;
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
 * 每个出现的 day 视为该日的完整快照：服务端先删后写，重复上传结果不变。
 */
export function parseUpload(body: unknown, today = isoDay(new Date())): ParsedUpload {
  if (!body || typeof body !== "object" || !Array.isArray((body as { days?: unknown }).days)) {
    throw new UploadError("缺少 days 数组");
  }
  const days = (body as { days: unknown[] }).days;
  if (days.length > LIMITS.daysPerRequest) throw new UploadError(`一次最多上传 ${LIMITS.daysPerRequest} 天`);

  const latest = addDays(today, 1); // 允许比 UTC 快一天的时区
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
        costMicro,
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
        prev.costMicro += row.costMicro;
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

export async function saveUpload(db: D1Database, userId: number, upload: ParsedUpload): Promise<void> {
  if (upload.days.length === 0) return;
  const stmts: D1PreparedStatement[] = [];
  for (const day of upload.days) {
    stmts.push(db.prepare("DELETE FROM daily_usage WHERE user_id = ? AND day = ?").bind(userId, day));
  }
  const insert = db.prepare(
    `INSERT INTO daily_usage (user_id, day, app, model, input_tokens, output_tokens,
       cache_read_tokens, cache_creation_tokens, cost_micro)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  );
  for (const r of upload.rows) {
    stmts.push(
      insert.bind(userId, r.day, r.app, r.model, r.inputTokens, r.outputTokens, r.cacheReadTokens, r.cacheCreationTokens, r.costMicro),
    );
  }
  // batch 在一个事务里执行，失败会整体回滚
  await db.batch(stmts);
}
