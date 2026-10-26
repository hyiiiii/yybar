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
  /** 每天 12:00 自动上传用量到 yybar 网站 */
  webAutoUpload: boolean;
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

/** 能添加其他账号的服务（Google 一个账号对应 Gemini、Antigravity 两个池，显示在 Antigravity 下）。 */
export type Provider = "codex" | "claude" | "grok" | "google";

/** 设置 · 服务里「添加账号…」加进来的账号（后台 accounts.rs 的 OtherAccountView）。 */
export interface OtherAccountView {
  id: string;
  provider: Provider;
  app: UsageApp;
  /** 别名 > 邮箱 @ 前 > 服务名 */
  name: string;
  alias: string;
  email: string | null;
  plan: string | null;
  enabled: boolean;
  showInTray: boolean;
  showInFloating: boolean;
  quota: QuotaSnapshot | null;
  refresh: RefreshState;
  renewal: SubscriptionRenewal | null;
  historyKeys: string[];
  switchable: boolean;
}

export type LoginPhase =
  | { kind: "starting" }
  | { kind: "waitingForBrowser" }
  | { kind: "needsCode" }
  | { kind: "exited"; succeeded: boolean }
  | { kind: "failed"; message: string };

/** 浏览器登录（添加账号）的进度，后台推 `login` 事件。 */
export interface LoginView {
  id: string;
  provider: Provider;
  phase: LoginPhase;
  loginUrl: string | null;
  outputTail: string;
}

/** 登录成功后自动添加的结果，后台推 `login-result` 事件。 */
export interface LoginResult {
  id: string;
  ok: boolean;
  name: string | null;
  error: string | null;
}

export interface SwitchNotice {
  seq: number;
  text: string;
  isError: boolean;
  /** 切换的时间（只在 8 秒内显示） */
  at: number;
}

/** 连上的 yybar 网站账号（GitHub）。 */
export interface WebProfile {
  login: string;
  name: string | null;
  avatarUrl: string | null;
}

/** bar 页：yybar 网站账号和待上传（后台 web.rs 的 WebView）。 */
export interface WebView {
  site: string;
  connected: boolean;
  profile: WebProfile | null;
  phase: "idle" | "waitingForBrowser" | "uploading";
  message: string | null;
  messageIsError: boolean;
  /** 今天以前、还没传过的（日期, 服务）；筹码按本机价格估，实际以网站为准 */
  pending: { days: string[]; pairs: string[]; costUsd: number; chips: number };
  uploadedDays: number;
  lastUploadAt: number | null;
  /** 今天已经成功点过一键上传 */
  usedManualToday: boolean;
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
  others: OtherAccountView[];
  switching: string | null;
  switchNotice: SwitchNotice | null;
  /** 本机装了哪些官方 CLI（添加账号时「在浏览器中登录」要用） */
  clis: { codex: boolean; claude: boolean; grok: boolean; agy: boolean };
  web: WebView;
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
