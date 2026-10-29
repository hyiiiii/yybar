// 共享组件（对应 Mac `Main/DesignSystem.swift`）：状态色、服务 tile / logo、进度条、额度行、开关、分段控件、图标。

import { useState, type CSSProperties, type ReactNode } from "react";
import { resetAltCompact, resetCompact, nowSecs, relativeShort } from "./format";
import { tr } from "./l10n";
import { shortLabel, windowsFor } from "./quota";
import { accentVar, colorLogo, displayName, monoLogo } from "./services";
import { ALL_APPS, floatingShows, localShown, trayShows } from "./types";
import type { Indicator, QuotaSnapshot, QuotaWindow, RefreshState, ResetTimeDisplay, ServiceStatus, StateSnapshot, UsageApp } from "./types";

// ---------- 状态色 ----------

/** 按剩余百分比 4 档：>50% normal / 20~50% warning / <20% low / =0 empty（设计风格 §4.3）。 */
export function statusColor(remaining: number | null | undefined): string {
  if (remaining == null) return "var(--text-secondary)";
  if (remaining <= 0) return "var(--q-empty)";
  if (remaining < 20) return "var(--q-low)";
  if (remaining <= 50) return "var(--q-warning)";
  return "var(--q-normal)";
}

export function indicatorColor(i: Indicator): string {
  switch (i) {
    case "none":
      return "var(--sys-green)";
    case "minor":
      return "var(--sys-yellow)";
    case "major":
      return "var(--sys-orange)";
    case "critical":
      return "var(--sys-red)";
    case "maintenance":
      return "var(--sys-blue)";
    default:
      return "var(--text-tertiary)";
  }
}

export function indicatorLabel(i: Indicator): string {
  switch (i) {
    case "none":
      return tr("All systems normal", "服务正常");
    case "minor":
      return tr("Minor issue", "轻微故障");
    case "major":
      return tr("Major issue", "重大故障");
    case "critical":
      return tr("Critical outage", "严重故障");
    case "maintenance":
      return tr("Maintenance", "维护中");
    default:
      return tr("Status unknown", "状态未知");
  }
}

export function statusTooltip(s: ServiceStatus): string {
  const head = s.description?.trim() || indicatorLabel(s.indicator);
  if (!s.updatedAt) return head;
  const age = relativeShort(s.updatedAt);
  return tr(`${head} · updated ${age} ago`, `${head} · ${age} 前更新`);
}

export function StatusDot({ status, size = 7, grayWhenMissing = false }: { status: ServiceStatus | null | undefined; size?: number; grayWhenMissing?: boolean }) {
  const missing = !status || status.indicator === "unknown";
  if (missing && !grayWhenMissing) return null;
  return (
    <span
      className="status-dot"
      title={status ? statusTooltip(status) : tr("Status unavailable", "暂无状态")}
      style={{ width: size, height: size, background: missing ? "var(--fill-strong)" : indicatorColor(status!.indicator) }}
    />
  );
}

// ---------- 服务 tile / logo ----------

/** 带 logo 的圆角方块：Codex 白底黑 logo + 细边；Claude 桃橙；Grok 黑底；Antigravity 白底彩虹 logo。 */
export function ServiceTile({ app, size = 22, logoSize = 14, radius = 6 }: { app: UsageApp; size?: number; logoSize?: number; radius?: number }) {
  const color = colorLogo[app];
  const style: CSSProperties = { width: size, height: size, borderRadius: radius };
  return (
    <span className={`service-tile tile-${app}`} style={style} title={displayName[app]}>
      <span className="logo" style={{ width: logoSize, height: logoSize }} dangerouslySetInnerHTML={{ __html: color ?? monoLogo[app] }} />
    </span>
  );
}

/** 单色 logo 染成服务识别色（Antigravity 用彩色版）。统计页里替代小色块。 */
export function ServiceLogo({ app, size = 14, title }: { app: UsageApp; size?: number; title?: string }) {
  const color = colorLogo[app];
  return (
    <span
      className={`service-logo logo-${app}`}
      title={title}
      style={{ width: size, height: size }}
      dangerouslySetInnerHTML={{ __html: color ?? monoLogo[app] }}
    />
  );
}

// ---------- 进度条 ----------

/** 套餐名：首字母大写；ChatGPT 的代号换成名字（prolite → Pro Lite、pro → Pro 20x、promax → Pro Max，和网站一致） */
export function planName(plan: string, app: UsageApp): string {
  const codex: Record<string, string> = { prolite: "Pro Lite", pro: "Pro 20x", promax: "Pro Max" };
  const named = app === "codex" ? codex[plan.toLowerCase()] : undefined;
  return named ?? plan.replace(/_+/g, " ").replace(/^./, (c) => c.toUpperCase());
}

/** 订阅等级标签（设置、弹出窗口、悬浮窗共用）：免费灰、标准档蓝、高档紫、团队 / 企业青。
 *  同名档次在不同服务里不一样：ChatGPT Pro 是最高档，Claude Pro 是标准档、Max 才是高档。 */
export function PlanTag({ plan, app }: { plan: string; app: UsageApp }) {
  const p = plan.toLowerCase();
  let tier: "free" | "standard" | "premium" | "team";
  if (p.includes("free") || p === "guest") tier = "free";
  else if (["team", "business", "enterprise", "edu"].some((t) => p.includes(t))) tier = "team";
  else if (app === "codex") tier = p.includes("pro") ? "premium" : "standard";
  else if (app === "claude") tier = p.includes("max") ? "premium" : "standard";
  else tier = p.includes("heavy") || p.includes("ultra") ? "premium" : "standard";
  const color = { free: "var(--text-secondary)", standard: "var(--sys-blue)", premium: "var(--sys-purple)", team: "var(--sys-teal)" }[tier];
  return (
    <span className="pill-tag" style={{ color, background: tier === "free" ? "var(--fill)" : `color-mix(in srgb, ${color} 13%, transparent)` }}>
      {planName(plan, app)}
    </span>
  );
}

export function ProgressBar({ value, color, height = 5 }: { value: number; color: string; height?: number }) {
  const v = Math.max(0, Math.min(1, value));
  return (
    <div className="progress" style={{ height, borderRadius: height / 2 }}>
      <div className="progress-fill" style={{ width: `${v * 100}%`, background: color, borderRadius: height / 2 }} />
    </div>
  );
}

// ---------- 重置时间 ----------

/** 重置时间，悬停切换成「相反格式」（剩余时长 ↔ 具体时间）。 */
export function ResetTimeText({ resetsAt, mode, now }: { resetsAt: number | null | undefined; mode: ResetTimeDisplay; now?: number }) {
  const [hover, setHover] = useState(false);
  const t = now ?? nowSecs();
  return (
    <span className="num reset-text" onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)}>
      {hover ? resetAltCompact(resetsAt, mode, t) : resetCompact(resetsAt, mode, t)}
    </span>
  );
}

// ---------- 额度行 ----------

/** 一行额度：标签 / 进度条 / 剩余百分比 / 重置倒计时。统计页「当前额度」和弹出浮窗共用。
 * 条用服务识别色；剩余 ≤50% 时百分比文字转为状态色（黄 / 橙 / 红）。 */
export function LimitBarRow({ label, window, tint, labelWidth = 74, mode, now }: {
  label: string;
  window: QuotaWindow | null | undefined;
  tint: string;
  labelWidth?: number;
  mode: ResetTimeDisplay;
  now?: number;
}) {
  const rem = window ? Math.max(0, Math.min(100, 100 - window.usedPercent)) : null;
  const percentColor = rem == null ? "var(--text-secondary)" : rem > 50 ? "var(--text)" : statusColor(rem);
  return (
    <div className="limit-row">
      <span className="limit-label" style={{ width: labelWidth }}>
        {label}
      </span>
      <ProgressBar value={(rem ?? 0) / 100} color={window ? tint : "var(--text-secondary)"} height={6} />
      <span className="limit-percent num" style={{ color: percentColor }}>
        {rem == null ? "--" : `${Math.round(rem)}%`}
      </span>
      <span className="limit-reset">
        <ResetTimeText resetsAt={window?.resetsAt} mode={mode} now={now} />
      </span>
    </div>
  );
}

// ---------- 控件 ----------

export function Toggle({ checked, onChange, disabled, small, title }: { checked: boolean; onChange: (v: boolean) => void; disabled?: boolean; small?: boolean; title?: string }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      title={title}
      disabled={disabled}
      className={`toggle ${checked ? "on" : ""} ${small ? "small" : ""}`}
      onClick={() => onChange(!checked)}
    >
      <span className="knob" />
    </button>
  );
}

export function Checkbox({ checked, onChange, disabled, title }: { checked: boolean; onChange: (v: boolean) => void; disabled?: boolean; title?: string }) {
  return (
    <button type="button" role="checkbox" aria-checked={checked} title={title} disabled={disabled} className={`checkbox ${checked ? "on" : ""}`} onClick={() => onChange(!checked)}>
      {checked && <Icon name="check" size={10} />}
    </button>
  );
}

export function Segmented<T extends string>({ options, value, onChange, small, title }: {
  options: { value: T; label: string }[];
  value: T;
  onChange: (v: T) => void;
  small?: boolean;
  title?: string;
}) {
  return (
    <div className={`segmented ${small ? "small" : ""}`} title={title}>
      {options.map((o) => (
        <button type="button" key={o.value} className={o.value === value ? "active" : ""} onClick={() => onChange(o.value)}>
          {o.label}
        </button>
      ))}
    </div>
  );
}

export function Select<T extends string>({ options, value, onChange }: { options: { value: T; label: string }[]; value: T; onChange: (v: T) => void }) {
  return (
    <select className="select" value={value} onChange={(e) => onChange(e.target.value as T)}>
      {options.map((o) => (
        <option key={o.value} value={o.value}>
          {o.label}
        </option>
      ))}
    </select>
  );
}

/** 刷新按钮：点一下图标转一圈。 */
export function RefreshButton({ onClick, size = 13, title }: { onClick: () => void; size?: number; title?: string }) {
  const [turns, setTurns] = useState(0);
  return (
    <button
      type="button"
      className="icon-button"
      title={title ?? tr("Refresh now", "立即刷新")}
      onClick={() => {
        setTurns((t) => t + 1);
        onClick();
      }}
    >
      <span className="spin" style={{ transform: `rotate(${turns * 360}deg)`, display: "inline-flex" }}>
        <Icon name="refresh" size={size} />
      </span>
    </button>
  );
}

// ---------- 图标（线性，16 网格；对应 Mac 的 SF Symbols） ----------

const PATHS: Record<string, ReactNode> = {
  chart: (
    <>
      <path d="M2.5 13.5h11" />
      <path d="M4.5 11V7.5M8 11V4M11.5 11V6" />
    </>
  ),
  gear: (
    <>
      <circle cx="8" cy="8" r="2.2" />
      <path d="M8 1.8v1.6M8 12.6v1.6M14.2 8h-1.6M3.4 8H1.8M12.4 3.6l-1.1 1.1M4.7 11.3l-1.1 1.1M12.4 12.4l-1.1-1.1M4.7 4.7 3.6 3.6" />
      <circle cx="8" cy="8" r="4.6" />
    </>
  ),
  refresh: (
    <>
      <path d="M13 8a5 5 0 1 1-1.6-3.7" />
      <path d="M13 2.5v3h-3" />
    </>
  ),
  pie: (
    <>
      <path d="M8 2.2A5.8 5.8 0 1 0 13.8 8H8z" />
      <path d="M10 1.8v4.2h4.2A4.4 4.4 0 0 0 10 1.8z" />
    </>
  ),
  grid: (
    <>
      <rect x="2" y="2" width="3" height="3" rx=".6" />
      <rect x="6.5" y="2" width="3" height="3" rx=".6" />
      <rect x="11" y="2" width="3" height="3" rx=".6" />
      <rect x="2" y="6.5" width="3" height="3" rx=".6" />
      <rect x="6.5" y="6.5" width="3" height="3" rx=".6" />
      <rect x="11" y="6.5" width="3" height="3" rx=".6" />
      <rect x="2" y="11" width="3" height="3" rx=".6" />
      <rect x="6.5" y="11" width="3" height="3" rx=".6" />
    </>
  ),
  line: (
    <>
      <path d="M2 13.5h12" />
      <path d="M2.5 11 6 7.5l2.5 2L13.5 4" />
      <path d="M10.5 4h3v3" />
    </>
  ),
  cpu: (
    <>
      <rect x="4" y="4" width="8" height="8" rx="1.2" />
      <rect x="6.2" y="6.2" width="3.6" height="3.6" rx=".5" />
      <path d="M6 2v2M10 2v2M6 12v2M10 12v2M2 6h2M2 10h2M12 6h2M12 10h2" />
    </>
  ),
  plug: (
    <>
      <path d="M5.5 2v3M10.5 2v3" />
      <path d="M4 5h8v2.5a4 4 0 0 1-8 0z" />
      <path d="M8 11.5V14" />
    </>
  ),
  taskbar: (
    <>
      <rect x="1.8" y="3" width="12.4" height="10" rx="1.5" />
      <path d="M1.8 10.5h12.4" />
      <path d="M10.5 12h2" />
    </>
  ),
  info: (
    <>
      <circle cx="8" cy="8" r="6" />
      <path d="M8 7.2V11M8 5v.2" />
    </>
  ),
  chevronRight: <path d="m6 3.5 4.5 4.5L6 12.5" />,
  chevronDown: <path d="m3.5 6 4.5 4.5L12.5 6" />,
  chevronUp: <path d="m3.5 10 4.5-4.5 4.5 4.5" />,
  merge: (
    <>
      <path d="M4 2.5v3.5c0 2 4 2.5 4 5v2.5M12 2.5v3.5c0 2-4 2.5-4 5" />
      <path d="m6 11.5 2 2 2-2" />
    </>
  ),
  branch: (
    <>
      <path d="M8 13.5V10c0-2-4-2.5-4-5V2.5M8 10c0-2 4-2.5 4-5V2.5" />
      <path d="m2 4.5 2-2 2 2M10 4.5l2-2 2 2" />
    </>
  ),
  minusCircle: (
    <>
      <circle cx="8" cy="8" r="6" />
      <path d="M5.2 8h5.6" />
    </>
  ),
  undo: (
    <>
      <circle cx="8" cy="8" r="6" />
      <path d="M10.5 10.5V9a2 2 0 0 0-2-2H5.5" />
      <path d="m7 5.5-1.5 1.5L7 8.5" />
    </>
  ),
  gauge: (
    <>
      <path d="M2.5 11a5.5 5.5 0 1 1 11 0" />
      <path d="m8 11 2.6-3.2" />
      <path d="M4.5 11h.5M11 11h.5M8 5.5V6" />
    </>
  ),
  check: <path d="m3 8.5 3 3 7-7" />,
  sidebar: (
    <>
      <rect x="2" y="3" width="12" height="10" rx="1.5" />
      <path d="M6 3v10" />
    </>
  ),
  warning: <path d="M8 2 14.5 13.5h-13z M8 6.5V9.5 M8 11.2v.3" />,
  globe: (
    <>
      <circle cx="8" cy="8" r="6" />
      <path d="M2 8h12M8 2c1.8 1.8 2.6 3.8 2.6 6S9.8 12.2 8 14c-1.8-1.8-2.6-3.8-2.6-6S6.2 3.8 8 2z" />
    </>
  ),
  clipboard: (
    <>
      <rect x="3.5" y="3" width="9" height="11" rx="1.5" />
      <path d="M6 3V2.4c0-.3.2-.5.5-.5h3c.3 0 .5.2.5.5V3M5.8 7h4.4M5.8 9.5h4.4" />
    </>
  ),
  terminal: (
    <>
      <rect x="2" y="3" width="12" height="10" rx="1.5" />
      <path d="m4.8 6.2 2 1.8-2 1.8M8.5 10.2h2.7" />
    </>
  ),
  external: <path d="M9.5 2.5h4v4M13.5 2.5 7.5 8.5M12 9.5v3a1 1 0 0 1-1 1H3.5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h3" />,
  personPlus: (
    <>
      <circle cx="6.5" cy="5.5" r="2.5" />
      <path d="M2 13.5c.4-2.3 2.2-3.8 4.5-3.8s4.1 1.5 4.5 3.8M12.5 5v4M10.5 7h4" />
    </>
  ),
  plusCircle: (
    <>
      <circle cx="8" cy="8" r="6" />
      <path d="M8 5.2v5.6M5.2 8h5.6" />
    </>
  ),
  cards: (
    <>
      <rect x="2.3" y="3.6" width="6.8" height="9.6" rx="1.2" transform="rotate(-10 5.7 8.4)" />
      <rect x="7" y="2.8" width="6.8" height="9.6" rx="1.2" transform="rotate(8 10.4 7.6)" />
    </>
  ),
  upload: (
    <>
      <circle cx="8" cy="8" r="6" />
      <path d="M8 10.8V5.4M5.6 7.6 8 5.2l2.4 2.4" />
    </>
  ),
};

export function Icon({ name, size = 14, className }: { name: keyof typeof PATHS | string; size?: number; className?: string }) {
  if (name === "warning") {
    return (
      <svg className={className} width={size} height={size} viewBox="0 0 16 16" aria-hidden>
        <path d="M8 1.6 15 14H1z" fill="currentColor" />
        <path d="M8 6v4M8 11.6v.4" stroke="var(--warning-ink)" strokeWidth="1.6" strokeLinecap="round" />
      </svg>
    );
  }
  return (
    <svg className={className} width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      {PATHS[name]}
    </svg>
  );
}

/** 跳动的小火苗（模型明细里用量最多的模型）。 */
export function HotFlame({ title }: { title?: string }) {
  return (
    <span className="hot-flame" title={title}>
      🔥
    </span>
  );
}

/**
 * 数字变化时滚动过去（对应 Mac 的 `.contentTransition(.numericText())`）：旧值往上淡出，新值从下面淡入。
 * 第一次显示不动；系统要求减少动态效果时直接换。
 */
export function RollingText({ text, className }: { text: string; className?: string }) {
  const [state, setState] = useState<{ cur: string; prev: string | null; seq: number; up: boolean }>({ cur: text, prev: null, seq: 0, up: true });
  if (text !== state.cur) {
    // 数值变大往上滚，变小往下滚（读得出数字时）
    const n = (v: string) => Number(v.replace(/[^0-9.\-]/g, ""));
    const up = !(Number.isFinite(n(text)) && Number.isFinite(n(state.cur)) && n(text) < n(state.cur));
    setState({ cur: text, prev: state.cur, seq: state.seq + 1, up });
  }
  return (
    <span className={`rolling ${className ?? ""}`}>
      {state.prev != null && (
        <span key={`p${state.seq}`} className={`rolling-out ${state.up ? "up" : "down"}`} aria-hidden>
          {state.prev}
        </span>
      )}
      <span key={`c${state.seq}`} className={state.seq > 0 ? `rolling-in ${state.up ? "up" : "down"}` : undefined}>
        {state.cur}
      </span>
    </span>
  );
}

/** 展开 / 收起时高度弹簧过渡、内容淡入淡出（对应 Mac 的 `.transition(.opacity.combined(with: .move(edge: .top)))`）。内容一直挂着。 */
export function Collapsible({ open, children }: { open: boolean; children: ReactNode }) {
  return (
    <div className={`collapsible ${open ? "open" : ""}`} aria-hidden={!open}>
      <div className="collapsible-inner">{children}</div>
    </div>
  );
}

// ---------- 账号额度块 ----------

/** 一个账号的额度块（对应 Mac `QuotaEntry`）：弹出窗口和「详细」样式的悬浮窗共用。 */
export type QuotaEntry = { key: string; app: UsageApp; title: string; plan: string | null; quota: QuotaSnapshot | null; refresh: RefreshState; status: ServiceStatus | null };

/** 要显示的账号：每个服务本机账号在前、其他账号（标题带账号名）在后，按服务顺序。place 为托盘（弹出窗口）或悬浮窗的勾选。 */
export function quotaEntries(state: StateSnapshot, place: "tray" | "floating"): QuotaEntry[] {
  const settings = state.settings;
  const shows = place === "tray" ? trayShows : floatingShows;
  const entries: QuotaEntry[] = [];
  for (const app of ALL_APPS) {
    const s = state.services.find((x) => x.app === app);
    if (!s) continue;
    if (shows(settings, app) && localShown(s)) {
      entries.push({ key: app, app, title: displayName[app], plan: s.plan, quota: s.quota, refresh: s.refresh, status: s.status });
    }
    for (const o of state.others) {
      if (o.app !== app || !o.enabled || !(place === "tray" ? o.showInTray : o.showInFloating)) continue;
      entries.push({ key: o.id, app, title: `${displayName[app]} · ${o.name}`, plan: o.plan, quota: o.quota, refresh: o.refresh, status: s.status });
    }
  }
  return entries;
}

/** 图标、名称、套餐、官方状态点，下面 5H / WK 的剩余条和重置倒计时（Antigravity 按池写成「Gemini 5H」）；
 *  刷新失败时名称旁一个小警告（悬停看原因）。 */
export function QuotaEntryView({ entry, mode, now }: { entry: QuotaEntry; mode: ResetTimeDisplay; now: number }) {
  const windows = windowsFor(entry.app, entry.quota);
  const pools = entry.quota?.pools;
  return (
    <div className="quota-entry">
      <ServiceTile app={entry.app} size={22} logoSize={13} />
      <div className="quota-entry-body">
        <div className="quota-entry-head">
          <span className="quota-entry-title">{entry.title}</span>
          {entry.plan && <PlanTag plan={entry.plan} app={entry.app} />}
          {entry.refresh.lastError && (
            <span className="quota-entry-warning" title={entry.refresh.lastError}>
              <Icon name="warning" size={11} />
            </span>
          )}
          <span style={{ flex: 1 }} />
          <StatusDot status={entry.status} size={6} />
        </div>
        {windows.map((w) => (
          <LimitBarRow key={w.id} label={shortLabel(w, pools)} window={w.window} tint={accentVar[entry.app]} labelWidth={pools ? 92 : 30} mode={mode} now={now} />
        ))}
      </div>
    </div>
  );
}
