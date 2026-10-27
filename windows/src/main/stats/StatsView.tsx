// 统计大页（对应 Mac `StatsView`）：顶部时间范围 + 服务筛选（作用于整页），下面依次是
// 概览（KPI、每日用量 / 单日对比、当前额度）→ 额度变化 → 模型明细 → Token 活动。

import { useMemo } from "react";
import { Icon, Segmented, ServiceLogo, StatusDot } from "../../shared/design";
import { compactToken, cost } from "../../shared/format";
import { tr } from "../../shared/l10n";
import { displayName, shortName } from "../../shared/services";
import { ALL_APPS, isEnabled, localShown, type StateSnapshot, type UsageApp } from "../../shared/types";
import { Section, SectionHeading, SectionedPage, type ScrollRequest } from "../SectionedPage";
import { STATS_PAGES, type MainTab } from "../tabs";
import { usePersisted } from "../uiState";
import { RANGES, addDays, isSingleDay, previousBounds, rangeBounds, rangeLabel, todayString, type Baseline, type Metric, type ServiceFilter, type StatsIndex, type StatsRange } from "./data";
import { Overview } from "./Overview";
import { QuotaTimeline } from "./QuotaTimeline";
import { ModelsTable } from "./ModelsTable";
import { TokenActivity } from "./TokenActivity";

export interface StatsSelections {
  range: StatsRange;
  filter: ServiceFilter;
  metric: Metric;
  baseline: Baseline;
  mergeTokens: boolean;
  customFrom: string;
  customTo: string;
}

export function StatsView({ state, index, active, request, onActive }: {
  state: StateSnapshot;
  index: StatsIndex | null;
  active: MainTab;
  request: ScrollRequest;
  onActive: (t: MainTab) => void;
}) {
  const [range, setRange] = usePersisted<StatsRange>("stats.range", "today");
  const [filter, setFilter] = usePersisted<ServiceFilter>("stats.filter", "all");
  const [metric, setMetric] = usePersisted<Metric>("stats.metric", "cost");
  const [baseline, setBaseline] = usePersisted<Baseline>("stats.baseline", "sevenDays");
  const [mergeTokens, setMergeTokens] = usePersisted("stats.mergeTokens", false);
  const [customFrom, setCustomFrom] = usePersisted("stats.customFrom", addDays(todayString(), -7));
  const [customTo, setCustomTo] = usePersisted("stats.customTo", todayString());

  const settings = state.settings;
  // 统计页列出的服务：本机登录着并启用的、有其他账号的，或者留有本地用量记录的；都没有的不出现
  const present: UsageApp[] = ALL_APPS.filter((a) => {
    const s = state.services.find((x) => x.app === a);
    return (s != null && localShown(s) && isEnabled(settings, a)) || state.others.some((o) => o.app === a) || (index?.firstDays.has(a) ?? false);
  });
  const presentKey = present.join();
  const visibleApps: UsageApp[] = useMemo(() => {
    if (filter === "all" || !present.includes(filter)) return present;
    return [filter];
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [filter, presentKey]);

  const bounds = rangeBounds(range, customFrom, customTo);
  const previous = previousBounds(range, customFrom, customTo);
  const single = isSingleDay(bounds);

  const sel: StatsSelections = { range, filter, metric, baseline, mergeTokens, customFrom, customTo };

  const chips: ServiceFilter[] = ["all", ...present];

  return (
    <div className="stats-root">
      <div className="toolbar">
        <div className="toolbar-left">
          <Segmented options={RANGES.map((r) => ({ value: r, label: rangeLabel(r) }))} value={range} onChange={setRange} />
          {range === "custom" && (
            <span className="custom-range">
              <input type="date" value={customFrom} max={customTo} onChange={(e) => e.target.value && setCustomFrom(e.target.value)} title={tr("From", "起")} />
              <span className="secondary">–</span>
              <input type="date" value={customTo} min={customFrom} max={todayString()} onChange={(e) => e.target.value && setCustomTo(e.target.value)} title={tr("To", "止")} />
            </span>
          )}
        </div>
        <div className="chips">
          {chips.map((c) => (
            <button key={c} className={`chip ${filter === c || (c === "all" && !present.includes(filter as UsageApp)) ? "active" : ""}`} onClick={() => setFilter(c)}>
              {c !== "all" && <StatusDot status={settings.showServiceStatus ? state.services.find((s) => s.app === c)?.status : null} grayWhenMissing size={7} />}
              {c === "all" ? tr("All", "全部") : shortName(c)}
            </button>
          ))}
        </div>
      </div>
      <SectionedPage sections={STATS_PAGES} request={request} active={active} onActive={onActive}>
        <Section tab="overview">
          <SectionHeading title={tr("Overview", "概览")} />
          {index ? (
            <Overview
              state={state}
              index={index}
              sel={sel}
              apps={visibleApps}
              bounds={bounds}
              previous={previous}
              single={single}
              setMetric={setMetric}
              setBaseline={setBaseline}
              setMergeTokens={setMergeTokens}
            />
          ) : (
            <div className="placeholder" style={{ height: 200 }}>
              {tr("Reading local logs…", "正在读取本地日志…")}
            </div>
          )}
        </Section>
        <Section tab="quota">
          <QuotaTimeline state={state} />
        </Section>
        <Section tab="models">
          <SectionHeading
            title={tr("Models", "模型明细")}
            subtitle={tr("Uses the time range and service filter above. Click a column to sort.", "跟随上方时间范围和服务筛选，点击表头排序。")}
          />
          <ModelsTable state={state} index={index} apps={visibleApps} bounds={bounds} />
          <div className="footnote">{tr("Unknown prices show as — and are excluded from estimated cost.", "未知定价的模型显示为 —，不计入估算费用。")}</div>
        </Section>
        <Section tab="activity">
          <SectionHeading
            title={tr("Token activity", "Token 活动")}
            subtitle={tr("All tokens including cache, over the last year. Uses the service filter above.", "最近一年的全部 Token（含缓存），跟随上方服务筛选。")}
          />
          <TokenActivity daily={index ? index.dailyTokens(visibleApps) : new Map()} filter={filter} />
        </Section>
      </SectionedPage>
    </div>
  );
}

/** 环比：中性灰，上期基数极小时封顶 >999%。 */
export function deltaText(current: number, previous: number | null | undefined, label: string): string | null {
  if (previous == null || !(previous > 0)) return null;
  const delta = ((current - previous) / previous) * 100;
  const mag = Math.abs(delta);
  return `${delta >= 0 ? "↑" : "↓"} ${mag >= 1000 ? ">999" : mag.toFixed(0)}% ${label}`;
}

export function formatMetric(value: number, metric: Metric): string {
  return metric === "cost" ? cost(value) : compactToken(value);
}

export function MergeButton({ merged, onClick, titleMerge, titleSplit }: { merged: boolean; onClick: () => void; titleMerge: string; titleSplit: string }) {
  return (
    <button className="icon-button" onClick={onClick} title={merged ? titleSplit : titleMerge}>
      <Icon name={merged ? "branch" : "merge"} size={12} />
    </button>
  );
}

export function AppLabel({ app, size = 14 }: { app: UsageApp; size?: number }) {
  return (
    <span className="app-label">
      <ServiceLogo app={app} size={size} />
      <span>{displayName[app]}</span>
    </span>
  );
}
