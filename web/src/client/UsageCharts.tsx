// 个人主页的三块用量图，照着 yybar App 统计页做：
// - 近 30 天：每天一根细柱，按服务叠起来，虚线是日均；可以在费用 / Tokens 之间切换，悬停看当天每个服务多少
// - 模型明细：每个模型的输入、输出、缓存读取、缓存写入、合计、费用，点表头排序；用得最多的模型后面一团小火苗
// - Token 活动：最近 53 周，每列一周（周一开头）；每天 = 热力格，每周 / 累计总量 = 每列从下往上填
import { useMemo, useState } from "react";
import { APP_LABEL, fmtInt, fmtTokens, fmtUSD, type ActivityPoint, type App, type ModelRow, type SeriesPoint } from "./api";
import { useLang, useT } from "./i18n";

const APPS: App[] = ["codex", "claude", "grok"];

/** YYYY-MM-DD 往前 / 往后挪几天（按日历日算，不受时区影响） */
function shift(day: string, n: number): string {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

/** 本地时区的今天 */
function localToday(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

/** 坐标轴上的刻度：0 和三四个好看的数，最高一格不小于最大值 */
function niceTicks(max: number): number[] {
  if (max <= 0) return [0];
  const raw = max / 3;
  const pow = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * pow).find((s) => s >= raw) ?? raw;
  // 最高一格要盖住最大值
  const out: number[] = [0];
  while (out[out.length - 1] < max) out.push(out[out.length - 1] + step);
  return out;
}

type Metric = "cost" | "tokens";

// ---------- 近 30 天 ----------

export function DailyUsage({ series, days = 30 }: { series: SeriesPoint[]; days?: number }) {
  const t = useT();
  const lang = useLang();
  const [metric, setMetric] = useState<Metric>("cost");
  const [hover, setHover] = useState<number | null>(null);
  const today = localToday();
  const dayList = Array.from({ length: days }, (_, i) => shift(today, i - days + 1));
  const byDay = new Map<string, Partial<Record<App, SeriesPoint>>>();
  for (const p of series) byDay.set(p.day, { ...byDay.get(p.day), [p.app]: p });
  const value = (d: string, a: App) => {
    const p = byDay.get(d)?.[a];
    return p ? (metric === "cost" ? p.cost_micro : p.tokens) : 0;
  };
  const totals = dayList.map((d) => APPS.reduce((s, a) => s + value(d, a), 0));
  const used = APPS.filter((a) => dayList.some((d) => value(d, a) > 0));
  const avg = totals.reduce((s, v) => s + v, 0) / days;
  const ticks = niceTicks(Math.max(...totals, 1));
  const top = ticks[ticks.length - 1] || 1;
  const fmt = (v: number) => (metric === "cost" ? fmtUSD(v) : fmtTokens(v));
  const fmtAxis = (v: number) => (metric === "cost" ? `$${fmtInt(Math.round(v / 1e6))}` : fmtTokens(v));
  const label = (d: string) => `${Number(d.slice(5, 7))}/${Number(d.slice(8))}`;
  const empty = totals.every((v) => !v);

  return (
    <section className="card-box usage-panel">
      <div className="usage-head">
        <h2>{t("近 30 天", "Last 30 days")}</h2>
        <div className="usage-tools">
          <span className="legend">
            {(used.length ? used : APPS).map((a) => (
              <span key={a}>
                <i className={`dot fill-${a}`} /> {APP_LABEL[a]}
              </span>
            ))}
          </span>
          <div className="seg seg-small" role="tablist">
            <button role="tab" aria-selected={metric === "cost"} onClick={() => setMetric("cost")}>{t("费用", "Cost")}</button>
            <button role="tab" aria-selected={metric === "tokens"} onClick={() => setMetric("tokens")}>Tokens</button>
          </div>
        </div>
      </div>
      {empty ? (
        <p className="empty">{t("这段时间没有用量", "No usage in this range")}</p>
      ) : (
        <div className="daily">
          <div className="daily-plot" onMouseLeave={() => setHover(null)}>
            {ticks.map((v) => (
              <div key={v} className="daily-grid" style={{ bottom: `${(v / top) * 100}%` }}>
                <span>{fmtAxis(v)}</span>
              </div>
            ))}
            <div className="daily-avg" style={{ bottom: `${(avg / top) * 100}%` }}>
              <span>
                {t("日均", "avg")} {fmt(avg)}
              </span>
            </div>
            <div className="daily-bars">
              {dayList.map((d, i) => (
                <div key={d} className={`daily-col${hover !== null && hover !== i ? " dim" : ""}`} onMouseEnter={() => setHover(i)}>
                  <div className="daily-stack" style={{ height: `${(totals[i] / top) * 100}%` }}>
                    {APPS.map((a) => {
                      const v = value(d, a);
                      return v ? <i key={a} className={`fill-${a}`} style={{ flexGrow: v }} /> : null;
                    })}
                  </div>
                  {hover === i && (
                    <div className={`daily-tip${i > days * 0.7 ? " tip-left" : i < days * 0.3 ? " tip-right" : ""}`}>
                      <b>{lang === "zh" ? `${Number(d.slice(5, 7))}月${Number(d.slice(8))}日` : label(d)}</b>
                      {(used.length ? used : APPS).map((a) => (
                        <span key={a}>
                          <i className={`dot fill-${a}`} /> {APP_LABEL[a]}
                          <em>{fmt(value(d, a))}</em>
                        </span>
                      ))}
                    </div>
                  )}
                </div>
              ))}
            </div>
          </div>
          <div className="daily-x">
            {dayList.map((d, i) => (
              <span key={d}>{i % 5 === (days - 1) % 5 ? label(d) : ""}</span>
            ))}
          </div>
        </div>
      )}
    </section>
  );
}

// ---------- 模型明细 ----------

type Col = "model" | "input" | "output" | "cache_read" | "cache_write" | "tokens" | "cost_micro";

export function ModelDetail({ models }: { models: ModelRow[] }) {
  const t = useT();
  const [sort, setSort] = useState<{ col: Col; desc: boolean }>({ col: "tokens", desc: true });
  const hottest = models.reduce<ModelRow | null>((best, m) => (!best || m.tokens > best.tokens ? m : best), null);
  const rows = [...models].sort((a, b) => {
    const d = sort.col === "model" ? a.model.localeCompare(b.model) : a[sort.col] - b[sort.col];
    return sort.desc ? -d : d;
  });
  const cols: { col: Col; label: string }[] = [
    { col: "model", label: t("模型", "Model") },
    { col: "input", label: t("输入", "Input") },
    { col: "output", label: t("输出", "Output") },
    { col: "cache_read", label: t("缓存读取", "Cache read") },
    { col: "cache_write", label: t("缓存写入", "Cache write") },
    { col: "tokens", label: t("合计", "Total") },
    { col: "cost_micro", label: t("费用", "Cost") },
  ];
  const click = (col: Col) => setSort((s) => (s.col === col ? { col, desc: !s.desc } : { col, desc: col !== "model" }));

  return (
    <section className="card-box">
      <h2>{t("模型明细", "Models")}</h2>
      {!models.length ? (
        <p className="empty">{t("还没有数据。", "No data yet.")}</p>
      ) : (
        <div className="table-scroll">
          <table className="table model-table">
            <thead>
              <tr>
                {cols.map((c) => (
                  <th key={c.col} className={c.col === "model" ? "" : "num"} aria-sort={sort.col === c.col ? (sort.desc ? "descending" : "ascending") : undefined}>
                    <button className={`th-sort${sort.col === c.col ? " on" : ""}`} onClick={() => click(c.col)}>
                      {c.label}
                      <i>{sort.col === c.col ? (sort.desc ? "↓" : "↑") : ""}</i>
                    </button>
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map((m) => (
                <tr key={`${m.app}/${m.model}`}>
                  <td>
                    <i className={`dot fill-${m.app}`} title={APP_LABEL[m.app]} /> {m.model}
                    {m === hottest && <HotFlame title={t("用得最多", "Most used")} />}
                  </td>
                  <td className="num">{fmtTokens(m.input)}</td>
                  <td className="num">{fmtTokens(m.output)}</td>
                  <td className="num">{fmtTokens(m.cache_read)}</td>
                  <td className="num">
                    {m.cache_write || m.app === "claude" ? (
                      fmtTokens(m.cache_write)
                    ) : (
                      <span className="muted" title={t("这个服务的日志不单独记录缓存写入", "This service doesn't log cache writes separately")}>—</span>
                    )}
                  </td>
                  <td className="num strong">{fmtTokens(m.tokens)}</td>
                  <td className="num">{fmtUSD(m.cost_micro)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

/** 用得最多的模型后面那团火苗：一直在小幅地蹦 */
function HotFlame({ title }: { title: string }) {
  return (
    <span className="hot-flame" title={title} aria-label={title}>
      <svg viewBox="0 0 12 14" aria-hidden>
        <defs>
          <linearGradient id="hot-flame-g" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#ff4533" />
            <stop offset="1" stopColor="#ffa81f" />
          </linearGradient>
        </defs>
        <path d="M6 .5c.5 2.6 3.2 3.9 3.9 6.6.8 3.2-1.3 6.1-3.9 6.1S1.3 11 2 8c.3-1.5 1.3-2.4 1.6-3.6.3 1.3.9 2 1.7 2.3C5.1 4.7 5.2 2.4 6 .5z" fill="url(#hot-flame-g)" />
      </svg>
    </span>
  );
}

// ---------- Token 活动 ----------

const WEEKS = 53;
type Mode = "daily" | "weekly" | "cumulative";

export function TokenActivity({ activity }: { activity: ActivityPoint[] }) {
  const t = useT();
  const lang = useLang();
  const [mode, setMode] = useState<Mode>("daily");
  const [hover, setHover] = useState<{ col: number; row: number } | null>(null);
  const model = useMemo(() => buildActivity(activity), [activity]);
  const { daily, starts, today, weekTotals, cumulative, thresholds, streaks, total, peak } = model;
  const values = mode === "weekly" ? weekTotals : cumulative;
  const maxValue = Math.max(...values, 1);

  const level = (v: number) => (v <= 0 ? 0 : v <= thresholds[0] ? 1 : v <= thresholds[1] ? 2 : v <= thresholds[2] ? 3 : 4);
  const longDate = (d: string) => (lang === "zh" ? `${d.slice(0, 4)}年${Number(d.slice(5, 7))}月${Number(d.slice(8))}日` : new Date(`${d}T00:00:00Z`).toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" }));
  const shortDate = (d: string) => (lang === "zh" ? `${Number(d.slice(5, 7))}月${Number(d.slice(8))}日` : new Date(`${d}T00:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" }));
  const tokens = (v: number) => t(`${fmtTokens(v)} 个 Token`, `${fmtTokens(v)} tokens`);
  const tip = (col: number, row: number): string[] | null => {
    if (mode === "daily") {
      const d = shift(starts[col], row);
      return d > today ? null : [shortDate(d), tokens(daily.get(d) ?? 0)];
    }
    if (mode === "weekly") return [t(`${longDate(starts[col])} 起的一周`, `Week of ${longDate(starts[col])}`), tokens(weekTotals[col])];
    return [t(`累计至 ${longDate(starts[col])} 起的一周`, `Total through week of ${longDate(starts[col])}`), tokens(cumulative[col])];
  };
  const cellClass = (col: number, row: number) => {
    if (mode === "daily") {
      const d = shift(starts[col], row);
      if (d > today) return "act-cell act-future";
      return `act-cell act-l${level(daily.get(d) ?? 0)}`;
    }
    const v = values[col];
    const filled = v > 0 ? Math.max(1, Math.round((v / maxValue) * 7)) : 0;
    if (row < 7 - filled) return "act-cell act-l0";
    return `act-cell act-bar${hover?.col === col ? " act-bar-hover" : ""}`;
  };
  // 月份标签写在每个月第一周那一列；离下一个标签不到 3 列的（最左边半个月）不写，免得挤在一起
  const firsts = starts.map((s, i) => (i === 0 || s.slice(5, 7) !== starts[i - 1].slice(5, 7)) && i < starts.length - 2);
  const months = starts.map((s, i) => (firsts[i] && !firsts.slice(i + 1, i + 3).some(Boolean) ? s : null));
  const shown = hover && tip(hover.col, hover.row);

  return (
    <section className="card-box">
      <div className="act-summary">
        <div><b>{fmtTokens(total)}</b><span>{t("累计 Token 数", "Total tokens")}</span></div>
        <div><b>{fmtTokens(peak)}</b><span>{t("Token 使用峰值", "Peak day")}</span></div>
        <div><b>{t(`${streaks.longest} 天`, `${streaks.longest} days`)}</b><span>{t("最长连续天数", "Longest streak")}</span></div>
        <div><b>{t(`${streaks.current} 天`, `${streaks.current} days`)}</b><span>{t("当前连续天数", "Current streak")}</span></div>
      </div>
      <div className="usage-head">
        <h2>{t("Token 活动", "Token activity")}</h2>
        <div className="act-modes">
          {(
            [
              ["daily", t("每天", "Daily")],
              ["weekly", t("每周", "Weekly")],
              ["cumulative", t("累计总量", "Cumulative")],
            ] as const
          ).map(([m, label]) => (
            <button key={m} className={mode === m ? "on" : ""} onClick={() => (setMode(m), setHover(null))}>
              {label}
            </button>
          ))}
        </div>
      </div>
      <div className="act-wrap">
        <div className={`act-grid act-${mode}`} onMouseLeave={() => setHover(null)}>
          {starts.map((s, col) => (
            <div key={s} className="act-col">
              {Array.from({ length: 7 }, (_, row) => (
                <i key={row} className={cellClass(col, row)} onMouseEnter={() => setHover({ col, row })} />
              ))}
            </div>
          ))}
          {shown && hover && (
            <div
              className="act-tip"
              style={{
                left: `${((hover.col + 0.5) / WEEKS) * 100}%`,
                top: `${mode === "daily" ? (hover.row / 7) * 100 : 0}%`,
                translate: `${hover.col > WEEKS * 0.8 ? "-90%" : hover.col < WEEKS * 0.2 ? "-10%" : "-50%"} calc(-100% - 6px)`,
              }}
            >
              <span>{shown[0]}</span>
              <b>{shown[1]}</b>
            </div>
          )}
        </div>
        <div className="act-months">
          {months.map((m, i) => (
            <span key={i}>{m ? (lang === "zh" ? `${Number(m.slice(5, 7))}月` : new Date(`${m}T00:00:00Z`).toLocaleDateString("en-US", { month: "short", timeZone: "UTC" })) : ""}</span>
          ))}
        </div>
      </div>
    </section>
  );
}

function buildActivity(activity: ActivityPoint[]) {
  const daily = new Map(activity.map((p) => [p.day, p.tokens]));
  const today = localToday();
  // 这周的周一，往前数 52 周
  const dow = (new Date(`${today}T00:00:00Z`).getUTCDay() + 6) % 7;
  const thisWeek = shift(today, -dow);
  const starts = Array.from({ length: WEEKS }, (_, i) => shift(thisWeek, (i - WEEKS + 1) * 7));
  const weekTotals = starts.map((s) => Array.from({ length: 7 }, (_, k) => daily.get(shift(s, k)) ?? 0).reduce((a, b) => a + b, 0));
  let running = activity.filter((p) => p.day < starts[0]).reduce((a, p) => a + p.tokens, 0);
  const cumulative = weekTotals.map((w) => (running += w));
  // 每天的四档：这 53 周里有用量的日子按 25% / 50% / 75% 分位切开
  const nonzero = activity.filter((p) => p.day >= starts[0] && p.tokens > 0).map((p) => p.tokens).sort((a, b) => a - b);
  const q = (f: number) => nonzero[Math.min(nonzero.length - 1, Math.floor(f * nonzero.length))] ?? 0;
  const thresholds = [q(0.25), q(0.5), q(0.75)];
  // 连续天数：有 token 的日子算「用了」；当前连续从今天往回数，今天还没用就从昨天开始
  const days = [...daily.keys()].filter((d) => (daily.get(d) ?? 0) > 0).sort();
  let longest = 0, run = 0, prev = "";
  for (const d of days) {
    run = prev && shift(prev, 1) === d ? run + 1 : 1;
    prev = d;
    longest = Math.max(longest, run);
  }
  let current = 0;
  let d = (daily.get(today) ?? 0) > 0 ? today : shift(today, -1);
  while ((daily.get(d) ?? 0) > 0) {
    current++;
    d = shift(d, -1);
  }
  const values = [...daily.values()];
  return {
    daily, starts, today, weekTotals, cumulative, thresholds,
    streaks: { longest, current },
    total: values.reduce((a, b) => a + b, 0),
    peak: Math.max(0, ...values),
  };
}
