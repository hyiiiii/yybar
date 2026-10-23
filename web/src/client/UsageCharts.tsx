// 个人主页的用量统计，照着 yybar App 的统计页做。最上面一排服务筛选（全部 / Codex / Claude / Grok，带各家的标），
// 下面三块都跟着筛选走：
// - Token 活动：四格汇总 + 最近 53 周，每列一周（周一开头）；每天 = 热力格，每周 / 累计总量 = 每列从下往上填
// - 每日用量：近 30 天每天一根柱，按服务叠起来，虚线是日均；可以在费用 / Tokens 之间切换，悬停看当天每个服务多少
// - 模型明细：今天 / 7 天 / 30 天，每个模型的输入、输出、缓存读取、缓存写入、合计、费用，点表头排序；用得最多的后面一团小火苗
import { useMemo, useState } from "react";
import { APP_LABEL, fmtInt, fmtTokens, fmtUSD, type ActivityPoint, type App, type ModelRow, type SeriesPoint } from "./api";
import { useLang, useT } from "./i18n";
import { SUIT_GLYPH, type Suit } from "./suits";

const APPS: App[] = ["codex", "claude", "grok"];
const APP_SUIT: Record<App, Suit> = { codex: "gpt", claude: "claude", grok: "grok" };
/** 筛选按钮上的短名 */
const APP_SHORT: Record<App, string> = { codex: "Codex", claude: "Claude", grok: "Grok" };

type Filter = "all" | App;

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

/** 坐标轴上的刻度：0 和两三个好看的数，最高一格不小于最大值 */
function niceTicks(max: number): number[] {
  if (max <= 0) return [0];
  const raw = max / 2.5;
  const pow = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * pow).find((s) => s >= raw) ?? raw;
  const out: number[] = [0];
  while (out[out.length - 1] < max) out.push(out[out.length - 1] + step);
  return out;
}

/** 服务的标（和牌面花色同一套），染成服务识别色 */
export function ServiceLogo({ app, size = 14 }: { app: App; size?: number }) {
  const g = SUIT_GLYPH[APP_SUIT[app]];
  return (
    <svg className={`svc-logo svc-${app}`} viewBox={g.viewBox} width={size} height={size} aria-label={APP_LABEL[app]} role="img">
      {g.paths.map((p, i) => (
        <path key={i} d={p.d} fillRule={p.rule} />
      ))}
    </svg>
  );
}

// ---------- 整块：筛选 + 三张图 ----------

export function UsageStats({ series, models, activity }: { series: SeriesPoint[]; models: ModelRow[]; activity: ActivityPoint[] }) {
  const t = useT();
  const [filter, setFilter] = useState<Filter>("all");
  const used = APPS.filter((a) => activity.some((p) => p.app === a) || series.some((p) => p.app === a));
  const apps = filter === "all" ? used : [filter];
  return (
    <>
      <div className="svc-filter" role="tablist" aria-label={t("按服务筛选", "Filter by service")}>
        <button role="tab" aria-selected={filter === "all"} onClick={() => setFilter("all")}>{t("全部", "All")}</button>
        {(used.length ? used : APPS).map((a) => (
          <button key={a} role="tab" aria-selected={filter === a} onClick={() => setFilter(a)}>
            <ServiceLogo app={a} />
            {APP_SHORT[a]}
          </button>
        ))}
      </div>
      <TokenActivity activity={activity} apps={apps} />
      <DailyUsage series={series} apps={apps.length ? apps : APPS} />
      <ModelDetail models={models} apps={apps} />
    </>
  );
}

// ---------- 每日用量（近 30 天） ----------

type Metric = "cost" | "tokens";

function DailyUsage({ series, apps, days = 30 }: { series: SeriesPoint[]; apps: App[]; days?: number }) {
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
  const totals = dayList.map((d) => apps.reduce((s, a) => s + value(d, a), 0));
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
        <div className="usage-title">
          <h2>{t("每日用量", "Daily usage")}</h2>
          {!empty && (
            <span className="usage-avg">
              <i />
              {t("日均", "avg")} {fmt(avg)}
            </span>
          )}
        </div>
        <div className="usage-tools">
          <span className="usage-legend">
            {apps.map((a) => (
              <ServiceLogo key={a} app={a} />
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
            <div className="daily-avg" style={{ bottom: `${(avg / top) * 100}%` }} />
            <div className="daily-bars">
              {dayList.map((d, i) => (
                <div key={d} className={`daily-col${hover !== null && hover !== i ? " dim" : ""}`} onMouseEnter={() => setHover(i)}>
                  <div className="daily-stack" style={{ height: `${(totals[i] / top) * 100}%` }}>
                    {apps.map((a) => {
                      const v = value(d, a);
                      return v ? <i key={a} className={`fill-${a}`} style={{ flexGrow: v }} /> : null;
                    })}
                  </div>
                  {hover === i && (
                    <div className={`daily-tip${i > days * 0.7 ? " tip-left" : i < days * 0.3 ? " tip-right" : ""}`}>
                      <b>{lang === "zh" ? `${Number(d.slice(5, 7))}月${Number(d.slice(8))}日` : label(d)}</b>
                      {apps.map((a) => (
                        <span key={a}>
                          <ServiceLogo app={a} size={11} /> {APP_SHORT[a]}
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

type Range = "today" | "7d" | "30d";
type Col = "model" | "input" | "output" | "cache_read" | "cache_write" | "tokens" | "cost_micro";
interface ModelTotal {
  app: App;
  model: string;
  input: number;
  output: number;
  cache_read: number;
  cache_write: number;
  tokens: number;
  cost_micro: number;
}

function ModelDetail({ models, apps }: { models: ModelRow[]; apps: App[] }) {
  const t = useT();
  const [range, setRange] = useState<Range>("30d");
  const [sort, setSort] = useState<{ col: Col; desc: boolean }>({ col: "tokens", desc: true });
  const today = localToday();
  const since = range === "today" ? today : shift(today, range === "7d" ? -6 : -29);
  // 按选的时间段、服务把每天的行加起来
  const totals = new Map<string, ModelTotal>();
  for (const r of models) {
    if (r.day < since || r.day > today || !apps.includes(r.app)) continue;
    const key = `${r.app}\u0000${r.model}`;
    const m = totals.get(key) ?? { app: r.app, model: r.model, input: 0, output: 0, cache_read: 0, cache_write: 0, tokens: 0, cost_micro: 0 };
    m.input += r.input;
    m.output += r.output;
    m.cache_read += r.cache_read;
    m.cache_write += r.cache_write;
    m.tokens += r.input + r.output + r.cache_read + r.cache_write;
    m.cost_micro += r.cost_micro;
    totals.set(key, m);
  }
  const list = [...totals.values()].filter((m) => m.tokens > 0 || m.cost_micro > 0);
  const hottest = list.reduce<ModelTotal | null>((best, m) => (!best || m.tokens > best.tokens ? m : best), null);
  const rows = list.sort((a, b) => {
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
      <div className="usage-head">
        <h2>{t("模型明细", "Models")}</h2>
        <div className="seg seg-small" role="tablist" aria-label={t("时间段", "Period")}>
          {(
            [
              ["today", t("今天", "Today")],
              ["7d", t("7 天", "7 days")],
              ["30d", t("30 天", "30 days")],
            ] as const
          ).map(([r, label]) => (
            <button key={r} role="tab" aria-selected={range === r} onClick={() => setRange(r)}>
              {label}
            </button>
          ))}
        </div>
      </div>
      {!rows.length ? (
        <p className="empty">{t("这段时间没有用量", "No usage in this range")}</p>
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
                    <ServiceLogo app={m.app} size={13} /> {m.model}
                    {m === hottest && <HotFlame title={t("这段时间用得最多", "Most used in this range")} />}
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

function TokenActivity({ activity, apps }: { activity: ActivityPoint[]; apps: App[] }) {
  const t = useT();
  const lang = useLang();
  const [mode, setMode] = useState<Mode>("daily");
  const [hover, setHover] = useState<{ col: number; row: number } | null>(null);
  const key = apps.join(",");
  const model = useMemo(() => buildActivity(activity.filter((p) => apps.includes(p.app))), [activity, key]);
  const { daily, starts, today, weekTotals, cumulative, thresholds, streaks, total, peak } = model;
  const values = mode === "weekly" ? weekTotals : cumulative;
  const maxValue = Math.max(...values, 1);
  // 只选了一个服务时用它的识别色（四档深浅），全部时用和「今天」火苗同一套暖色
  const tint = apps.length === 1 ? apps[0] : null;

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
        <div className={`act-grid act-${mode}${tint ? ` act-tint act-tint-${tint}` : ""}`} onMouseLeave={() => setHover(null)}>
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
  const daily = new Map<string, number>();
  for (const p of activity) daily.set(p.day, (daily.get(p.day) ?? 0) + p.tokens);
  const today = localToday();
  // 这周的周一，往前数 52 周
  const dow = (new Date(`${today}T00:00:00Z`).getUTCDay() + 6) % 7;
  const thisWeek = shift(today, -dow);
  const starts = Array.from({ length: WEEKS }, (_, i) => shift(thisWeek, (i - WEEKS + 1) * 7));
  const weekTotals = starts.map((s) => Array.from({ length: 7 }, (_, k) => daily.get(shift(s, k)) ?? 0).reduce((a, b) => a + b, 0));
  let running = [...daily].filter(([d]) => d < starts[0]).reduce((a, [, v]) => a + v, 0);
  const cumulative = weekTotals.map((w) => (running += w));
  // 每天的四档：这 53 周里有用量的日子按 25% / 50% / 75% 分位切开
  const nonzero = [...daily].filter(([d, v]) => d >= starts[0] && v > 0).map(([, v]) => v).sort((a, b) => a - b);
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
