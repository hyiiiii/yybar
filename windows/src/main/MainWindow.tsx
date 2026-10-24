// 主窗口（对应 Mac `MainWindowRootView`）：侧边栏（统计 / 设置）+ 内容区。
// Ctrl+R 立即刷新，Ctrl+1 统计，Ctrl+, 设置，Ctrl+Shift+S 显示 / 隐藏侧边栏。

import { useCallback, useEffect, useMemo, useState } from "react";
import { api, useAppState, useEvent, useUsage } from "../shared/api";
import { Icon, RefreshButton } from "../shared/design";
import { relativeShort } from "../shared/format";
import { tr } from "../shared/l10n";
import { ALL_TABS, SETTINGS_PAGES, STATS_PAGES, isStats, tabIcon, tabTitle, type MainTab } from "./tabs";
import { loadUiState, uiValue, setUiValue } from "./uiState";
import type { ScrollRequest } from "./SectionedPage";
import { StatsView } from "./stats/StatsView";
import { SettingsView } from "./settings/SettingsView";
import { StatsIndex } from "./stats/data";

export function MainWindow() {
  const state = useAppState();
  const usage = useUsage();
  const [ready, setReady] = useState(false);
  const [active, setActive] = useState<MainTab>("overview");
  const [request, setRequest] = useState<ScrollRequest>({ tab: "overview", seq: 0, animated: false });
  const [sidebar, setSidebar] = useState(true);

  const select = useCallback((tab: MainTab, animated = true) => {
    setActive(tab);
    setRequest((r) => ({ tab, seq: r.seq + 1, animated }));
    setUiValue("mainTab", tab);
  }, []);

  useEffect(() => {
    (async () => {
      await loadUiState();
      const pending = await api.takePendingTab();
      const tab = (ALL_TABS.includes(pending as MainTab) ? pending : uiValue<MainTab>("mainTab", "overview")) as MainTab;
      setSidebar(uiValue("sidebar", true));
      setReady(true);
      select(tab, false);
    })();
  }, [select]);

  useEvent<string>("navigate", (tab) => {
    if (ALL_TABS.includes(tab as MainTab)) select(tab as MainTab);
  });

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!e.ctrlKey) return;
      if (e.key === "r" || e.key === "R") {
        e.preventDefault();
        api.refreshNow();
      } else if (e.key === "1") {
        e.preventDefault();
        select("overview");
      } else if (e.key === ",") {
        e.preventDefault();
        select("services");
      } else if (e.shiftKey && (e.key === "S" || e.key === "s")) {
        e.preventDefault();
        setSidebar((v) => {
          setUiValue("sidebar", !v);
          return !v;
        });
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [select]);

  const index = useMemo(() => (state && usage ? new StatsIndex(usage.buckets, state) : null), [usage, state?.prices]);

  if (!state || !ready) return <div className="main-loading" />;

  const latest = Math.max(0, ...state.services.map((s) => s.refresh.lastSuccessAt ?? 0));

  return (
    <div className="main-root">
      {sidebar && (
        <aside className="sidebar">
          <SidebarGroup title={tr("Statistics", "统计")} pages={STATS_PAGES} active={active} onSelect={select} />
          <SidebarGroup title={tr("Settings", "设置")} pages={SETTINGS_PAGES} active={active} onSelect={select} />
          <span style={{ flex: 1 }} />
          <div className="sidebar-footer">
            <span className="num tertiary" title={tr("Last quota refresh", "上次额度刷新")}>
              {latest > 0 ? tr(`${relativeShort(latest)} ago`, `${relativeShort(latest)} 前`) : ""}
            </span>
            <span style={{ flex: 1 }} />
            <RefreshButton onClick={() => api.refreshNow()} size={13} />
          </div>
        </aside>
      )}
      <main className="content">
        <button
          className="icon-button sidebar-toggle"
          title={sidebar ? tr("Hide sidebar (Ctrl+Shift+S)", "隐藏侧边栏（Ctrl+Shift+S）") : tr("Show sidebar (Ctrl+Shift+S)", "显示侧边栏（Ctrl+Shift+S）")}
          onClick={() =>
            setSidebar((v) => {
              setUiValue("sidebar", !v);
              return !v;
            })
          }
        >
          <Icon name="sidebar" size={14} />
        </button>
        {isStats(active) ? (
          <StatsView state={state} index={index} active={active} request={request} onActive={setActive} />
        ) : (
          <SettingsView state={state} usage={usage} active={active} request={request} onActive={setActive} />
        )}
      </main>
    </div>
  );
}

function SidebarGroup({ title, pages, active, onSelect }: { title: string; pages: MainTab[]; active: MainTab; onSelect: (t: MainTab) => void }) {
  return (
    <div className="sidebar-group">
      <div className="sidebar-group-title">{title}</div>
      {pages.map((p) => (
        <button key={p} className={`sidebar-item ${active === p ? "active" : ""}`} onClick={() => onSelect(p)}>
          <Icon name={tabIcon[p]} size={14} />
          <span>{tabTitle(p)}</span>
        </button>
      ))}
    </div>
  );
}
