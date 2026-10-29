// 设置 · 账号每行「查看额度」的浮层（对应 Mac `QuotaCardView`）：本机账号与其他账号同一张卡。
// 头部 tile + 服务名（本机账号「使用中」）+ 邮箱 · 订阅 + 官方状态点；中间 5H | WK 两块并列（Grok 只有一个周期）；
// 底部今日 / 本周花费（来自本地日志，仅本机账号）+ 更新时间。

import { useTicker } from "../../shared/api";
import { ProgressBar, ResetTimeText, ServiceTile, StatusDot, statusColor } from "../../shared/design";
import { costInt, relativeShort } from "../../shared/format";
import { tr } from "../../shared/l10n";
import { hasDisplayableCost } from "../../shared/pricing";
import { remaining, windowsFor, type CardWindow } from "../../shared/quota";
import { displayName, providerName } from "../../shared/services";
import type { OtherAccountView, RefreshState, ServiceView, StateSnapshot, UsageBucket } from "../../shared/types";
import { dayBounds } from "../../shared/usage";

export function subtitleOf(email: string | null, plan: string | null, fallback: string) {
  const parts = [email, plan ? plan[0].toUpperCase() + plan.slice(1) : null].filter(Boolean);
  return parts.length ? parts.join(" · ") : fallback;
}

/** 其他账号的标题：服务名 + 别名（Google 账号写 Gemini · Antigravity）。 */
export function otherTitle(o: OtherAccountView): string {
  const base = o.provider === "google" ? "Gemini · Antigravity" : displayName[o.app];
  if (o.alias) return `${base} · ${o.alias}`;
  // 其他 Codex 目录里的账号：带上目录名，和主目录的本机账号区分开
  return o.home ? `${base} · ${dirName(o.home)}` : base;
}

/** 路径的最后一段（目录名） */
export function dirName(path: string): string {
  return path.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || path;
}

function refreshText(s: RefreshState, now: number) {
  if (s.inFlight) return tr("Refreshing…", "正在刷新…");
  if (s.backoffUntil && s.backoffUntil > now) {
    const sec = Math.round(s.backoffUntil - now);
    return tr(`Retry in ${sec}s`, `${sec} 秒后重试`);
  }
  if (!s.lastSuccessAt) return tr("Not updated yet", "尚未更新");
  const age = relativeShort(s.lastSuccessAt, now);
  return tr(`Updated ${age} ago`, `${age} 前更新`);
}

export function QuotaCard({ state, service, other, buckets }: { state: StateSnapshot; service: ServiceView; other?: OtherAccountView; buckets: UsageBucket[] }) {
  const now = useTicker(1000);
  const quota = other ? other.quota : service.quota;
  const refresh = other ? other.refresh : service.refresh;
  const windows = windowsFor(service.app, quota);
  const { today, tomorrow, weekStart } = dayBounds();
  const spend = (from: string): number | null => {
    let sum = 0;
    for (const b of buckets) {
      if (b.app !== service.app || b.day < from || b.day >= tomorrow) continue;
      if (!hasDisplayableCost(state, b.app, b.model, b.costUSD)) return null;
      sum += b.costUSD;
    }
    return sum;
  };
  const error = refresh.lastError?.replace(/\n/g, " ").trim();
  return (
    <div className="quota-card">
      <div className="qc-header">
        <ServiceTile app={service.app} size={30} logoSize={17} radius={8} />
        <div className="qc-titles">
          <div className="qc-title">
            {other ? otherTitle(other) : displayName[service.app]}
            {!other && <span className="in-use-tag">{tr("In use", "使用中")}</span>}
          </div>
          <div className="qc-subtitle">
            {other ? subtitleOf(other.email, other.plan, other.name) : subtitleOf(service.email, service.plan, providerName[service.app])}
          </div>
        </div>
        <span style={{ flex: 1 }} />
        <StatusDot status={service.status} size={7} />
      </div>
      <div className={`qc-windows ${windows.length > 2 ? "grid" : ""}`}>
        {windows.map((w) => (
          <WindowBlock key={w.id} item={w} mode={state.settings.resetTimeDisplay} now={now} />
        ))}
      </div>
      <div className="qc-footer">
        {!other && (
          <>
            <span className="qc-cost">
              <span className="secondary">{tr("Today", "今日")}</span> <b className="num">{costInt(spend(today))}</b>
            </span>
            <span className="qc-cost">
              <span className="secondary">{tr("This week", "本周")}</span> <b className="num">{costInt(spend(weekStart))}</b>
            </span>
          </>
        )}
        <span style={{ flex: 1 }} />
        <span className="secondary num" style={{ fontSize: 10.5 }}>
          {refreshText(refresh, now)}
        </span>
      </div>
      {error && <div className="qc-error">{error.length > 110 ? error.slice(0, 107) + "…" : error}</div>}
    </div>
  );
}

function WindowBlock({ item, mode, now }: { item: CardWindow; mode: "relative" | "absolute"; now: number }) {
  const rem = remaining(item.window);
  const color = item.window ? statusColor(rem) : "var(--text-secondary)";
  return (
    <div className="qc-block">
      <div className="qc-block-label">{item.label}</div>
      <div className="qc-big num" style={{ color }}>
        {rem == null ? "--" : Math.round(rem)}
        <span className="qc-pct">%</span>
      </div>
      <ProgressBar value={(rem ?? 0) / 100} color={color} height={5} />
      <div className="qc-reset">
        {tr("Resets", "重置")} <ResetTimeText resetsAt={item.window?.resetsAt} mode={mode} now={now} />
      </div>
    </div>
  );
}
