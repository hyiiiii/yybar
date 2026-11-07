// 成就要自己领：解锁只记一行，点「领取」才发奖励，每个只发一次。用真实的迁移跑在 Node 自带的 SQLite 上。
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { beforeEach, describe, expect, it } from "vitest";
import { claimAchievement, readyCount, syncAchievements, unlockAchievement } from "../src/worker/achievements";
import { ACHIEVEMENTS } from "../src/shared/achievements";
import { fakeD1, migrate } from "./d1";

describe("achievements are claimed by hand", () => {
  let sqlite: DatabaseSync;
  let d1: D1Database;
  beforeEach(() => {
    sqlite = migrate(new DatabaseSync(":memory:"));
    sqlite.exec("INSERT INTO users (id, github_id, login) VALUES (1, 100, 'u1')");
    d1 = fakeD1(sqlite);
  });
  const paid = () => (sqlite.prepare("SELECT COALESCE(SUM(delta), 0) AS n FROM points_ledger WHERE user_id = 1 AND reason = 'achievement'").get() as { n: number }).n;

  it("unlocks without paying, then pays once when claimed", async () => {
    await syncAchievements(d1, 1);
    expect(await readyCount(d1, 1)).toBe(1); // 第一次登录
    expect(paid()).toBe(0);

    expect(await claimAchievement(d1, 1, "first_login")).toBe(500);
    expect(await claimAchievement(d1, 1, "first_login")).toBe(0); // 连点两下不会发两次
    expect(paid()).toBe(500);
    expect(await readyCount(d1, 1)).toBe(0);

    // 没解锁的领不了
    expect(await claimAchievement(d1, 1, "quads")).toBe(0);
    await unlockAchievement(d1, 1, "quads");
    expect(await readyCount(d1, 1)).toBe(1);
    expect(await claimAchievement(d1, 1, "quads")).toBe(100);
    expect(paid()).toBe(600);
  });

  it("unlocks the subscription and big-spender badges", async () => {
    sqlite.exec("INSERT INTO api_tokens (id, user_id, token_hash, label) VALUES (10, 1, 'h10', 'mac')");
    sqlite.exec(`INSERT INTO user_accounts (token_id, user_id, app, account, plan) VALUES
      (10, 1, 'claude', 'b1b1b1b1', 'max_20x'), (10, 1, 'codex', 'c1c1c1c1', 'pro'), (10, 1, 'codex', 'c2c2c2c2', 'free')`);
    sqlite.exec(`INSERT INTO daily_usage (user_id, day, app, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_micro)
      VALUES (1, '2026-10-01', 'codex', 'gpt-5', 11000000000, 0, 0, 0, 10000000000)`);
    await syncAchievements(d1, 1);
    const ids = (sqlite.prepare("SELECT id FROM user_achievements WHERE user_id = 1").all() as { id: string }[]).map((r) => r.id);
    expect(ids).toEqual(expect.arrayContaining(["claude_max", "gpt_pro", "tokens_10b", "spend_10k"]));
    expect(ids).not.toContain("claude_pro");
    expect(ids).not.toContain("gpt_plus");
  });

  it("pays $100 for everything except the first login", () => {
    expect(ACHIEVEMENTS.filter((a) => a.id !== "first_login").every((a) => a.reward === 100)).toBe(true);
    expect(ACHIEVEMENTS.find((a) => a.id === "first_login")!.reward).toBe(500);
  });

  it("treats achievements unlocked before the change as already claimed", () => {
    const old = migrate(new DatabaseSync(":memory:"), "0009_usage_apps.sql");
    old.exec("INSERT INTO users (id, github_id, login) VALUES (1, 100, 'u1')");
    old.exec("INSERT INTO user_achievements (user_id, id) VALUES (1, 'first_login')");
    old.exec(readFileSync("migrations/0010_achievement_claims.sql", "utf8"));
    const row = old.prepare("SELECT unlocked_at, claimed_at FROM user_achievements").get() as { unlocked_at: string; claimed_at: string };
    expect(row.claimed_at).toBe(row.unlocked_at);
  });
});
