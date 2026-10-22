// 上传「每一天只收第一次」：用 Node 自带的 SQLite 跑真实的建表迁移，配一个最小的 D1 外壳。
import { readFileSync, readdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { beforeEach, describe, expect, it } from "vitest";
import { parseUpload, saveUpload, uploadedDays } from "../src/worker/usage";
import { pointsFromMicro } from "../src/worker/util";

function fakeD1(db: DatabaseSync): D1Database {
  const statement = (sql: string, args: unknown[] = []) => ({
    sql,
    args,
    bind: (...next: unknown[]) => statement(sql, next),
    all: async () => ({ results: db.prepare(sql).all(...(args as never[])) }),
    first: async () => db.prepare(sql).get(...(args as never[])) ?? null,
    run: async () => db.prepare(sql).run(...(args as never[])),
  });
  return {
    prepare: (sql: string) => statement(sql),
    batch: async (stmts: { sql: string; args: unknown[] }[]) => {
      db.exec("BEGIN");
      try {
        const out = stmts.map((s) => db.prepare(s.sql).run(...(s.args as never[])));
        db.exec("COMMIT");
        return out;
      } catch (e) {
        db.exec("ROLLBACK");
        throw e;
      }
    },
  } as unknown as D1Database;
}

const entry = (cost: string, model = "claude-opus") => ({
  app: "claude", model, inputTokens: 1, outputTokens: 2, cacheReadTokens: 3, cacheCreationTokens: 4, costUSD: cost,
});
const today = "2026-10-22";

describe("uploads count each day once", () => {
  let d1: D1Database;
  let sqlite: DatabaseSync;
  beforeEach(() => {
    sqlite = new DatabaseSync(":memory:");
    for (const f of readdirSync("migrations").sort()) sqlite.exec(readFileSync(`migrations/${f}`, "utf8"));
    sqlite.exec("INSERT INTO users (id, github_id, login) VALUES (1, 100, 'u1'), (2, 200, 'u2')");
    d1 = fakeD1(sqlite);
  });
  const cost = (user: number) =>
    pointsFromMicro((sqlite.prepare("SELECT COALESCE(SUM(cost_micro), 0) AS c FROM daily_usage WHERE user_id = ?").get(user) as { c: number }).c);

  it("keeps the first upload of a day and skips it afterwards", async () => {
    const first = parseUpload({ days: [{ day: "2026-10-20", entries: [entry("10.5")] }, { day: "2026-10-21", entries: [entry("5"), entry("2", "claude-sonnet")] }] }, today);
    expect(await saveUpload(d1, 1, first)).toEqual({ accepted: ["2026-10-20", "2026-10-21"], skipped: [] });
    expect(cost(1)).toBe(17); // $1 = 1 筹码，向下取整

    // 同样的天再传（哪怕数字变大）：整天跳过，筹码不变；新的一天照收
    const again = parseUpload({ days: [{ day: "2026-10-21", entries: [entry("99")] }, { day: "2026-10-22", entries: [entry("3")] }] }, today);
    expect(await saveUpload(d1, 1, again)).toEqual({ accepted: ["2026-10-22"], skipped: ["2026-10-21"] });
    expect(cost(1)).toBe(20);
    expect(await uploadedDays(d1, 1)).toEqual(["2026-10-20", "2026-10-21", "2026-10-22"]);

    // 别人的标记互不影响
    expect(await saveUpload(d1, 2, parseUpload({ days: [{ day: "2026-10-21", entries: [entry("1")] }] }, today))).toEqual({ accepted: ["2026-10-21"], skipped: [] });
    expect(cost(2)).toBe(1);
  });

  it("does not double count when the same day slips through twice in one batch run", async () => {
    // 两次上传都在「查已上传」之后才写：第二次的用量因为这一天已经标记而不写入
    const up = parseUpload({ days: [{ day: "2026-10-20", entries: [entry("4")] }] }, today);
    const a = saveUpload(d1, 1, up);
    const b = saveUpload(d1, 1, up);
    await Promise.all([a, b]);
    expect(cost(1)).toBe(4);
  });
});
