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
  const state: StateSnapshot = {
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
      webAutoUpload: false,
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
    others: [
      {
        id: "claude:work@example.com",
        provider: "claude",
        app: "claude",
        name: "work",
        alias: "",
        email: "work@example.com",
        plan: "pro",
        enabled: true,
        showInTray: false,
        showInFloating: false,
        quota: snap("claude", 64, 22),
        refresh: refresh(95),
        renewal: { date: t + 9 * 86400, estimated: true, basis: t - 21 * 86400 },
        historyKeys: ["other:claude:work@example.com"],
        switchable: true,
      },
      {
        id: "codex:acc-2:user-2",
        provider: "codex",
        app: "codex",
        name: "备用",
        alias: "备用",
        email: "spare@example.com",
        plan: "plus",
        enabled: true,
        showInTray: true,
        showInFloating: true,
        quota: snap("codex", 8, 51),
        refresh: refresh(70),
        renewal: null,
        historyKeys: ["other:codex:acc-2:user-2"],
        switchable: true,
      },
    ],
    switching: null,
    switchNotice: null,
    clis: { codex: true, claude: true, grok: false, agy: true },
    web: {
      site: "https://yybar-web.hyi030618.workers.dev",
      connected: true,
      profile: { login: "hyiiiii", name: "hyi", avatarUrl: null },
      phase: "idle",
      message: null,
      messageIsError: false,
      pending: { days: ["2026-10-24", "2026-10-25"], pairs: [], costUsd: 37.42, chips: 37 },
      uploadedDays: 31,
      lastUploadAt: t - 26 * 3600,
      usedManualToday: false,
    },
  };
  // 地址带 ?empty：模拟本机什么都没登录、也没添加账号（看空状态）
  if (new URLSearchParams(location.search).has("empty")) {
    state.services = state.services.map((x) => ({ ...x, detected: false, email: null, plan: null, quota: null }));
    state.others = [];
  }
  return state;
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
