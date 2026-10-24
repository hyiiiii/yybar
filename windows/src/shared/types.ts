// 与后台（src-tauri/core、src-tauri/src/app_state.rs）序列化结构一一对应，字段为 camelCase。

export type UsageApp = "codex" | "claude" | "grok" | "agy";
export const ALL_APPS: UsageApp[] = ["codex", "claude", "grok", "agy"];

export interface QuotaWindow {
  usedPercent: number;
  resetsAt?: number | null;
  windowSeconds?: number | null;
}

export interface QuotaPool {
  label: string;
  fiveHour?: QuotaWindow | null;
  weekly?: QuotaWindow | null;
}

export interface QuotaSnapshot {
  app: UsageApp;
  fiveHour?: QuotaWindow | null;
  weekly?: QuotaWindow | null;
  weeklyOpus?: QuotaWindow | null;
  weeklySonnet?: QuotaWindow | null;
  planType?: string | null;
  fetchedAt: number;
  primary?: QuotaWindow | null;
  primaryLabel?: string | null;
  pools?: QuotaPool[] | null;
}

export interface RefreshState {
  lastSuccessAt: number | null;
  lastAttemptAt: number | null;
  backoffUntil: number | null;
  lastError: string | null;
  inFlight: boolean;
  source: "api" | "cache" | "agyCli" | null;
}

export type Indicator = "none" | "minor" | "major" | "critical" | "maintenance" | "unknown";

export interface ServiceStatus {
  indicator: Indicator;
  description: string | null;
  updatedAt: number | null;
  fetchedAt: number;
}

export interface SubscriptionRenewal {
  date: number;
  estimated: boolean;
  basis: number;
}

export interface ServiceView {
  app: UsageApp;
  enabled: boolean;
  detected: boolean;
  removed: boolean;
  email: string | null;
  plan: string | null;
  quota: QuotaSnapshot | null;
  refresh: RefreshState;
  status: ServiceStatus | null;
  renewal: SubscriptionRenewal | null;
  source: string | null;
  /** 今日额度变化里的 key（周窗口加 #wk）；Antigravity 两个池子各一个。 */
  historyKeys: string[];
}

export type MenuBarWindow = "fiveHour" | "weekly" | "both";
export type ResetTimeDisplay = "relative" | "absolute";
export type AppLanguage = "system" | "zh" | "en";
export type IntervalChoice = "m1" | "m2" | "m3" | "m5" | "m10";

export interface Settings {
  showCodex: boolean;
  showClaude: boolean;
  showGrok: boolean;
  showAgy: boolean;
  removedLocalAccounts: Record<string, string>;
  menuBarShowCodex: boolean;
  menuBarShowClaude: boolean;
  menuBarShowGrok: boolean;
  menuBarShowAgy: boolean;
  menuBarWindow: MenuBarWindow;
  menuBarBreatheWhenActive: boolean;
  menuBarHoldColorWhileWaiting: boolean;
  floatingEnabled: boolean;
  floatingShowCodex: boolean;
  floatingShowClaude: boolean;
  floatingShowGrok: boolean;
  floatingShowAgy: boolean;
  floatingPosition: [number, number] | null;
  quotaInterval: IntervalChoice;
  usageInterval: IntervalChoice;
  scanWsl: boolean;
  resetTimeDisplay: ResetTimeDisplay;
  showServiceStatus: boolean;
  appLanguage: AppLanguage;
  didCompleteOnboarding: boolean;
}

export interface HistorySample {
  accountKey: string;
  app: UsageApp;
  sampledAt: number;
  remainingPercent: number;
  resetsAt: number | null;
}

export interface ChangeEvent {
  id: string;
  accountKey: string;
  app: UsageApp;
  sampledAt: number;
  beforeRemainingPercent: number;
  afterRemainingPercent: number;
  deltaPercent: number;
  resetsAt: number | null;
}

export interface QuotaHistory {
  day: string;
  lastSamples: Record<string, HistorySample>;
  events: ChangeEvent[];
  firstSampledAt: Record<string, number>;
}

export interface ModelPrice {
  input: number;
  output: number;
  cacheRead: number;
  cacheCreation: number;
}

export interface StateSnapshot {
  services: ServiceView[];
  settings: Settings;
  chinese: boolean;
  activity: { active: UsageApp[]; waiting: UsageApp[] };
  history: QuotaHistory;
  usage: { version: number; lastScanAt: number | null; scanning: boolean };
  prices: { builtin: Record<string, ModelPrice>; custom: Record<string, ModelPrice> };
  repricing: boolean;
  autostart: boolean;
  agyInstalled: boolean;
  version: string;
}

export interface UsageBucket {
  app: UsageApp;
  model: string;
  /** 本地日期 YYYY-MM-DD */
  day: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
  costUSD: number;
}

export interface UsagePayload {
  version: number;
  buckets: UsageBucket[];
}

/** 设置里「启用 / 托盘 / 悬浮窗」三列的键名。 */
export const SETTING_KEYS: Record<UsageApp, { enabled: keyof Settings; tray: keyof Settings; floating: keyof Settings }> = {
  codex: { enabled: "showCodex", tray: "menuBarShowCodex", floating: "floatingShowCodex" },
  claude: { enabled: "showClaude", tray: "menuBarShowClaude", floating: "floatingShowClaude" },
  grok: { enabled: "showGrok", tray: "menuBarShowGrok", floating: "floatingShowGrok" },
  agy: { enabled: "showAgy", tray: "menuBarShowAgy", floating: "floatingShowAgy" },
};

export const isEnabled = (s: Settings, app: UsageApp) => Boolean(s[SETTING_KEYS[app].enabled]);
export const trayShows = (s: Settings, app: UsageApp) => isEnabled(s, app) && Boolean(s[SETTING_KEYS[app].tray]);
export const floatingShows = (s: Settings, app: UsageApp) => isEnabled(s, app) && Boolean(s[SETTING_KEYS[app].floating]);
