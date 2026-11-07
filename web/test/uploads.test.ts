// 上传「每一天的每个服务记一份，量变多了才换」：用 Node 自带的 SQLite 跑真实的建表迁移，配一个最小的 D1 外壳。
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { beforeEach, describe, expect, it } from "vitest";
import { fakeD1, migrate } from "./d1";
import { loadPrices, parseUpload, saveUpload, uploadedPairs, uploadHistory } from "../src/worker/usage";
import { pointsFromMicro } from "../src/worker/util";
import { serverCostMicro } from "../src/shared/pricing";

// 花费由服务端按价格表算：测试用的 test-* 模型输入 $1 / 百万 token，所以 entry("10.5") 是 1050 万输入 token、正好 $10.5
const entry = (cost: string, model = "test-opus", app = "claude", answers?: number) => ({
  app, model, inputTokens: Math.round(Number(cost) * 1e6), outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: cost, ...(answers === undefined ? {} : { answers }),
});
const TEST_PRICE = "INSERT INTO model_prices (model, vendor, input, output, cache_read, cache_write) VALUES ('test-*', 'anthropic', 1, 0, 0, 0)";
const today = "2026-10-22";

describe("uploads count each day once (the biggest copy)", () => {
  let d1: D1Database;
  let sqlite: DatabaseSync;
  beforeEach(() => {
    sqlite = migrate(new DatabaseSync(":memory:"));
    sqlite.exec(TEST_PRICE);
    sqlite.exec("INSERT INTO users (id, github_id, login) VALUES (1, 100, 'u1'), (2, 200, 'u2')");
    d1 = fakeD1(sqlite);
  });
  const cost = (user: number) =>
    pointsFromMicro((sqlite.prepare("SELECT COALESCE(SUM(cost_micro), 0) AS c FROM daily_usage WHERE user_id = ?").get(user) as { c: number }).c);

  it("keeps the first upload of a day and skips it afterwards", async () => {
    const first = parseUpload({ days: [{ day: "2026-10-20", entries: [entry("10.5")] }, { day: "2026-10-21", entries: [entry("5"), entry("2", "test-sonnet")] }] }, today);
    expect(await saveUpload(d1, 1, first)).toEqual({ accepted: ["2026-10-20", "2026-10-21"], skipped: [] });
    expect(cost(1)).toBe(17); // $1 = 1 筹码，向下取整

    // 同样的天再传、量没变多：整天跳过，筹码不变；新的一天照收
    const again = parseUpload({ days: [{ day: "2026-10-21", entries: [entry("6")] }, { day: "2026-10-22", entries: [entry("3")] }] }, today);
    expect(await saveUpload(d1, 1, again)).toEqual({ accepted: ["2026-10-22"], skipped: ["2026-10-21"] });
    expect(cost(1)).toBe(20);
    expect((await uploadedPairs(d1, 1)).map((p) => p.day)).toEqual(["2026-10-20", "2026-10-21", "2026-10-22"]);

    // 别人的标记互不影响
    expect(await saveUpload(d1, 2, parseUpload({ days: [{ day: "2026-10-21", entries: [entry("1")] }] }, today))).toEqual({ accepted: ["2026-10-21"], skipped: [] });
    expect(cost(2)).toBe(1);
  });

  it("locks each service per day: a newly supported service can still fill in an uploaded day, once", async () => {
    await saveUpload(d1, 1, parseUpload({ days: [{ day: "2026-10-20", entries: [entry("10")] }] }, today));
    // 同一天：Claude 已经传过、量没变 → 跳过；Antigravity、Gemini（只有回答次数）是新的 → 收下
    const more = parseUpload({ days: [{ day: "2026-10-20", entries: [entry("10"), entry("3", "test-gem", "agy"), entry("0", "gemini-3-pro", "gemini", 12)] }] }, today);
    expect(await saveUpload(d1, 1, more)).toEqual({ accepted: ["2026-10-20"], skipped: [] });
    expect(cost(1)).toBe(13);
    const answers = sqlite.prepare("SELECT SUM(answers) AS a FROM daily_usage WHERE user_id = 1 AND app = 'gemini'").get() as { a: number };
    expect(answers.a).toBe(12);
    // 再传一遍：这一天三个服务都传过了 → 整天跳过
    expect(await saveUpload(d1, 1, more)).toEqual({ accepted: [], skipped: ["2026-10-20"] });
    expect(cost(1)).toBe(13);
    expect((await uploadedPairs(d1, 1)).map((p) => p.app).sort()).toEqual(["agy", "claude", "gemini"]);
  });

  it("lists the last 10 uploaded days without counting a day once per service", async () => {
    const days = Array.from({ length: 12 }, (_, i) => ({
      day: `2026-10-${String(i + 1).padStart(2, "0")}`,
      entries: [entry("1"), entry("2", "test-codex", "codex"), entry("0", "gemini", "gemini", 3)],
    }));
    await saveUpload(d1, 1, parseUpload({ days }, today));
    const history = await uploadHistory(d1, 1);
    expect(history.map((h) => h.day)).toEqual(days.slice(2).reverse().map((d) => d.day));
    // 每天 300 万 token、共 $3；三个服务各有一条上传标记，不会把它再乘三
    expect(history[0]).toMatchObject({ day: "2026-10-12", tokens: 3_000_000, cost_micro: 3_000_000 });
  });

  it("replaces a day when the app later finds more usage for it, never with less", async () => {
    await saveUpload(d1, 1, parseUpload({ days: [{ day: "2026-10-20", entries: [entry("5", "test-codex", "codex")] }] }, today));
    expect(cost(1)).toBe(5);
    // 新加了一个 Codex 目录：这一天多了另一个账号的会话（另一个模型），整份换掉，不叠加
    const more = parseUpload({ days: [{ day: "2026-10-20", entries: [entry("5", "test-codex", "codex"), entry("20", "test-codex-pro", "codex")] }] }, today);
    expect(await saveUpload(d1, 1, more)).toEqual({ accepted: ["2026-10-20"], skipped: [] });
    expect(cost(1)).toBe(25);
    // 另一台电脑只有其中一部分：量更少，跳过
    expect(await saveUpload(d1, 1, parseUpload({ days: [{ day: "2026-10-20", entries: [entry("5", "test-codex", "codex")] }] }, today))).toEqual({ accepted: [], skipped: ["2026-10-20"] });
    expect(cost(1)).toBe(25);
    const models = sqlite.prepare("SELECT model FROM daily_usage WHERE user_id = 1 ORDER BY model").all() as { model: string }[];
    expect(models.map((m) => m.model)).toEqual(["test-codex", "test-codex-pro"]);
    expect(await uploadedPairs(d1, 1)).toEqual([{ day: "2026-10-20", app: "codex", total: 25_000_000, costMicro: 25_000_000 }]);
  });

  it("backfills the totals of days uploaded before totals were kept", () => {
    const old = migrate(new DatabaseSync(":memory:"), "0014_account_devices.sql");
    old.exec("INSERT INTO users (id, github_id, login) VALUES (1, 100, 'u1')");
    old.exec(`INSERT INTO daily_usage (user_id, day, app, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_micro, answers)
      VALUES (1, '2026-10-20', 'codex', 'a', 10, 20, 30, 40, 0, 0), (1, '2026-10-20', 'codex', 'b', 1, 0, 0, 0, 0, 0), (1, '2026-10-20', 'gemini', 'g', 0, 0, 0, 0, 0, 7)`);
    old.exec("INSERT INTO usage_uploads (user_id, day, app) VALUES (1, '2026-10-20', 'codex'), (1, '2026-10-20', 'gemini'), (1, '2026-10-20', 'grok')");
    old.exec(readFileSync("migrations/0015_upload_totals.sql", "utf8"));
    const rows = old.prepare("SELECT app, total FROM usage_uploads ORDER BY app").all() as { app: string; total: number }[];
    expect(rows).toEqual([{ app: "codex", total: 101 }, { app: "gemini", total: 7 }, { app: "grok", total: 0 }]);
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

describe("costs come from the server's price table", () => {
  let d1: D1Database;
  let sqlite: DatabaseSync;
  beforeEach(() => {
    sqlite = migrate(new DatabaseSync(":memory:"));
    sqlite.exec("INSERT INTO users (id, github_id, login) VALUES (1, 100, 'u1')");
    d1 = fakeD1(sqlite);
  });
  const M = 1_000_000;
  const use = (app: string, model: string, costUSD: string, t = M) => ({ app, model, inputTokens: t, outputTokens: t, cacheReadTokens: t, cacheCreationTokens: t, costUSD });
  const rows = () => sqlite.prepare("SELECT app, model, cost_micro AS cost, client_cost_micro AS client FROM daily_usage ORDER BY app, model").all() as { app: string; model: string; cost: number; client: number }[];

  it("prices tokens with the table and ignores what the app says it cost", async () => {
    // App 里把 Opus 4.5 改成天价也没用：每样 100 万 token 按表是 $5 + $25 + $0.5 + $6.25
    await saveUpload(d1, 1, parseUpload({ days: [{ day: "2026-10-20", entries: [use("claude", "claude-opus-4-5-20251101", "999")] }] }, today));
    expect(rows()).toEqual([{ app: "claude", model: "claude-opus-4-5-20251101", cost: 36_750_000, client: 999 * M }]);
  });

  it("takes Grok's billed cost but never more than the listed price; Grok Bot, Gemini and unknown models cost nothing", async () => {
    const up = parseUpload(
      {
        days: [
          {
            day: "2026-10-20",
            entries: [
              use("grok", "grok-4.7-build", "5"), // 实际扣费 $5，没到上限
              use("grok", "xai/grok-4.6", "50"), // 超过上限 $3 + $15 + $0.75 → 封顶
              use("grokBot", "grok-bot-default", "7"),
              use("codex", "brand-new-model", "8"),
            ],
          },
        ],
      },
      today,
    );
    await saveUpload(d1, 1, up);
    expect(rows().map((r) => [r.model, r.cost])).toEqual([
      ["brand-new-model", 0],
      ["grok-4.7-build", 5 * M],
      ["xai/grok-4.6", 18_750_000],
      ["grok-bot-default", 0],
    ]);
  });

  it("rejects a day whose priced cost is absurd even if the app reports $0", async () => {
    const huge = parseUpload({ days: [{ day: "2026-10-20", entries: [use("claude", "claude-opus-4-1", "0", 100 * M)] }] }, today);
    await expect(saveUpload(d1, 1, huge)).rejects.toThrow(/单日花费/);
  });

  it("recomputes old uploads the same way when the price table is added", async () => {
    // 迁移前按 App 报的花费存的几行，跑完 0012 后应该和按价格表现算的一样
    const old = migrate(new DatabaseSync(":memory:"), "0011_table_online.sql");
    old.exec("INSERT INTO users (id, github_id, login) VALUES (1, 100, 'u1')");
    const samples = [
      ["codex", "gpt-5.6-sol", 81_419_841, 7_435_975, 1_864_493_696, 0, 1_220_196_341],
      ["claude", "claude-opus-5-5", 808_214, 5_542_637, 1_742_776_655, 39_137_215, 669_425_555],
      ["grok", "grok-4.7-build", 17_443_126, 1_109_552, 164_550_272, 0, 56_840_000],
      ["grok", "xai/grok-4.6", 87_992, 8_210, 982_976, 0, 720_000],
      ["grokBot", "grok-bot-default", 75_155_455, 0, 0, 0, 0],
      ["claude", "kimi-k2.6", 384_372, 3_349, 0, 0, 0],
      ["agy", "claude-opus-4-6", 15_975, 60, 0, 0, 81_000],
    ] as const;
    for (const [app, model, i, o, cr, cw, c] of samples) {
      old.prepare(
        "INSERT INTO daily_usage (user_id, day, app, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_micro) VALUES (1, '2026-10-20', ?, ?, ?, ?, ?, ?, ?)",
      ).run(app, model, i, o, cr, cw, c);
    }
    old.exec(readFileSync("migrations/0012_model_prices.sql", "utf8"));
    const prices = await loadPrices(fakeD1(old));
    const after = old.prepare("SELECT app, model, input_tokens AS i, output_tokens AS o, cache_read_tokens AS cr, cache_creation_tokens AS cw, cost_micro AS cost, client_cost_micro AS client FROM daily_usage").all() as Record<string, number & string>[];
    expect(after).toHaveLength(samples.length);
    for (const r of after) {
      const expected = serverCostMicro({ app: r.app, model: r.model, inputTokens: r.i, outputTokens: r.o, cacheReadTokens: r.cr, cacheCreationTokens: r.cw, clientCostMicro: r.client }, prices);
      expect([r.model, r.cost]).toEqual([r.model, expected]);
    }
    // gpt-5.6-sol 和 App 算的一样（App 逐条算再加，差不到 1 微美元）；Grok 按实际扣费；Grok Bot、表里没有的模型是 0
    const by = Object.fromEntries(after.map((r) => [r.model, r.cost]));
    expect(Math.abs(by["gpt-5.6-sol"] - 1_220_196_341)).toBeLessThanOrEqual(1);
    expect(by["grok-4.7-build"]).toBe(56_840_000);
    expect(by["grok-bot-default"]).toBe(0);
    expect(by["kimi-k2.6"]).toBe(0);
  });
});
