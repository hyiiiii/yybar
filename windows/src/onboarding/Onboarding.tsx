// 首次启动引导（对应 Mac `OnboardingView`）：4 步 Welcome / 检测账号 / 选择显示方式 / 完成。
// 完成后记下 didCompleteOnboarding，之后启动不再显示。

import { useState, type ReactNode } from "react";
import appIcon from "../../src-tauri/icons/128x128.png";
import { api, useAppState } from "../shared/api";
import { Icon, ServiceLogo, ServiceTile, Toggle } from "../shared/design";
import { tr } from "../shared/l10n";
import { displayName, providerName } from "../shared/services";
import type { ServiceView, StateSnapshot, UsageApp } from "../shared/types";

export function Onboarding() {
  const state = useAppState();
  const [step, setStep] = useState(0);
  const next = () => setStep((s) => Math.min(s + 1, 3));
  const prev = () => setStep((s) => Math.max(s - 1, 0));
  return (
    <div className="onboarding">
      <div className="step" key={step}>
        {step === 0 && <Welcome onContinue={next} />}
        {step === 1 && state && <Detect state={state} onBack={prev} onContinue={next} />}
        {step === 2 && state && <Configure state={state} onBack={prev} onContinue={next} />}
        {step === 3 && <Ready />}
      </div>
      <div className="dots">
        {[0, 1, 2, 3].map((i) => (
          <span key={i} className={i === step ? "active" : ""} />
        ))}
      </div>
    </div>
  );
}

function Welcome({ onContinue }: { onContinue: () => void }) {
  return (
    <div className="centered">
      <img className="app-icon" src={appIcon} alt="" />
      <h1>{tr("Welcome to yybar", "欢迎使用 yybar")}</h1>
      <p className="lead">
        {tr(
          "Track Codex, Claude Code, Grok and Antigravity quota right from your taskbar. We'll detect your accounts automatically.",
          "在任务栏即时查看 Codex、Claude Code、Grok 和 Antigravity 的额度，我们将自动检测你的账号。",
        )}
      </p>
      <div className="actions-center">
        <button className="primary-button" onClick={onContinue}>
          {tr("Get started", "开始")}
        </button>
      </div>
    </div>
  );
}

function Detect({ state, onBack, onContinue }: { state: StateSnapshot; onBack: () => void; onContinue: () => void }) {
  const svc = (app: UsageApp) => state.services.find((s) => s.app === app)!;
  const also = state.agyInstalled ? (["agy"] as UsageApp[]) : [];
  return (
    <div className="page">
      <h2>{tr("We found these accounts", "检测到以下账号")}</h2>
      <div className="rows">
        {(["codex", "claude", "grok"] as UsageApp[]).map((app) => (
          <DetectedRow key={app} service={svc(app)} />
        ))}
        {also.length > 0 && (
          <div className="also panel">
            {also.map((app) => (
              <span key={app} className="also-item">
                <ServiceLogo app={app} size={13} />
                {displayName[app]}
              </span>
            ))}
            <span style={{ flex: 1 }} />
            <span className="tertiary" style={{ fontSize: 10.5 }}>
              {tr("Also found · quota only, toggle in Settings", "也已检测到 · 仅额度，可在设置里开关")}
            </span>
          </div>
        )}
      </div>
      <div className="info-card">
        <Icon name="info" size={15} />
        <div>
          <div className="info-title">{tr("Read-only access", "仅读取")}</div>
          <div className="secondary">
            {tr(
              "yybar reads your CLI sign-ins on this PC to query quota from each service. It never sends your credentials anywhere else.",
              "yybar 只读取本机 CLI 的登录信息去查询各服务的额度，不会把凭据发送到其他地方。",
            )}
          </div>
        </div>
      </div>
      <span style={{ flex: 1 }} />
      <div className="actions">
        <button className="secondary-button" onClick={onBack}>
          {tr("Back", "上一步")}
        </button>
        <span style={{ flex: 1 }} />
        <button className="primary-button" onClick={onContinue}>
          {tr("Continue", "继续")}
        </button>
      </div>
    </div>
  );
}

function DetectedRow({ service }: { service: ServiceView }) {
  const detected = service.detected;
  const subtitle = service.plan ? `${providerName[service.app]} · ${service.plan}` : providerName[service.app];
  return (
    <div className="detected panel" style={{ opacity: detected ? 1 : 0.6 }}>
      <span className={`check-box ${detected ? "on" : ""}`}>{detected && <Icon name="check" size={9} />}</span>
      <ServiceTile app={service.app} size={34} logoSize={16} radius={8} />
      <div className="detected-text">
        <div>
          <b>{displayName[service.app]}</b> <span className="tertiary">· {subtitle}</span>
        </div>
        <div className="secondary">{detected ? service.email ?? "—" : tr("Not detected — sign in with the CLI in a terminal first", "未识别——请先在终端里用 CLI 登录")}</div>
        <div className="mono tertiary">{service.source ?? "—"}</div>
      </div>
    </div>
  );
}

function ConfigureRow({ title, subtitle, children }: { title: string; subtitle: string; children: ReactNode }) {
  return (
    <div className="configure panel">
      <div>
        <div className="configure-title">{title}</div>
        <div className="secondary" style={{ fontSize: 11 }}>
          {subtitle}
        </div>
      </div>
      <span style={{ flex: 1 }} />
      {children}
    </div>
  );
}

function Configure({ state, onBack, onContinue }: { state: StateSnapshot; onBack: () => void; onContinue: () => void }) {
  const s = state.settings;
  return (
    <div className="page">
      <h2>{tr("Choose your view", "选择你想看到的方式")}</h2>
      <div className="rows">
        <ConfigureRow title={tr("Show in the taskbar", "任务栏")} subtitle={tr("One tray icon per service with its remaining percentage.", "每个服务一个托盘图标，显示剩余百分比")}>
          <div className="toggles">
            {(
              [
                ["Codex", "menuBarShowCodex"],
                ["Claude", "menuBarShowClaude"],
                ["Grok", "menuBarShowGrok"],
              ] as const
            ).map(([label, key]) => (
              <label key={key}>
                <Toggle checked={s[key]} onChange={(v) => api.updateSettings({ [key]: v })} small />
                {label}
              </label>
            ))}
          </div>
        </ConfigureRow>
        <ConfigureRow title={tr("Floating window", "桌面悬浮窗")} subtitle={tr("Pin a small always-on-top window to your desktop.", "在桌面常驻一个置顶的小悬浮窗")}>
          <label className="toggles">
            <Toggle checked={s.floatingEnabled} onChange={(v) => api.updateSettings({ floatingEnabled: v })} small />
            {tr("Enabled", "启用")}
          </label>
        </ConfigureRow>
        <ConfigureRow title={tr("Launch at sign-in", "开机自动启动")} subtitle={tr("Start yybar when you sign in to Windows.", "登录 Windows 时自动启动 yybar")}>
          <Toggle checked={state.autostart} onChange={(v) => api.setAutostart(v)} small />
        </ConfigureRow>
      </div>
      <p className="tertiary" style={{ fontSize: 11, margin: "12px 4px 0" }}>
        {tr(
          "Tip: Windows 11 puts new tray icons in the overflow (^). Drag them onto the taskbar, or turn them on in Settings › Personalization › Taskbar › Other system tray icons.",
          "提示：Windows 11 会把新托盘图标放进「^」溢出区。把它们拖到任务栏上，或在 设置 › 个性化 › 任务栏 › 其他系统托盘图标 里打开。",
        )}
      </p>
      <span style={{ flex: 1 }} />
      <div className="actions">
        <button className="secondary-button" onClick={onBack}>
          {tr("Back", "上一步")}
        </button>
        <span style={{ flex: 1 }} />
        <button className="primary-button" onClick={onContinue}>
          {tr("Continue", "继续")}
        </button>
      </div>
    </div>
  );
}

function Ready() {
  return (
    <div className="centered">
      <div className="ready-icon">
        <img className="app-icon" src={appIcon} alt="" />
        <span className="ready-check">
          <Icon name="check" size={16} />
        </span>
      </div>
      <h1>{tr("You're all set", "一切就绪")}</h1>
      <p className="lead">{tr("Open Statistics now, or just keep an eye on the taskbar.", "现在打开统计，或者直接在任务栏盯着看。")}</p>
      <div className="actions-center">
        <button className="secondary-button" onClick={() => api.finishOnboarding(false)}>
          {tr("Close", "关闭")}
        </button>
        <button className="primary-button" onClick={() => api.finishOnboarding(true)}>
          {tr("Open Statistics", "打开统计")}
        </button>
      </div>
    </div>
  );
}
