// 个人主页 @ 后面的订阅：每台设备整份替换，多台设备按账号摘要去重，撤销的令牌和 30 天没传的设备不算。
import { DatabaseSync } from "node:sqlite";
import { beforeEach, describe, expect, it } from "vitest";
import { fakeD1, migrate } from "./d1";
import { AccountsError, parseAccounts, plansOf, saveAccounts } from "../src/worker/accounts";

const acct = (app: string, account: string, plan: string) => ({ app, account, plan });

describe("account plans", () => {
  let d1: D1Database;
  let sqlite: DatabaseSync;
  beforeEach(() => {
    sqlite = migrate(new DatabaseSync(":memory:"));
    sqlite.exec("INSERT INTO users (id, github_id, login) VALUES (1, 100, 'u1'), (2, 200, 'u2')");
    sqlite.exec("INSERT INTO api_tokens (id, user_id, token_hash, label) VALUES (10, 1, 'h10', 'mac'), (11, 1, 'h11', 'win'), (20, 2, 'h20', 'mac')");
    d1 = fakeD1(sqlite);
  });

  it("validates uploads and drops duplicates", () => {
    expect(parseAccounts({ accounts: [acct("codex", "aaaaaaaa", "  pro "), acct("codex", "aaaaaaaa", "plus")] })).toEqual([
      { app: "codex", account: "aaaaaaaa", plan: "pro" },
    ]);
    expect(() => parseAccounts({ accounts: [acct("cursor", "aaaaaaaa", "pro")] })).toThrow(AccountsError);
    expect(() => parseAccounts({ accounts: [acct("codex", "me@example.com", "pro")] })).toThrow(AccountsError);
    expect(() => parseAccounts({ accounts: [acct("codex", "aaaaaaaa", "<b>pro</b>")] })).toThrow(AccountsError);
    expect(() => parseAccounts({ accounts: [acct("codex", "aaaaaaaa", "")] })).toThrow(AccountsError);
    expect(() => parseAccounts({})).toThrow(AccountsError);
  });

  it("counts accounts per plan, de-duplicating across devices", async () => {
    await saveAccounts(d1, 1, 10, parseAccounts({ accounts: [
      acct("codex", "c1c1c1c1", "pro"), acct("codex", "c2c2c2c2", "pro"), acct("claude", "b1b1b1b1", "max"),
      acct("gemini", "e1e1e1e1", "Google AI Pro"),
    ] }));
    // 另一台设备也登着同一个 Codex 账号，再加一个 Plus
    await saveAccounts(d1, 1, 11, parseAccounts({ accounts: [acct("codex", "c1c1c1c1", "pro"), acct("codex", "c3c3c3c3", "plus")] }));
    await saveAccounts(d1, 2, 20, parseAccounts({ accounts: [acct("codex", "c1c1c1c1", "plus")] }));
    expect(await plansOf(d1, 1)).toEqual([
      { app: "codex", plan: "pro", count: 2 },
      { app: "codex", plan: "plus", count: 1 },
      { app: "claude", plan: "max", count: 1 },
      { app: "gemini", plan: "Google AI Pro", count: 1 },
    ]);
    expect(await plansOf(d1, 2)).toEqual([{ app: "codex", plan: "plus", count: 1 }]);
  });

  it("replaces a device's list, ignores revoked tokens and stale devices", async () => {
    await saveAccounts(d1, 1, 10, parseAccounts({ accounts: [acct("codex", "c1c1c1c1", "plus"), acct("claude", "b1b1b1b1", "pro")] }));
    await saveAccounts(d1, 1, 10, parseAccounts({ accounts: [acct("codex", "c1c1c1c1", "pro")] }));
    expect(await plansOf(d1, 1)).toEqual([{ app: "codex", plan: "pro", count: 1 }]);

    await saveAccounts(d1, 1, 11, parseAccounts({ accounts: [acct("grok", "a1a1a1a1", "SuperGrok")] }));
    sqlite.exec("UPDATE api_tokens SET revoked_at = '2026-10-01T00:00:00.000Z' WHERE id = 11");
    expect(await plansOf(d1, 1)).toEqual([{ app: "codex", plan: "pro", count: 1 }]);

    // 同一个账号两台设备传的套餐不一样：取最近一次
    sqlite.exec("UPDATE api_tokens SET revoked_at = NULL WHERE id = 11");
    await saveAccounts(d1, 1, 11, parseAccounts({ accounts: [acct("codex", "c1c1c1c1", "plus")] }));
    sqlite.exec("UPDATE user_accounts SET updated_at = '2026-10-27T00:00:00.000Z' WHERE token_id = 10");
    sqlite.exec("UPDATE user_accounts SET updated_at = '2026-10-28T00:00:00.000Z' WHERE token_id = 11");
    const now = new Date("2026-10-28T12:00:00Z");
    expect(await plansOf(d1, 1, now)).toEqual([{ app: "codex", plan: "plus", count: 1 }]);

    // 30 天以后两台都没再传：一个都不算
    expect(await plansOf(d1, 1, new Date("2026-12-01T00:00:00Z"))).toEqual([]);
  });
});
