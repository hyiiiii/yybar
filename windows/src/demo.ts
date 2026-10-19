import type { Snapshot } from "./types";

/** 浏览器预览用的演示数据 */
export function demoSnapshot(): Snapshot {
  const now = Math.floor(Date.now() / 1000);
  const daily = Array.from({ length: 30 }, (_, i) => {
    const d = new Date((now - (29 - i) * 86400) * 1000);
    const wave = (n: number) => Math.max(0, Math.sin(i / 3 + n) * 4 + 4 + ((i * 7 + n * 13) % 5));
    return {
      day: `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`,
      codex: wave(1),
      claude: wave(2) * 1.6,
      grok: i % 4 === 0 ? wave(3) * 0.4 : 0,
    };
  });
  return {
    services: [
      {
        app: "codex", enabled: true, detected: true, account: "hyi@example.com",
        quota: {
          fiveHour: { usedPercent: 58, resetsAt: now + 2 * 3600 + 18 * 60, windowSeconds: 18000 },
          weekly: { usedPercent: 69, resetsAt: now + 4 * 86400, windowSeconds: 604800 },
          primary: null, primaryLabel: null, planType: "plus", fetchedAt: now - 32,
        },
        error: null, lastSuccessAt: now - 32, backoffUntil: null, inFlight: false,
      },
      {
        app: "claude", enabled: true, detected: true, account: "hyi@example.com",
        quota: {
          fiveHour: { usedPercent: 22, resetsAt: now + 3 * 3600 + 5 * 60, windowSeconds: null },
          weekly: { usedPercent: 36, resetsAt: now + 5 * 86400, windowSeconds: null },
          primary: null, primaryLabel: null, planType: "max", fetchedAt: now - 32,
        },
        error: null, lastSuccessAt: now - 32, backoffUntil: null, inFlight: false,
      },
      {
        app: "grok", enabled: true, detected: true, account: null,
        quota: {
          fiveHour: null, weekly: null,
          primary: { usedPercent: 88, resetsAt: now + 2 * 86400, windowSeconds: 604800 },
          primaryLabel: "本周", planType: null, fetchedAt: now - 32,
        },
        error: null, lastSuccessAt: now - 32, backoffUntil: null, inFlight: false,
      },
    ],
    usage: {
      today: { costUsd: 18.42, tokens: 23_400_000 },
      week: { costUsd: 96.1, tokens: 131_000_000 },
      month: { costUsd: 312.75, tokens: 402_000_000 },
      perApp: [
        { app: "codex", today: { costUsd: 6.3, tokens: 9_100_000 }, week: { costUsd: 31.2, tokens: 0 }, month: { costUsd: 0, tokens: 0 } },
        { app: "claude", today: { costUsd: 11.9, tokens: 14_000_000 }, week: { costUsd: 62.5, tokens: 0 }, month: { costUsd: 0, tokens: 0 } },
        { app: "grok", today: { costUsd: 0.22, tokens: 300_000 }, week: { costUsd: 2.4, tokens: 0 }, month: { costUsd: 0, tokens: 0 } },
      ],
      daily,
      scannedAt: now - 20,
      scanning: false,
      filesScanned: 418,
    },
    settings: {
      showCodex: true, showClaude: true, showGrok: true, showPill: true, pillPosition: null,
      quotaIntervalSecs: 120, scanWsl: true, resetAsClock: false,
    },
  };
}
