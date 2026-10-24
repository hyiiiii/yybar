// 浏览器里直接打开页面（`npm run dev`）时的演示数据，只用来调样式。

import { dayString } from "./format";
import type { QuotaSnapshot, RefreshState, ServiceView, StateSnapshot, UsageApp, UsageBucket, UsagePayload } from "./types";

const now = () => Math.floor(Date.now() / 1000);

const refresh = (ago: number): RefreshState => ({
  lastSuccessAt: now() - ago,
  lastAttemptAt: now() - ago,
  backoffUntil: null,
  lastError: null,
  inFlight: false,
  source: "api",
});

function snap(app: UsageApp, five: number | null, week: number | null): QuotaSnapshot {
  const t = now();
  return {
    app,
    fiveHour: five == null ? null : { usedPercent: five, resetsAt: t + 2 * 3600 + 1200, windowSeconds: 18000 },
    weekly: week == null ? null : { usedPercent: week, resetsAt: t + 3 * 86400 + 7200, windowSeconds: 604800 },
    fetchedAt: t - 40,
  };
}

export function demoState(): StateSnapshot {
  const t = now();
  const grok: QuotaSnapshot = {
    app: "grok",
    fetchedAt: t - 60,
    primary: { usedPercent: 37, resetsAt: t + 4 * 86400, windowSeconds: 604800 },
    weekly: { usedPercent: 37, resetsAt: t + 4 * 86400, windowSeconds: 604800 },
    primaryLabel: "WEEK · 本周",
  };
  const agy: QuotaSnapshot = {
    ...snap("agy", 12, 41),
    pools: [
      { label: "Gemini", fiveHour: { usedPercent: 12, resetsAt: t + 9000, windowSeconds: 18000 }, weekly: { usedPercent: 30, resetsAt: t + 400000, windowSeconds: 604800 } },
      { label: "Claude·GPT", fiveHour: { usedPercent: 3, resetsAt: t + 9000, windowSeconds: 18000 }, weekly: { usedPercent: 41, resetsAt: t + 400000, windowSeconds: 604800 } },
    ],
  };
  const service = (app: UsageApp, quota: QuotaSnapshot, email: string, plan: string, extra: Partial<ServiceView> = {}): ServiceView => ({
    app,
    enabled: true,
    detected: true,
    removed: false,
    email,
    plan,
    quota,
    refresh: refresh(45),
    status: { indicator: "none", description: "All systems normal", updatedAt: t - 3600, fetchedAt: t - 60 },
    renewal: null,
    source: null,
    historyKeys: app === "agy" ? ["agy:gemini", "agy:3p"] : [`${app}:primary`],
    ...extra,
  });
  const historyEvents = [
    { at: 9 * 3600, before: 100, after: 82 },
    { at: 11 * 3600, before: 82, after: 61 },
    { at: 14 * 3600, before: 61, after: 42 },
  ];
  const dayStart = new Date();
  dayStart.setHours(0, 0, 0, 0);
  const ds = Math.floor(dayStart.getTime() / 1000);
  return {
    services: [
      service("codex", snap("codex", 58, 31), "me@example.com", "pro", {
        renewal: { date: t + 2 * 86400, estimated: false, basis: t + 2 * 86400 },
      }),
      service("claude", snap("claude", 85, 64), "me@example.com", "max"),
      service("grok", grok, "me@example.com", "SuperGrok"),
      service("agy", agy, "me@gmail.com", ""),
    ],
    settings: {
      showCodex: true,
      showClaude: true,
      showGrok: true,
      showAgy: true,
      removedLocalAccounts: {},
      menuBarShowCodex: true,
      menuBarShowClaude: true,
      menuBarShowGrok: true,
      menuBarShowAgy: true,
      menuBarWindow: "fiveHour",
      menuBarBreatheWhenActive: true,
      menuBarHoldColorWhileWaiting: true,
      floatingEnabled: true,
      floatingShowCodex: true,
      floatingShowClaude: true,
      floatingShowGrok: true,
      floatingShowAgy: false,
      floatingPosition: null,
      quotaInterval: "m2",
      usageInterval: "m2",
      scanWsl: false,
      resetTimeDisplay: "relative",
      showServiceStatus: true,
      appLanguage: "system",
      didCompleteOnboarding: true,
    },
    chinese: navigator.language.toLowerCase().startsWith("zh"),
    activity: { active: ["claude"], waiting: [] },
    history: {
      day: dayString(new Date()),
      lastSamples: { "codex:primary": { accountKey: "codex:primary", app: "codex", sampledAt: t - 60, remainingPercent: 42, resetsAt: t + 7200 } },
      events: historyEvents.map((e, i) => ({
        id: `e${i}`,
        accountKey: "codex:primary",
        app: "codex",
        sampledAt: ds + e.at,
        beforeRemainingPercent: e.before,
        afterRemainingPercent: e.after,
        deltaPercent: e.after - e.before,
        resetsAt: t + 7200,
      })),
      firstSampledAt: { "codex:primary": ds + 7 * 3600, "claude:primary": ds + 7 * 3600 },
    },
    usage: { version: 1, lastScanAt: t - 30, scanning: false },
    prices: {
      builtin: {
        "gpt-5.5": { input: 5, output: 30, cacheRead: 0.5, cacheCreation: 0 },
        "claude-opus-4-8": { input: 5, output: 25, cacheRead: 0.5, cacheCreation: 6.25 },
        "claude-sonnet-5-5": { input: 2, output: 10, cacheRead: 0.1, cacheCreation: 2.5 },
      },
      custom: {},
    },
    repricing: false,
    autostart: true,
    agyInstalled: true,
    version: "0.2.0",
  };
}

export function demoUsage(): UsagePayload {
  const buckets: UsageBucket[] = [];
  let seed = 7;
  const rand = () => {
    seed = (seed * 9301 + 49297) % 233280;
    return seed / 233280;
  };
  const models: [UsageApp, string, number][] = [
    ["codex", "gpt-5.5", 5],
    ["claude", "claude-opus-4-8", 5],
    ["claude", "claude-sonnet-5-5", 2],
    ["grok", "grok-code-fast-1", 0.4],
    ["agy", "gemini-3.8-flash", 0.75],
  ];
  for (let i = 0; i < 300; i++) {
    const d = new Date();
    d.setDate(d.getDate() - i);
    if (rand() < 0.2) continue;
    for (const [app, model, price] of models) {
      if (rand() < 0.35) continue;
      const input = Math.round(rand() * 2_000_000);
      const output = Math.round(rand() * 200_000);
      const cacheRead = Math.round(rand() * 20_000_000);
      buckets.push({
        app,
        model,
        day: dayString(d),
        inputTokens: input,
        outputTokens: output,
        cacheReadTokens: cacheRead,
        cacheCreationTokens: app === "claude" ? Math.round(rand() * 500_000) : 0,
        costUSD: (input * price + output * price * 5 + cacheRead * price * 0.1) / 1_000_000,
      });
    }
  }
  return { version: 1, buckets };
}
