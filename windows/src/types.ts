// 与 src-tauri/src/core/model.rs 的序列化结构一一对应

export type AppId = "codex" | "claude" | "grok";

export interface QuotaWindow {
  usedPercent: number;
  resetsAt: number | null;
  windowSeconds: number | null;
}

export interface QuotaSnapshot {
  fiveHour: QuotaWindow | null;
  weekly: QuotaWindow | null;
  primary: QuotaWindow | null;
  primaryLabel: string | null;
  planType: string | null;
  fetchedAt: number;
}

export interface ServiceView {
  app: AppId;
  enabled: boolean;
  detected: boolean;
  account: string | null;
  quota: QuotaSnapshot | null;
  error: string | null;
  lastSuccessAt: number | null;
  backoffUntil: number | null;
  inFlight: boolean;
}

export interface PeriodSummary {
  costUsd: number;
  tokens: number;
}

export interface AppUsage {
  app: AppId;
  today: PeriodSummary;
  week: PeriodSummary;
  month: PeriodSummary;
}

export interface DailyPoint {
  day: string;
  codex: number;
  claude: number;
  grok: number;
}

export interface UsageSummary {
  today: PeriodSummary;
  week: PeriodSummary;
  month: PeriodSummary;
  perApp: AppUsage[];
  daily: DailyPoint[];
  scannedAt: number | null;
  scanning: boolean;
  filesScanned: number;
}

export interface Settings {
  showCodex: boolean;
  showClaude: boolean;
  showGrok: boolean;
  showPill: boolean;
  pillPosition: [number, number] | null;
  quotaIntervalSecs: number;
  scanWsl: boolean;
  resetAsClock: boolean;
}

export interface Snapshot {
  services: ServiceView[];
  usage: UsageSummary;
  settings: Settings;
}
