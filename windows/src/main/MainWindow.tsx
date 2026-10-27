// 主窗口（对应 Mac `MainWindowRootView`）：侧边栏（统计 / 设置）+ 内容区。
// Ctrl+R 立即刷新，Ctrl+1 统计，Ctrl+, 设置，Ctrl+Shift+S 显示 / 隐藏侧边栏。

import { useCallback, useEffect, useMemo, useState } from "react";
import { api, useAppState, useEvent, useUsage } from "../shared/api";
import { Icon, RefreshButton } from "../shared/design";
import { relativeShort } from "../shared/format";
import { tr } from "../shared/l10n";
import { ALL_TABS, BAR_PAGES, SETTINGS_PAGES, STATS_PAGES, isStats, tabIcon, tabTitle, type MainTab } from "./tabs";
import { BarPage, WebAvatar } from "./bar/BarPage";
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
    <div className={`main-root ${sidebar ? "" : "sidebar-hidden"}`}>
      {/* 侧边栏隐藏 / 显示时滑出滑入（对应 Mac 的 .move(edge: .leading)） */}
      <aside className={`sidebar ${sidebar ? "" : "collapsed"}`} aria-hidden={!sidebar}>
          <SidebarGroup title={tr("Statistics", "统计")} pages={STATS_PAGES} active={active} onSelect={select} />
          <SidebarGroup title={tr("Settings", "设置")} pages={SETTINGS_PAGES} active={active} onSelect={select} />
          {/* bar 是独立的一页，单独一组、没有标题 */}
          <SidebarGroup pages={BAR_PAGES} active={active} onSelect={select} />
          <span style={{ flex: 1 }} />
          {/* 左边是连上 yybar 网站后的 GitHub 头像和用户名（点了去 bar 页），右边刷新 */}
          <div className="sidebar-footer">
            {state.web.connected && state.web.profile ? (
              <button className="sidebar-account" onClick={() => select("bar")} title={tr(`Connected to yybar as @${state.web.profile.login}`, `已连接 yybar 网站：@${state.web.profile.login}`)}>
                <WebAvatar profile={state.web.profile} size={18} />
                <span>@{state.web.profile.login}</span>
              </button>
            ) : (
              <span className="num tertiary" title={tr("Last quota refresh", "上次额度刷新")}>
                {latest > 0 ? tr(`${relativeShort(latest)} ago`, `${relativeShort(latest)} 前`) : ""}
              </span>
            )}
            <span style={{ flex: 1 }} />
            <RefreshButton onClick={() => api.refreshNow()} size={13} />
          </div>
      </aside>
      {/* 侧边栏按钮：显示时在侧边栏右上角（Mac 在标题栏同一位置），隐藏后留在内容区左上角 */}
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
      <main className="content">
        {/* 统计 / 设置 / bar 之间切换时新的一页弹簧淡入（对应 Mac mainTab 变化的 spring 动画） */}
        <div key={active === "bar" ? "bar" : isStats(active) ? "stats" : "settings"} className="page-swap">
          {active === "bar" ? (
            <BarPage state={state} />
          ) : isStats(active) ? (
            <StatsView state={state} index={index} active={active} request={request} onActive={setActive} />
          ) : (
            <SettingsView state={state} usage={usage} active={active} request={request} onActive={setActive} />
          )}
        </div>
      </main>
    </div>
  );
}

function SidebarGroup({ title, pages, active, onSelect }: { title?: string; pages: MainTab[]; active: MainTab; onSelect: (t: MainTab) => void }) {
  return (
    <div className="sidebar-group">
      {title && <div className="sidebar-group-title">{title}</div>}
      {pages.map((p) => (
        <button key={p} className={`sidebar-item ${active === p ? "active" : ""}`} onClick={() => onSelect(p)}>
          <Icon name={tabIcon[p]} size={14} />
          <span>{tabTitle(p)}</span>
        </button>
      ))}
    </div>
  );
}
