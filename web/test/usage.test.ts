import { describe, expect, it } from "vitest";
import { parseUpload, UploadError } from "../src/worker/usage";
import { parseCostMicro, pointsFromMicro } from "../src/worker/util";

const entry = (over: Record<string, unknown> = {}) => ({
  app: "claude",
  model: "claude-opus",
  inputTokens: 10,
  outputTokens: 20,
  cacheReadTokens: 30,
  cacheCreationTokens: 40,
  costUSD: "1.5",
  ...over,
});

describe("parseCostMicro", () => {
  it("parses decimal strings to micro-dollars", () => {
    expect(parseCostMicro("1.5")).toBe(1_500_000);
    expect(parseCostMicro("0.0000005")).toBe(1);
    expect(parseCostMicro("0.0000004")).toBe(0);
    expect(parseCostMicro("41.72")).toBe(41_720_000);
    expect(parseCostMicro(3)).toBe(3_000_000);
  });
  it("rejects bad input", () => {
    for (const v of ["-1", "1e3", "abc", "", null, undefined, "1.2.3"]) expect(parseCostMicro(v)).toBeNull();
  });
  it("$1 = 1 chip, rounded down", () => {
    expect(pointsFromMicro(1_000_000)).toBe(1);
    expect(pointsFromMicro(999_999)).toBe(0);
    expect(pointsFromMicro(3_499_110_000)).toBe(3499);
  });
});

describe("parseUpload", () => {
  const today = "2026-10-17";
  it("accepts a valid upload and merges duplicate models", () => {
    const r = parseUpload({ days: [{ day: "2026-10-16", entries: [entry(), entry({ costUSD: "0.5" }), entry({ app: "codex", model: "gpt-5" })] }] }, today);
    expect(r.days).toEqual(["2026-10-16"]);
    expect(r.rows).toHaveLength(2);
    const claude = r.rows.find((x) => x.app === "claude")!;
    expect(claude.costMicro).toBe(2_000_000);
    expect(claude.inputTokens).toBe(20);
  });
  it("accepts today (UTC) but not tomorrow", () => {
    expect(parseUpload({ days: [{ day: today, entries: [] }] }, today).days).toEqual([today]);
    expect(() => parseUpload({ days: [{ day: "2026-10-18", entries: [] }] }, today)).toThrow(UploadError);
  });
  it("allows an empty day", () => {
    expect(parseUpload({ days: [{ day: "2026-10-16", entries: [] }] }, today).rows).toEqual([]);
  });
  const bad: [string, unknown][] = [
    ["no days", {}],
    ["bad date", { days: [{ day: "2026-02-30", entries: [] }] }],
    ["future", { days: [{ day: "2026-10-19", entries: [] }] }],
    ["duplicate day", { days: [{ day: "2026-10-16", entries: [] }, { day: "2026-10-16", entries: [] }] }],
    ["unknown app", { days: [{ day: "2026-10-16", entries: [entry({ app: "gemini" })] }] }],
    ["negative tokens", { days: [{ day: "2026-10-16", entries: [entry({ outputTokens: -1 })] }] }],
    ["float tokens", { days: [{ day: "2026-10-16", entries: [entry({ outputTokens: 1.5 })] }] }],
    ["cost cap", { days: [{ day: "2026-10-16", entries: [entry({ costUSD: "5000.01" })] }] }],
  ];
  for (const [name, body] of bad) {
    it(`rejects: ${name}`, () => expect(() => parseUpload(body, today)).toThrow(UploadError));
  }
});
