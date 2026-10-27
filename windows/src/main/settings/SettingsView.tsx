// 设置大页（对应 Mac `SettingsRootView`）：服务 / 显示 / 刷新 / 通用 四部分纵向排列，内容限宽 640。
// 每部分沿用 PrefsGroup + PrefsRow 卡片结构；改动立即生效（间隔变化同步到调度器，不用重启）。

import { useEffect, useRef, useState, type ReactNode } from "react";
import { api, useTicker } from "../../shared/api";
import { Checkbox, Icon, Segmented, Select, ServiceTile, Toggle } from "../../shared/design";
import { relativeShort, timeString } from "../../shared/format";
import { isChinese, tr } from "../../shared/l10n";
import { displayName } from "../../shared/services";
import { ALL_APPS, SETTING_KEYS, localShown, type IntervalChoice, type OtherAccountView, type ServiceView, type Settings, type StateSnapshot, type SubscriptionRenewal, type SwitchNotice, type UsageApp, type UsagePayload } from "../../shared/types";
import { Section, SectionHeading, SectionedPage, type ScrollRequest } from "../SectionedPage";
import { SETTINGS_PAGES, tabTitle, type MainTab } from "../tabs";
import { ModelPrices } from "./ModelPrices";
import { AddAccountDialog } from "./AddAccountDialog";
import { QuotaCard, otherTitle } from "./QuotaCard";

const INTERVALS: IntervalChoice[] = ["m1", "m2", "m3", "m5", "m10"];
const intervalLabel = (c: IntervalChoice) => {
  const n = Number(c.slice(1));
  return tr(`${n} minute${n > 1 ? "s" : ""}`, `${n} 分钟`);
};

export function SettingsView({ state, usage, active, request, onActive }: {
  state: StateSnapshot;
  usage: UsagePayload | null;
  active: MainTab;
  request: ScrollRequest;
  onActive: (t: MainTab) => void;
}) {
  const s = state.settings;
  const set = (patch: Partial<Settings>) => api.updateSettings(patch);
  const [confirm, setConfirm] = useState<UsageApp | null>(null);
  const [otherConfirm, setOtherConfirm] = useState<OtherAccountView | null>(null);
  const [adding, setAdding] = useState(false);
  const [autostartError, setAutostartError] = useState<string | null>(null);
  const now = useTicker(1000);
  const anyRemoved = Object.keys(s.removedLocalAccounts).length > 0;
  const noAccounts = state.services.every((x) => !localShown(x)) && state.others.length === 0;
  const latest = Math.max(0, ...state.services.map((x) => x.refresh.lastSuccessAt ?? 0));

  return (
    <>
      <SectionedPage sections={SETTINGS_PAGES} request={request} active={active} onActive={onActive}>
        <Section tab="services" maxWidth={640}>
          <SectionHeading title={tabTitle("services")} />
          <PrefsGroup
            title={tr("Accounts", "账号")}
            desc={tr(
              "The green dot marks the account each CLI on this PC is using. Click the circle next to another account to switch the CLI to it.",
              "绿点表示本机 CLI 正在使用的账号；点其他账号左侧的圆圈，即可把本机 CLI 切换到该账号",
            )}
          >
            {noAccounts ? (
              <div className="services-empty">
                {tr(
                  "No accounts yet. A CLI signed in on this PC shows up here automatically, or add an account below.",
                  "还没有账号。本机 CLI 登录后会自动出现在这里，也可以点下方「添加账号…」添加。",
                )}
              </div>
            ) : (
              <MatrixHeader />
            )}
            {ALL_APPS.map((app) => {
              const service = state.services.find((x) => x.app === app)!;
              const others = state.others.filter((o) => o.app === app);
              // 本机没登录（未识别）的服务不列，只列其他账号
              const local = localShown(service);
              if (!local && others.length === 0) return null;
              return (
                <div key={app}>
                  <div className="divider" />
                  {local && <ServiceRow state={state} service={service} buckets={usage?.buckets ?? []} onDelete={() => setConfirm(app)} />}
                  {others.map((o, i) => (
                    <div key={o.id} className="row-enter">
                      {(i > 0 || local) && <div className="divider inset" />}
                      <OtherRow state={state} service={service} account={o} buckets={usage?.buckets ?? []} onDelete={() => setOtherConfirm(o)} />
                    </div>
                  ))}
                </div>
              );
            })}
            <div className="divider" />
            <button className="restore-button add-account-button" onClick={() => setAdding(true)}>
              <Icon name="plusCircle" size={14} />
              {tr("Add account…", "添加账号…")}
            </button>
            {anyRemoved && (
              <>
                <div className="divider" />
                <button className="restore-button" onClick={() => api.restoreRemovedAccounts()}>
                  <Icon name="undo" size={13} />
                  {tr("Restore removed accounts", "恢复已删除的本机账号")}
                </button>
              </>
            )}
          </PrefsGroup>
          <SwitchNoticeView notice={state.switchNotice} />
          <p className="group-note">
            {tr(
              "Accounts you add are saved only on this PC (%APPDATA%\\yybar), readable by your Windows user, and don't affect the CLIs' own sign-ins until you switch.",
              "添加的账号只保存在本机（%APPDATA%\\yybar），只有当前 Windows 用户能读；在你切换之前，不影响本机 CLI 自己的登录。",
            )}
          </p>
        </Section>

        <Section tab="display" maxWidth={640}>
          <SectionHeading title={tabTitle("display")} />
          <PrefsGroup title={tr("Taskbar", "任务栏")} desc={tr("Which services appear is set on the Services page.", "显示哪些服务在「服务」页勾选")}>
            <PrefsRow label={tr("Quota period", "额度周期")} desc={tr("Grok always shows its billing period.", "Grok 始终显示计费周期")}>
              <Segmented
                options={[
                  { value: "fiveHour", label: "5H" },
                  { value: "weekly", label: "WK" },
                  { value: "both", label: tr("Lower of both", "取较低者") },
                ]}
                value={s.menuBarWindow}
                onChange={(v) => set({ menuBarWindow: v })}
              />
            </PrefsRow>
            <div className="divider" />
            <PrefsRow
              label={tr("Breathe while in use", "使用中图标呼吸")}
              desc={tr("A service's tray icon pulses between its number and logo while it's being used.", "服务正在使用时，托盘图标在数字和 logo 之间呼吸闪烁")}
            >
              <Toggle checked={s.menuBarBreatheWhenActive} onChange={(v) => set({ menuBarBreatheWhenActive: v })} />
            </PrefsRow>
            <div className="divider" />
            <PrefsRow
              label={tr("Hold logo while waiting for approval", "等待审批保持 logo")}
              desc={tr("When a CLI is waiting for you to approve a tool call, its icon keeps showing the logo.", "CLI 等待你批准工具调用时，图标保持显示 logo、不闪烁")}
            >
              <Toggle checked={s.menuBarHoldColorWhileWaiting} onChange={(v) => set({ menuBarHoldColorWhileWaiting: v })} />
            </PrefsRow>
          </PrefsGroup>
          <PrefsGroup title={tr("Statistics", "统计")}>
            <PrefsRow label={tr("Reset time", "重置时间显示为")} desc={tr("Used in Current limits, the popup and the floating window.", "用于「当前额度」、弹出窗口和悬浮窗")}>
              <Select
                options={[
                  { value: "relative", label: tr("Remaining", "剩余时长") },
                  { value: "absolute", label: tr("Exact time", "具体时间") },
                ]}
                value={s.resetTimeDisplay}
                onChange={(v) => set({ resetTimeDisplay: v })}
              />
            </PrefsRow>
            <div className="divider" />
            <PrefsRow
              label={tr("Service status dot", "服务状态圆点")}
              desc={tr("Show OpenAI / Anthropic / xAI / Google status in the popup and on the Statistics filter buttons.", "在弹出窗口和统计页服务筛选按钮上显示 OpenAI / Anthropic / xAI / Google 官方状态")}
            >
              <Toggle checked={s.showServiceStatus} onChange={(v) => set({ showServiceStatus: v })} />
            </PrefsRow>
          </PrefsGroup>
          <PrefsGroup title={tr("Floating window", "悬浮窗")}>
            <PrefsRow
              label={tr("Show floating window", "显示悬浮窗")}
              desc={tr("A small always-on-top window. Pick its services on the Services page.", "固定在桌面上的小窗口，显示哪些服务在「服务」页勾选")}
            >
              <Toggle checked={s.floatingEnabled} onChange={(v) => set({ floatingEnabled: v })} />
            </PrefsRow>
          </PrefsGroup>
        </Section>

        <Section tab="refresh" maxWidth={640}>
          <SectionHeading title={tabTitle("refresh")} />
          <PrefsGroup desc={tr("How often the app polls in the background. Rate limits back off automatically.", "后台轮询频率，遇到限流时会自动退避")}>
            <PrefsRow label={tr("Quota refresh", "额度刷新")} desc={tr("Fetches remaining quota from each service.", "请求官方接口获取剩余额度")}>
              <Select options={INTERVALS.map((c) => ({ value: c, label: intervalLabel(c) }))} value={s.quotaInterval} onChange={(v) => set({ quotaInterval: v })} />
            </PrefsRow>
            <div className="divider" />
            <PrefsRow label={tr("Log scan", "日志扫描")} desc={tr("Reads local CLI logs to count tokens and cost.", "读取本地 CLI 记录计算 Token 和费用")}>
              <Select options={INTERVALS.map((c) => ({ value: c, label: intervalLabel(c) }))} value={s.usageInterval} onChange={(v) => set({ usageInterval: v })} />
            </PrefsRow>
            <div className="divider" />
            <PrefsRow
              label={tr("Include WSL", "也统计 WSL")}
              desc={tr(
                "Also read sign-ins and logs from running WSL distros (\\\\wsl.localhost). Stopped distros are left alone.",
                "同时读取正在运行的 WSL 发行版里的 CLI 登录和日志（\\\\wsl.localhost），没在运行的发行版不碰",
              )}
            >
              <Toggle checked={s.scanWsl} onChange={(v) => set({ scanWsl: v })} />
            </PrefsRow>
          </PrefsGroup>
          <PrefsGroup title={tr("Status", "状态")}>
            <PrefsRow label={tr("Last refresh", "上次刷新")}>
              <span className="row-inline">
                <span className="num secondary" style={{ fontSize: 11.5 }}>
                  {latest > 0 ? `${timeString(latest)} · ${relativeShort(latest, now)} ${tr("ago", "前")}` : "—"}
                </span>
                <button className="button" onClick={() => api.refreshNow()}>
                  <Icon name="refresh" size={12} />
                  {tr("Refresh now", "立即刷新")}
                </button>
              </span>
            </PrefsRow>
            <div className="divider" />
            <PrefsRow label={tr("Local usage", "本地用量")}>
              <span className="num secondary" style={{ fontSize: 11.5 }}>
                {state.repricing
                  ? tr("Recalculating costs with the new prices…", "正在按新价格重算历史费用…")
                  : state.usage.scanning
                    ? tr("Scanning…", "正在扫描…")
                    : state.usage.lastScanAt
                      ? tr(`Scanned ${relativeShort(state.usage.lastScanAt, now)} ago`, `${relativeShort(state.usage.lastScanAt, now)} 前扫描`)
                      : "—"}
              </span>
            </PrefsRow>
          </PrefsGroup>
        </Section>

        <Section tab="general" maxWidth={640}>
          <SectionHeading title={tabTitle("general")} />
          <PrefsGroup>
            <PrefsRow label={tr("Language", "语言")}>
              <Select
                options={[
                  { value: "system", label: "Follow System · 跟随系统" },
                  { value: "zh", label: "中文" },
                  { value: "en", label: "English" },
                ]}
                value={s.appLanguage}
                onChange={(v) => set({ appLanguage: v })}
              />
            </PrefsRow>
            <div className="divider" />
            <PrefsRow label={tr("Launch at sign-in", "开机自动启动")}>
              <Toggle
                checked={state.autostart}
                onChange={(v) =>
                  api
                    .setAutostart(v)
                    .then(() => setAutostartError(null))
                    .catch((e) => setAutostartError(String(e)))
                }
              />
            </PrefsRow>
            {autostartError && (
              <>
                <div className="divider" />
                <PrefsRow label={tr("Error", "错误")}>
                  <span style={{ color: "var(--sys-red)", fontSize: 11 }}>{autostartError}</span>
                </PrefsRow>
              </>
            )}
            <div className="divider" />
            <PrefsRow label={tr("Version", "版本")}>
              <span className="num secondary" style={{ fontSize: 11.5 }}>
                {state.version}
              </span>
            </PrefsRow>
          </PrefsGroup>
          <PrefsGroup
            title={tr("Model prices", "模型价格")}
            desc={
              state.repricing
                ? tr("Recalculating costs with the new prices…", "正在按新价格重算历史费用…")
                : tr(
                    "USD per million tokens, for the Codex, Claude Code and Antigravity models in Statistics › Models. Grok costs come from its own logs, so it isn't listed. Press Enter or leave a field to save; past costs are recalculated.",
                    "美元 / 百万 Token。列出统计 · 模型明细里出现过的 Codex、Claude Code、Antigravity 模型；Grok 的费用直接取自它的日志，不在此列。回车或离开输入框即保存，历史费用会按新价格重算",
                  )
            }
          >
            <ModelPrices state={state} buckets={usage?.buckets ?? []} />
          </PrefsGroup>
          <p className="group-note tertiary">
            {tr(`yybar ${state.version} for Windows · quota and usage for Codex, Claude Code, Grok and Antigravity`, `yybar ${state.version} Windows 版 · Codex、Claude Code、Grok 和 Antigravity 的额度与用量`)}
          </p>
        </Section>
      </SectionedPage>
      {confirm && (
        <ConfirmDialog
          title={tr("Remove this account from yybar?", "从 yybar 中删除这个账号？")}
          message={tr(
            `yybar stops showing and refreshing it. The ${displayName[confirm]} CLI stays signed in. It comes back if the CLI signs in to another account, or use "Restore" below.`,
            `yybar 将不再显示和刷新它，本机 ${displayName[confirm]} CLI 的登录不受影响。CLI 换成其他账号后会重新出现，也可以在下方「恢复」。`,
          )}
          confirmLabel={tr("Remove", "删除")}
          onConfirm={() => {
            api.removeLocalAccount(confirm);
            setConfirm(null);
          }}
          onCancel={() => setConfirm(null)}
        />
      )}
      {otherConfirm && (
        <ConfirmDialog
          title={tr("Remove account?", "删除此账号？")}
          message={tr(
            `“${otherConfirm.email ?? otherConfirm.name}” will be removed from yybar and its saved credentials deleted. The account itself is not affected.`,
            `“${otherConfirm.email ?? otherConfirm.name}” 将从 yybar 中移除，并删除保存的凭据，账号本身不受影响。`,
          )}
          confirmLabel={tr("Remove", "删除")}
          onConfirm={() => {
            api.removeOtherAccount(otherConfirm.id);
            setOtherConfirm(null);
          }}
          onCancel={() => setOtherConfirm(null)}
        />
      )}
      {adding && <AddAccountDialog state={state} onClose={() => setAdding(false)} />}
    </>
  );
}

// ---------- PrefsGroup / PrefsRow ----------

function PrefsGroup({ title, desc, children }: { title?: string; desc?: string; children: ReactNode }) {
  return (
    <div className="prefs-group">
      {(title || desc) && (
        <div className="prefs-group-head">
          {title && <div className="prefs-group-title">{title}</div>}
          {desc && <div className="prefs-group-desc">{desc}</div>}
        </div>
      )}
      <div className="panel prefs-card">{children}</div>
    </div>
  );
}

function PrefsRow({ label, desc, children }: { label: string; desc?: string; children: ReactNode }) {
  return (
    <div className="prefs-row">
      <div className="prefs-row-text">
        <div className="prefs-row-label">{label}</div>
        {desc && <div className="prefs-row-desc">{desc}</div>}
      </div>
      <span style={{ flex: 1 }} />
      {children}
    </div>
  );
}

// ---------- 账号矩阵 ----------

function MatrixHeader() {
  return (
    <div className="matrix-row matrix-head">
      <span className="col-radio" />
      <span className="col-name">{tr("Account", "账号")}</span>
      <span className="col-enabled">{tr("On", "启用")}</span>
      <span className="col-tray">{tr("Taskbar", "任务栏")}</span>
      <span className="col-floating">{tr("HUD", "悬浮窗")}</span>
      <span className="col-quota">{tr("Quota", "额度")}</span>
      <span className="col-action" />
    </div>
  );
}

function ServiceRow({ state, service, buckets, onDelete }: { state: StateSnapshot; service: ServiceView; buckets: UsagePayload["buckets"]; onDelete: () => void }) {
  const s = state.settings;
  const keys = SETTING_KEYS[service.app];
  const detected = service.detected;
  const enabled = Boolean(s[keys.enabled]);
  const notDetected =
    service.app === "agy" ? tr("agy CLI not found", "没有找到 agy CLI") : tr("Not detected", "未识别");
  return (
    <div className="matrix-row">
      <span className="col-radio">
        {detected && <span className="in-use-dot" title={tr("In use by the CLI on this PC", "本机 CLI 正在使用的账号")} />}
      </span>
      <span className="col-name" style={{ opacity: enabled || !detected ? 1 : 0.5 }}>
        <ServiceTile app={service.app} size={26} logoSize={15} radius={7} />
        <span className="name-text">
          <span className="name-line">
            <b>{displayName[service.app]}</b>
            {detected && service.plan && <PlanTag plan={service.plan} app={service.app} />}
            {detected && service.renewal && <RenewalTag renewal={service.renewal} />}
          </span>
          <span className={`email ${detected ? "" : "missing"}`}>{detected ? service.email ?? "—" : notDetected}</span>
        </span>
      </span>
      <span className="col-enabled">
        <Toggle small checked={enabled} disabled={!detected} onChange={(v) => api.updateSettings({ [keys.enabled]: v })} title={tr("Show and refresh this account's quota", "显示并刷新这个账号的额度")} />
      </span>
      <span className="col-tray">
        <Checkbox checked={Boolean(s[keys.tray])} disabled={!enabled || !detected} onChange={(v) => api.updateSettings({ [keys.tray]: v })} />
      </span>
      <span className="col-floating">
        <Checkbox
          checked={Boolean(s[keys.floating])}
          disabled={!enabled || !detected || !s.floatingEnabled}
          title={s.floatingEnabled ? "" : tr("Turn on the floating window on the Display page first.", "先在「显示」页开启悬浮窗")}
          onChange={(v) => api.updateSettings({ [keys.floating]: v })}
        />
      </span>
      <span className="col-quota">{detected && <QuotaButton>{() => <QuotaCard state={state} service={service} buckets={buckets} />}</QuotaButton>}</span>
      <span className="col-action">
        {detected && (
          <button className="icon-button" title={tr("Remove", "删除")} onClick={onDelete}>
            <Icon name="minusCircle" size={14} />
          </button>
        )}
      </span>
    </div>
  );
}

/** 其他账号一行：左侧空心圆点一下把本机 CLI 切换到它（切换中转圈，期间其他行不能点）；启用 / 任务栏 / 悬浮窗；查看额度；删除。 */
function OtherRow({ state, service, account, buckets, onDelete }: {
  state: StateSnapshot;
  service: ServiceView;
  account: OtherAccountView;
  buckets: UsagePayload["buckets"];
  onDelete: () => void;
}) {
  const s = state.settings;
  const switching = state.switching;
  const error = account.refresh.lastError;
  return (
    <div className="matrix-row">
      <span className="col-radio">
        {account.switchable &&
          (switching === account.id ? (
            <span className="spinner small" title={tr("Switching…", "正在切换…")} />
          ) : (
            <button
              className="switch-radio"
              disabled={switching != null}
              title={tr(`Switch the ${displayName[account.app]} CLI on this PC to this account`, `把本机 ${displayName[account.app]} CLI 切换到这个账号`)}
              onClick={() => api.switchAccount(account.id)}
            />
          ))}
      </span>
      <span className="col-name" style={{ opacity: account.enabled ? 1 : 0.5 }}>
        <ServiceTile app={account.app} size={26} logoSize={15} radius={7} />
        <span className="name-text">
          <span className="name-line">
            <b>{otherTitle(account)}</b>
            {account.plan && <PlanTag plan={account.plan} app={account.app} />}
            {account.renewal && <RenewalTag renewal={account.renewal} />}
            {error && (
              <span className="row-warning" title={error}>
                <Icon name="warning" size={11} />
              </span>
            )}
          </span>
          <span className="email">{account.email ?? account.name}</span>
        </span>
      </span>
      <span className="col-enabled">
        <Toggle small checked={account.enabled} onChange={(v) => api.updateOtherAccount(account.id, { enabled: v })} title={tr("Refresh this account's quota", "刷新这个账号的额度")} />
      </span>
      <span className="col-tray">
        <Checkbox checked={account.showInTray} disabled={!account.enabled} onChange={(v) => api.updateOtherAccount(account.id, { showInTray: v })} />
      </span>
      <span className="col-floating">
        <Checkbox
          checked={account.showInFloating}
          disabled={!account.enabled || !s.floatingEnabled}
          title={s.floatingEnabled ? "" : tr("Turn on the floating window on the Display page first.", "先在「显示」页开启悬浮窗")}
          onChange={(v) => api.updateOtherAccount(account.id, { showInFloating: v })}
        />
      </span>
      <span className="col-quota">
        <QuotaButton>{() => <QuotaCard state={state} service={service} other={account} buckets={buckets} />}</QuotaButton>
      </span>
      <span className="col-action">
        <button className="icon-button" title={tr("Remove", "删除")} onClick={onDelete}>
          <Icon name="minusCircle" size={14} />
        </button>
      </span>
    </div>
  );
}

/** 「查看额度」按钮 + 浮层（点外面或 Esc 收起）。 */
function QuotaButton({ children }: { children: () => ReactNode }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    const esc = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    setTimeout(() => window.addEventListener("mousedown", close), 0);
    window.addEventListener("keydown", esc);
    return () => {
      window.removeEventListener("mousedown", close);
      window.removeEventListener("keydown", esc);
    };
  }, [open]);
  return (
    <span ref={ref} style={{ position: "relative", display: "inline-flex" }}>
      <button className={`icon-button ${open ? "accent" : ""}`} title={tr("View quota", "查看额度")} onClick={() => setOpen(!open)}>
        <Icon name="gauge" size={15} />
      </button>
      {open && <div className="quota-popover">{children()}</div>}
    </span>
  );
}

/** 切换本机账号的结果，显示在账号卡片下方，8 秒后淡出。 */
function SwitchNoticeView({ notice }: { notice: SwitchNotice | null }) {
  const now = useTicker(1000);
  const [shown, setShown] = useState<SwitchNotice | null>(null);
  useEffect(() => {
    if (notice && Date.now() / 1000 - notice.at < 8) setShown(notice);
  }, [notice?.seq]);
  const visible = shown != null && now - shown.at < 8;
  if (!shown) return null;
  return (
    <div className={`switch-notice ${visible ? "" : "hidden"}`}>
      <span style={{ color: shown.isError ? "var(--sys-orange)" : "var(--sys-green)" }}>
        <Icon name={shown.isError ? "warning" : "check"} size={12} />
      </span>
      <span>{shown.text}</span>
    </div>
  );
}

/** 订阅等级标签：免费灰、标准档蓝、高档紫、团队 / 企业青。 */
function PlanTag({ plan, app }: { plan: string; app: UsageApp }) {
  const p = plan.toLowerCase();
  let tier: "free" | "standard" | "premium" | "team";
  if (p.includes("free") || p === "guest") tier = "free";
  else if (["team", "business", "enterprise", "edu"].some((t) => p.includes(t))) tier = "team";
  else if (app === "codex") tier = p.includes("pro") ? "premium" : "standard";
  else if (app === "claude") tier = p.includes("max") ? "premium" : "standard";
  else tier = p.includes("heavy") ? "premium" : "standard";
  const color = { free: "var(--text-secondary)", standard: "var(--sys-blue)", premium: "var(--sys-purple)", team: "var(--sys-teal)" }[tier];
  return (
    <span className="pill-tag" style={{ color, background: tier === "free" ? "var(--fill)" : `color-mix(in srgb, ${color} 13%, transparent)` }}>
      {plan[0].toUpperCase() + plan.slice(1)}
    </span>
  );
}

/** 「10月20日续费」：3 天内续费变橙色；悬停说明来源（准确 / 按订阅开始日推算）。 */
function RenewalTag({ renewal }: { renewal: SubscriptionRenewal }) {
  const date = new Date(renewal.date * 1000);
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const d0 = new Date(date);
  d0.setHours(0, 0, 0, 0);
  const days = Math.round((d0.getTime() - today.getTime()) / 86400000);
  const soon = days <= 3;
  const basis = new Date(renewal.basis * 1000).toLocaleDateString(isChinese() ? "zh-CN" : "en-US");
  const label = isChinese()
    ? `${date.getMonth() + 1}月${date.getDate()}日续费`
    : `Renews ${date.toLocaleDateString("en-US", { month: "short", day: "numeric" })}`;
  return (
    <span
      className="pill-tag num"
      style={{ color: soon ? "var(--sys-orange)" : "var(--text-secondary)", background: soon ? "color-mix(in srgb, var(--sys-orange) 13%, transparent)" : "var(--fill)" }}
      title={
        renewal.estimated
          ? tr(`Estimated from the subscription start (${basis}), assuming monthly billing. Annual plans or plan changes may differ.`, `按订阅开始日（${basis}）每月续费推算，年付或中途改过套餐时可能不准`)
          : tr(`From the ChatGPT sign-in: the current paid period ends ${basis}. ${days} days left.`, `来自 ChatGPT 登录信息：当前付费周期到 ${basis}，还有 ${days} 天`)
      }
    >
      {label}
    </span>
  );
}

function ConfirmDialog({ title, message, confirmLabel, onConfirm, onCancel }: { title: string; message: string; confirmLabel: string; onConfirm: () => void; onCancel: () => void }) {
  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === "Escape" && onCancel();
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [onCancel]);
  return (
    <div className="dialog-backdrop" onMouseDown={onCancel}>
      <div className="dialog" onMouseDown={(e) => e.stopPropagation()}>
        <div className="dialog-title">{title}</div>
        <div className="dialog-message">{message}</div>
        <div className="dialog-actions">
          <button className="button" onClick={onCancel}>
            {tr("Cancel", "取消")}
          </button>
          <button className="button danger" onClick={onConfirm}>
            {confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
