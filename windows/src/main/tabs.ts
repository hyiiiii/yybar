// 主窗口的部分（对应 Mac `MainTab`）。统计、设置共用一个侧边栏，各是一个可滚动的大页。

import { tr } from "../shared/l10n";

export type MainTab = "overview" | "quota" | "models" | "activity" | "services" | "floating" | "display" | "refresh" | "general" | "bar";

export const STATS_PAGES: MainTab[] = ["overview", "quota", "models", "activity"];
export const SETTINGS_PAGES: MainTab[] = ["services", "floating", "display", "refresh", "general"];
/** bar 是和统计、设置都不同的独立页（侧边栏单独一组，没有标题）。 */
export const BAR_PAGES: MainTab[] = ["bar"];
export const ALL_TABS: MainTab[] = [...STATS_PAGES, ...SETTINGS_PAGES, ...BAR_PAGES];

export const isStats = (t: MainTab) => STATS_PAGES.includes(t);

export function tabTitle(t: MainTab): string {
  switch (t) {
    case "overview":
      return tr("Overview", "概览");
    case "quota":
      return tr("Quota changes", "额度变化");
    case "models":
      return tr("Models", "模型明细");
    case "activity":
      return tr("Token activity", "Token 活动");
    case "services":
      return tr("Services", "服务");
    case "floating":
      return tr("Floating window", "悬浮窗");
    case "display":
      return tr("Display", "显示");
    case "refresh":
      return tr("Refresh", "刷新");
    case "general":
      return tr("General", "通用");
    case "bar":
      return "bar";
  }
}

export const tabIcon: Record<MainTab, string> = {
  overview: "pie",
  quota: "line",
  models: "cpu",
  activity: "grid",
  services: "plug",
  floating: "pip",
  display: "taskbar",
  refresh: "refresh",
  general: "gear",
  bar: "cards",
};
