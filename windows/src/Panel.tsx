import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { api, useSnapshot, useTicker } from "./api";
import { APP_NAME, ago, pct, planLabel, remaining, resetText, statusClass, tokens, usd } from "./format";
import type { AppUsage, QuotaWindow, ServiceView, Settings, Snapshot } from "./types";

// ---------- 图标（Fluent 风格的细线图标） ----------

const Icon = {
  refresh: (
    <svg viewBox="0 0 16 16"><path d="M13.5 8a5.5 5.5 0 1 1-1.6-3.9M13.5 2.5v3h-3" /></svg>
  ),
  settings: (
    <svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="2.2" /><path d="M8 1.8v1.6M8 12.6v1.6M14.2 8h-1.6M3.4 8H1.8M12.4 3.6l-1.1 1.1M4.7 11.3l-1.1 1.1M12.4 12.4l-1.1-1.1M4.7 4.7 3.6 3.6" /></svg>
  ),
  power: (
    <svg viewBox="0 0 16 16"><path d="M8 2v6M4.6 4.2a5 5 0 1 0 6.8 0" /></svg>
  ),
  back: (
    <svg viewBox="0 0 16 16"><path d="M10 3 5 8l5 5" /></svg>
  ),
};

function IconButton(props: { title: string; onClick: () => void; children: React.ReactNode; spinning?: boolean; disabled?: boolean }) {
  return (
    <button className={`icon-btn${props.spinning ? " spinning" : ""}`} title={props.title} onClick={props.onClick} disabled={props.disabled}>
      {props.children}
    </button>
  );
}

// ---------- 服务块 ----------

// 不用官方 logo（商标风险），tile 里只放名字缩写
const TILE_LETTER = { codex: "Cx", claude: "Cl", grok: "G" } as const;

function Ring({ rem, label }: { rem: number | null; label: string }) {
  const r = 24;
  const c = 2 * Math.PI * r;
  const filled = rem === null ? 0 : (rem / 100) * c;
  return (
    <div className={`ring ${statusClass(rem)}`}>
      <svg viewBox="0 0 56 56">
        <circle className="ring-track" cx="28" cy="28" r={r} />
        <circle className="ring-fill" cx="28" cy="28" r={r} strokeDasharray={`${filled} ${c}`} transform="rotate(-90 28 28)" />
      </svg>
      <div className="ring-text">
        <span className="ring-pct num">{pct(rem)}</span>
        <span className="ring-label">{label}</span>
      </div>
    </div>
  );
}

function Bar({ title, w, now, asClock }: { title: string; w: QuotaWindow; now: number; asClock: boolean }) {
  const rem = remaining(w);
  return (
    <div className="bar-block">
      <div className="bar-head">
        <span className="muted">{title}</span>
        <span className={`num ${statusClass(rem)} st-text`}>{pct(rem)}</span>
      </div>
      <div className="bar-track">
        <div className={`bar-fill ${statusClass(rem)}`} style={{ width: `${rem ?? 0}%` }} />
      </div>
      <div className="bar-foot muted num">{resetText(w.resetsAt, asClock, now)}</div>
    </div>
  );
}

function ServiceBlock({ s, usage, now, settings }: { s: ServiceView; usage?: AppUsage; now: number; settings: Settings }) {
  const q = s.quota;
  const ringWindow = q?.fiveHour ?? q?.primary ?? null;
  const ringLabel = q?.fiveHour ? "5H" : q?.primaryLabel ?? "5H";
  const sub = [planLabel(q?.planType ?? null), s.account].filter(Boolean).join(" · ");
  return (
    <section className="service">
      <header className="service-head">
        <div className={`tile tile-${s.app}`}>{TILE_LETTER[s.app]}</div>
        <div className="service-name">
          <div className="title">{APP_NAME[s.app]}</div>
          <div className="caption muted">{sub || (s.detected ? "已登录" : "未检测到登录")}</div>
        </div>
        {ringWindow && <div className="caption muted num">{resetText(ringWindow.resetsAt, settings.resetAsClock, now)}</div>}
      </header>
      {!s.detected && !q ? (
        <div className="empty muted">在终端里登录 {APP_NAME[s.app]} CLI 后会自动出现</div>
      ) : (
        <div className="service-body">
          <Ring rem={remaining(ringWindow)} label={ringLabel} />
          <div className="service-right">
            {q?.weekly && <Bar title="本周额度" w={q.weekly} now={now} asClock={settings.resetAsClock} />}
            {!q && <div className="muted caption">等待数据</div>}
            <div className="stats">
              <div>
                <div className="stat-main num">{tokens(usage?.today.tokens ?? 0)}</div>
                <div className="stat-sub">今日 tokens</div>
              </div>
              <div>
                <div className="stat-main num">{usd(usage?.today.costUsd ?? 0)}</div>
                <div className="stat-sub">今日花费</div>
              </div>
              <div>
                <div className="stat-main num">{usd(usage?.week.costUsd ?? 0)}</div>
                <div className="stat-sub">本周花费</div>
              </div>
            </div>
          </div>
        </div>
      )}
      {s.error && <div className="error">{s.error}</div>}
    </section>
  );
}

// ---------- 用量汇总 ----------

function UsageFooter({ snap }: { snap: Snapshot }) {
  const u = snap.usage;
  const max = Math.max(0.01, ...u.daily.map((d) => d.codex + d.claude + d.grok));
  return (
    <section className="usage">
      <div className="usage-totals">
        {[
          ["今日", u.today],
          ["本周", u.week],
          ["本月", u.month],
        ].map(([label, p]) => (
          <div key={label as string} className="usage-cell">
            <div className="stat-sub">{label as string}</div>
            <div className="usage-cost num">{usd((p as { costUsd: number }).costUsd)}</div>
            <div className="caption muted num">{tokens((p as { tokens: number }).tokens)} tokens</div>
          </div>
        ))}
      </div>
      <div className="chart" title="近 30 天每日花费">
        {u.daily.map((d) => (
          <div key={d.day} className="chart-col" title={`${d.day}  ${usd(d.codex + d.claude + d.grok)}`}>
            <div className="seg seg-grok" style={{ height: `${(d.grok / max) * 100}%` }} />
            <div className="seg seg-claude" style={{ height: `${(d.claude / max) * 100}%` }} />
            <div className="seg seg-codex" style={{ height: `${(d.codex / max) * 100}%` }} />
          </div>
        ))}
      </div>
      <div className="chart-legend caption muted">
        <span><i className="dot seg-codex" />Codex</span>
        <span><i className="dot seg-claude" />Claude</span>
        <span><i className="dot seg-grok" />Grok</span>
        <span className="spacer" />
        <span>{u.scanning ? "正在扫描本地日志…" : `近 30 天 · ${u.filesScanned} 个日志文件`}</span>
      </div>
    </section>
  );
}

// ---------- 设置 ----------

function Toggle({ label, hint, checked, onChange }: { label: string; hint?: string; checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <label className="toggle-row">
      <div>
        <div>{label}</div>
        {hint && <div className="caption muted">{hint}</div>}
      </div>
      <input type="checkbox" className="switch" checked={checked} onChange={(e) => onChange(e.target.checked)} />
    </label>
  );
}

function SettingsView({ settings }: { settings: Settings }) {
  const [autostart, setAutostart] = useState(false);
  useEffect(() => {
    api.getAutostart().then((v) => setAutostart(!!v));
  }, []);
  const set = (patch: Partial<Settings>) => api.updateSettings({ ...settings, ...patch });
  return (
    <div className="settings">
      <div className="group-title">显示的服务</div>
      <Toggle label="Codex" checked={settings.showCodex} onChange={(v) => set({ showCodex: v })} />
      <Toggle label="Claude Code" checked={settings.showClaude} onChange={(v) => set({ showClaude: v })} />
      <Toggle label="Grok" checked={settings.showGrok} onChange={(v) => set({ showGrok: v })} />
      <div className="group-title">通用</div>
      <Toggle label="悬浮条" hint="桌面上常驻显示剩余额度和今日花费，可拖动" checked={settings.showPill} onChange={(v) => set({ showPill: v })} />
      <Toggle label="开机启动" checked={autostart} onChange={(v) => api.setAutostart(v).then((r) => setAutostart(!!r))} />
      <Toggle label="同时统计 WSL 里的用量" hint="只读取已经在运行的 WSL 发行版，不会把它们启动" checked={settings.scanWsl} onChange={(v) => set({ scanWsl: v })} />
      <Toggle label="重置时间显示为具体时刻" checked={settings.resetAsClock} onChange={(v) => set({ resetAsClock: v })} />
      <label className="toggle-row">
        <div>额度刷新间隔</div>
        <select value={settings.quotaIntervalSecs} onChange={(e) => set({ quotaIntervalSecs: Number(e.target.value) })}>
          {[60, 120, 180, 300, 600].map((s) => (
            <option key={s} value={s}>{s / 60} 分钟</option>
          ))}
        </select>
      </label>
    </div>
  );
}

// ---------- 面板 ----------

export default function Panel() {
  const snap = useSnapshot();
  const now = useTicker();
  const [view, setView] = useState<"main" | "settings">("main");
  const root = useRef<HTMLDivElement>(null);

  useEffect(() => {
    api.backdrop().then((kind) => document.body.classList.toggle("mica", kind === "mica"));
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") api.hidePanel();
      if (e.key.toLowerCase() === "r" && e.ctrlKey) api.refresh();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  // 面板高度跟着内容走
  useLayoutEffect(() => {
    const el = root.current;
    if (!el) return;
    const ro = new ResizeObserver(() => api.fitPanel(Math.ceil(el.getBoundingClientRect().height)));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const services = snap?.services.filter((s) => s.enabled) ?? [];
  const refreshing = services.some((s) => s.inFlight);
  const lastSuccess = Math.max(0, ...services.map((s) => s.lastSuccessAt ?? 0)) || null;
  const anyLive = services.some((s) => s.lastSuccessAt && !s.error);

  return (
    <div className="panel" ref={root}>
      <header className="panel-head">
        {view === "settings" ? (
          <>
            <IconButton title="返回" onClick={() => setView("main")}>{Icon.back}</IconButton>
            <div className="title">设置</div>
          </>
        ) : (
          <div>
            <div className="title">用量</div>
            <div className="caption muted">
              <i className={`live-dot ${anyLive ? "live" : "stale"}`} />
              {ago(lastSuccess, now)}
            </div>
          </div>
        )}
        <span className="spacer" />
        {view === "main" && (
          <IconButton title="刷新 (Ctrl+R)" onClick={() => api.refresh()} spinning={refreshing} disabled={refreshing}>
            {Icon.refresh}
          </IconButton>
        )}
        <IconButton title="设置" onClick={() => setView(view === "settings" ? "main" : "settings")}>{Icon.settings}</IconButton>
        <IconButton title="退出 yybar" onClick={() => api.quit()}>{Icon.power}</IconButton>
      </header>
      {!snap ? (
        <div className="empty muted">正在读取…</div>
      ) : view === "settings" ? (
        <SettingsView settings={snap.settings} />
      ) : (
        <>
          {services.length === 0 && <div className="empty muted">没有启用任何服务，去设置里打开</div>}
          {services.map((s) => (
            <ServiceBlock key={s.app} s={s} usage={snap.usage.perApp.find((u) => u.app === s.app)} now={now} settings={snap.settings} />
          ))}
          <UsageFooter snap={snap} />
        </>
      )}
    </div>
  );
}
