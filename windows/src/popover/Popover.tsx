// 左键点托盘图标弹出的额度浮窗（对应 Mac `MenuBarPopoverView`，320 宽）。
// 顶部 yybar + 统计 / 设置；中间是托盘上显示的每个账号（顺序同托盘，其他账号排在同服务本机账号后面）：图标、名称、套餐、官方状态点，
// 下面 5H / WK 的剩余条和重置倒计时（Antigravity 按池写成「Gemini 5H」），刷新失败时名称旁一个小警告（悬停看原因）；
// 底部左边刷新按钮 +「x 前更新」，右边今日花费 / Token。

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { api, useAppState, useTicker, useUsage } from "../shared/api";
import { Icon, LimitBarRow, RefreshButton, ServiceTile, StatusDot } from "../shared/design";
import { compactToken, cost, relativeShort } from "../shared/format";
import { tr } from "../shared/l10n";
import { shortLabel, windowsFor } from "../shared/quota";
import { accentVar, displayName } from "../shared/services";
import { ALL_APPS, trayShows, type QuotaSnapshot, type RefreshState, type ServiceStatus, type UsageApp } from "../shared/types";
import { allTokens, dayBounds, totalsBetween } from "../shared/usage";

export function Popover() {
  const state = useAppState();
  const usage = useUsage();
  const now = useTicker(1000);
  const rootRef = useRef<HTMLDivElement>(null);
  const [translucent, setTranslucent] = useState(false);

  useEffect(() => {
    api.backdrop().then((b) => setTranslucent(b === "mica" || b === "acrylic"));
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") api.hidePopover();
      if ((e.key === "r" || e.key === "R") && e.ctrlKey) {
        e.preventDefault();
        api.refreshNow();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  // 浮窗刚好包住内容
  useLayoutEffect(() => {
    const el = rootRef.current;
    if (!el) return;
    const fit = () => api.fitPopover(Math.ceil(el.getBoundingClientRect().height));
    fit();
    const ro = new ResizeObserver(fit);
    ro.observe(el);
    return () => ro.disconnect();
  }, [state != null]);

  if (!state) return <div ref={rootRef} className={`popover ${translucent ? "translucent" : ""}`} style={{ height: 120 }} />;

  const settings = state.settings;
  /** 托盘上的一个账号：本机账号，或者勾了「任务栏」的其他账号（标题带账号名）。 */
  type Entry = { key: string; app: UsageApp; title: string; plan: string | null; quota: QuotaSnapshot | null; refresh: RefreshState; status: ServiceStatus | null };
  const entries: Entry[] = [];
  for (const app of ALL_APPS) {
    const s = state.services.find((x) => x.app === app);
    if (!s) continue;
    if (trayShows(settings, app) && !s.removed) {
      entries.push({ key: app, app, title: displayName[app], plan: s.plan, quota: s.quota, refresh: s.refresh, status: s.status });
    }
    for (const o of state.others) {
      if (o.app !== app || !o.enabled || !o.showInTray) continue;
      entries.push({ key: o.id, app, title: `${displayName[app]} · ${o.name}`, plan: o.plan, quota: o.quota, refresh: o.refresh, status: s.status });
    }
  }

  const { today, tomorrow } = dayBounds();
  const totals = totalsBetween(usage?.buckets ?? [], today, tomorrow);
  const todaySummary = tr(`Today ${cost(totals.cost)} · ${compactToken(allTokens(totals))} tokens`, `今日 ${cost(totals.cost)} · ${compactToken(allTokens(totals))} Token`);

  const shown = entries.length ? entries.map((e) => e.refresh) : state.services.filter((s) => ["codex", "claude", "grok"].includes(s.app)).map((s) => s.refresh);
  const latest = Math.max(0, ...shown.map((r) => r.lastSuccessAt ?? 0));
  const refreshed = latest > 0 ? tr(`Updated ${relativeShort(latest, now)} ago`, `${relativeShort(latest, now)} 前更新`) : tr("Waiting for data", "等待数据");

  return (
    <div ref={rootRef} className={`popover ${translucent ? "translucent" : ""}`}>
      <header className="pop-header">
        <span className="pop-title">yybar</span>
        <span style={{ flex: 1 }} />
        <button className="pop-head-button" onClick={() => api.openMain("overview")}>
          <Icon name="chart" size={13} />
          {tr("Stats", "统计")}
        </button>
        <button className="pop-head-button" onClick={() => api.openMain("services")}>
          <Icon name="gear" size={13} />
          {tr("Settings", "设置")}
        </button>
        <button className="pop-head-button" onClick={() => api.openMain("bar")}>
          <Icon name="cards" size={13} />
          bar
        </button>
      </header>
      <div className="divider" />
      {entries.length === 0 ? (
        <div className="pop-empty">{tr("No services in the tray. Choose them in Settings › Services.", "托盘没有显示任何服务，可在 设置 · 服务 里勾选。")}</div>
      ) : (
        <div className="pop-entries">
          {entries.map((s) => {
            const windows = windowsFor(s.app, s.quota);
            const pools = s.quota?.pools;
            return (
              <div className="pop-entry" key={s.key}>
                <ServiceTile app={s.app} size={22} logoSize={13} />
                <div className="pop-entry-body">
                  <div className="pop-entry-head">
                    <span className="pop-entry-title">{s.title}</span>
                    {s.plan && <span className="pop-plan">{s.plan}</span>}
                    {s.refresh.lastError && (
                      <span className="pop-warning" title={s.refresh.lastError}>
                        <Icon name="warning" size={11} />
                      </span>
                    )}
                    <span style={{ flex: 1 }} />
                    <StatusDot status={s.status} size={6} />
                  </div>
                  {windows.map((w) => (
                    <LimitBarRow
                      key={w.id}
                      label={shortLabel(w, pools)}
                      window={w.window}
                      tint={accentVar[s.app]}
                      labelWidth={pools ? 92 : 30}
                      mode={settings.resetTimeDisplay}
                      now={now}
                    />
                  ))}
                </div>
              </div>
            );
          })}
        </div>
      )}
      <div className="divider" />
      <footer className="pop-footer">
        <RefreshButton onClick={() => api.refreshNow()} size={12} />
        <span className="num secondary">{refreshed}</span>
        <span style={{ flex: 1 }} />
        <span className="num secondary">{todaySummary}</span>
      </footer>
    </div>
  );
}
