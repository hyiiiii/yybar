// 个人主页的用量统计，照着 yybar App 的统计页做。最上面一排服务筛选（全部 + 用过的服务，带各家的标）；
// Grok 和 Grok Bot、Gemini 和 Antigravity 两两一组，和 App 统计页一样：默认合并成一个按钮，后面跟一个小图标按钮拆开 / 合并。
// 下面三块都跟着筛选走：
// - Token 活动：四格汇总 + 最近 53 周，每列一周（周一开头）；每天 = 热力格，每周 / 累计总量 = 每列从下往上填
// - 每日用量：近 30 天每天一根柱，按服务叠起来，虚线是日均；可以在费用 / Tokens 之间切换，悬停看当天每个服务多少
// - 模型明细：昨天 / 7 天 / 30 天 / 全部，每个模型的输入、输出、缓存读取、缓存写入、合计、费用，点表头排序；用得最多的后面一团小火苗
// Gemini 没有 token 和花费，只有回答次数：只看 Gemini 时三块都换成回答次数，其他时候 Gemini 不进柱子和热力格，悬停里写次数。
import { useLayoutEffect, useMemo, useRef, useState } from "react";
import { APP_LABEL, fmtInt, fmtTokens, fmtUSD, type ActivityPoint, type App, type ModelRow, type ModelTotalRow, type SeriesPoint } from "./api";
import { useLang, useT } from "./i18n";
import { SUIT_GLYPH } from "./suits";

const APPS: App[] = ["codex", "claude", "grok", "grokBot", "gemini", "agy"];
/** 筛选按钮上的短名 */
const APP_SHORT: Record<App, string> = { codex: "Codex", claude: "Claude", grok: "Grok", grokBot: "Grok Bot", gemini: "Gemini", agy: "Antigravity" };

type Glyph = { viewBox: string; paths: { d: string; rule?: "evenodd"; fill?: string }[] };
/** 各家的标：Codex / Claude / Grok / Gemini 和牌面花色同一套；Grok Bot、Antigravity 照 App 里的占位图形（Antigravity 是彩虹像素 A） */
const GLYPH: Record<App, Glyph> = {
  codex: SUIT_GLYPH.gpt,
  claude: SUIT_GLYPH.claude,
  grok: SUIT_GLYPH.grok,
  gemini: SUIT_GLYPH.gemini,
  grokBot: {
    viewBox: "2 2 16 16",
    paths: [{ rule: "evenodd", d: "M10 2.2a7.8 7.8 0 1 1 0 15.6 7.8 7.8 0 0 1 0-15.6zM10.94 6.01L10.80 5.83L10.62 5.69L10.40 5.60L10.18 5.57L9.95 5.60L9.74 5.69L9.55 5.83L9.41 6.01L9.32 6.23L9.29 6.45L9.32 6.68L9.41 6.89L10.56 8.89L10.70 9.07L10.88 9.21L11.10 9.30L11.32 9.33L11.55 9.30L11.76 9.21L11.95 9.07L12.09 8.89L12.18 8.67L12.21 8.45L12.18 8.22L12.09 8.01zM14.49 4.53L14.37 4.37L14.22 4.26L14.04 4.18L13.85 4.16L13.66 4.18L13.48 4.26L13.33 4.37L13.21 4.53L13.14 4.71L13.11 4.90L13.14 5.09L13.21 5.27L14.31 7.17L14.43 7.33L14.58 7.44L14.76 7.52L14.95 7.54L15.14 7.52L15.32 7.44L15.47 7.33L15.59 7.17L15.66 6.99L15.69 6.80L15.66 6.61L15.59 6.43z" }],
  },
  agy: {
    viewBox: "2.5 2.5 15 15",
    paths: [
      { fill: "#E8613C", d: "M8.6 3h1.4v1.4h-1.4zM10 3h1.4v1.4h-1.4z" },
      { fill: "#EE7A3A", d: "M7.2 4.4h1.4v1.4h-1.4zM8.6 4.4h1.4v1.4h-1.4zM10 4.4h1.4v1.4h-1.4zM11.4 4.4h1.4v1.4h-1.4z" },
      { fill: "#E3A33A", d: "M5.8 5.8h1.4v1.4h-1.4z" },
      { fill: "#F08A3C", d: "M7.2 5.8h1.4v1.4h-1.4zM8.6 5.8h1.4v1.4h-1.4zM10 5.8h1.4v1.4h-1.4zM11.4 5.8h1.4v1.4h-1.4z" },
      { fill: "#D9594F", d: "M12.8 5.8h1.4v1.4h-1.4zM10 7.2h1.4v1.4h-1.4zM11.4 7.2h1.4v1.4h-1.4zM12.8 7.2h1.4v1.4h-1.4z" },
      { fill: "#D9B13C", d: "M5.8 7.2h1.4v1.4h-1.4zM7.2 7.2h1.4v1.4h-1.4zM8.6 7.2h1.4v1.4h-1.4z" },
      { fill: "#A9BE4A", d: "M5.8 8.6h1.4v1.4h-1.4zM7.2 8.6h1.4v1.4h-1.4z" },
      { fill: "#C25A78", d: "M11.4 8.6h1.4v1.4h-1.4zM12.8 8.6h1.4v1.4h-1.4z" },
      { fill: "#7CB85A", d: "M4.4 10h1.4v1.4h-1.4zM5.8 10h1.4v1.4h-1.4z" },
      { fill: "#9E62A8", d: "M12.8 10h1.4v1.4h-1.4zM14.2 10h1.4v1.4h-1.4z" },
      { fill: "#5DB37A", d: "M4.4 11.4h1.4v1.4h-1.4zM5.8 11.4h1.4v1.4h-1.4z" },
      { fill: "#8A6FD0", d: "M12.8 11.4h1.4v1.4h-1.4zM14.2 11.4h1.4v1.4h-1.4z" },
      { fill: "#5AAE9E", d: "M4.4 12.8h1.4v1.4h-1.4zM5.8 12.8h1.4v1.4h-1.4z" },
      { fill: "#6E79DE", d: "M12.8 12.8h1.4v1.4h-1.4zM14.2 12.8h1.4v1.4h-1.4z" },
      { fill: "#6FB0E8", d: "M3 14.2h1.4v1.4h-1.4zM4.4 14.2h1.4v1.4h-1.4z" },
      { fill: "#4F82E6", d: "M14.2 14.2h1.4v1.4h-1.4zM15.6 14.2h1.4v1.4h-1.4z" },
      { fill: "#7DB6F0", d: "M3 15.6h1.4v1.4h-1.4zM4.4 15.6h1.4v1.4h-1.4z" },
      { fill: "#4A86E8", d: "M14.2 15.6h1.4v1.4h-1.4zM15.6 15.6h1.4v1.4h-1.4z" },
    ],
  },
};

/** 柱子、热力格、筛选里的一个「服务」：一家一个，合并时 Grok · Grok Bot、Gemini · Antigravity 各一个 */
interface Unit {
  id: string;
  apps: App[];
  label: string;
  /** 柱子、热力格用哪家的颜色（合并的组用前一家的） */
  color: App;
}
const unit = (apps: App[]): Unit => ({ id: apps.join("+"), apps, label: apps.map((a) => APP_SHORT[a]).join(" · "), color: apps[0] });
/** 两两一组的服务：合并时一个按钮，拆开时两个 */
const PAIRS = { grok: ["grok", "grokBot"], google: ["gemini", "agy"] } as const satisfies Record<string, readonly [App, App]>;
type Pair = keyof typeof PAIRS;
const pairOf = (a: App) => (Object.keys(PAIRS) as Pair[]).find((k) => (PAIRS[k] as readonly App[]).includes(a));

/** 筛选一排的按钮：服务，或者一组后面的拆开 / 合并 */
type FilterItem = { kind: "unit"; unit: Unit } | { kind: "pair"; pair: Pair; split: boolean };

/** 按用过的服务和每组拆没拆，排出筛选一排。一组里只用过一家就只显示那一家，不带拆开按钮 */
function filterItems(used: Set<App>, split: Record<Pair, boolean>): FilterItem[] {
  const out: FilterItem[] = [];
  const one = (a: App) => out.push({ kind: "unit", unit: unit([a]) });
  for (const a of APPS) {
    const pair = pairOf(a);
    if (!pair) {
      if (used.has(a)) one(a);
      continue;
    }
    const [first, second] = PAIRS[pair];
    if (a !== first) continue;
    const apps = [first, second].filter((x) => used.has(x));
    if (apps.length < 2) apps.forEach(one);
    else if (split[pair]) {
      one(first);
      out.push({ kind: "pair", pair, split: true });
      one(second);
    } else {
      out.push({ kind: "unit", unit: unit([first, second]) });
      out.push({ kind: "pair", pair, split: false });
    }
  }
  return out;
}

const reduced = () => typeof matchMedia !== "undefined" && matchMedia("(prefers-reduced-motion: reduce)").matches;

type Filter = "all" | string;

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

/** 服务的标，染成服务识别色（Antigravity 是彩虹色，不染） */
export function ServiceLogo({ app, size = 14 }: { app: App; size?: number }) {
  const g = GLYPH[app];
  return (
    <svg className={`svc-logo svc-${app}`} viewBox={g.viewBox} width={size} height={size} aria-label={APP_LABEL[app]} role="img">
      {g.paths.map((p, i) => (
        <path key={i} d={p.d} fillRule={p.rule} fill={p.fill} />
      ))}
    </svg>
  );
}

/** 一组服务的标：合并的组两个标挨在一起 */
function UnitLogo({ u, size = 14 }: { u: Unit; size?: number }) {
  return (
    <span className={`unit-logo${u.apps.length > 1 ? " unit-pair" : ""}`} aria-label={u.label}>
      {u.apps.map((a) => (
        <ServiceLogo key={a} app={a} size={size} />
      ))}
    </span>
  );
}

const onlyGemini = (apps: App[]) => apps.length === 1 && apps[0] === "gemini";

/** 一组后面的拆开 / 合并：只有图标（同 App 的 arrow.triangle.branch / merge），换的时候转着淡进来 */
function PairButton({ pair, split, onClick }: { pair: Pair; split: boolean; onClick: () => void }) {
  const t = useT();
  const names = PAIRS[pair].map((a) => APP_SHORT[a]).join(t(" 和 ", " and "));
  const label = split ? t(`合并 ${names}`, `Merge ${names}`) : t(`拆开 ${names}`, `Show ${names} separately`);
  // 点过才转：刚打开页面时图标不动
  const clicked = useRef(false);
  return (
    <button className="svc-pair" data-k={`pair-${pair}`} onClick={() => ((clicked.current = true), onClick())} title={label} aria-label={label} aria-pressed={split}>
      <svg key={String(split)} viewBox="0 0 16 16" aria-hidden className={`svc-pair-icon${clicked.current ? (split ? " to-merge" : " to-split") : ""}`}>
        {split ? <path d="M3.8 14.5 8 9.2M12.2 14.5 8 9.2V2M5.4 4.4 8 1.8l2.6 2.6" /> : <path d="M8 14.5V9.2L3.8 4M8 9.2 12.2 4M3.8 7.2V4H7M12.2 7.2V4H9" />}
      </svg>
    </button>
  );
}

// ---------- 整块：筛选 + 三张图 ----------

export function UsageStats({ series, models, modelsAll, activity }: { series: SeriesPoint[]; models: ModelRow[]; modelsAll?: ModelTotalRow[]; activity: ActivityPoint[] }) {
  const t = useT();
  // 每次打开都是合并的（和 App 一样，不记）
  const [split, setSplit] = useState<Record<Pair, boolean>>({ grok: false, google: false });
  const [filter, setFilter] = useState<Filter>("all");
  const usedApps = new Set<App>([
    ...activity.filter((p) => p.tokens > 0 || (p.answers ?? 0) > 0).map((p) => p.app),
    ...series.filter((p) => p.tokens > 0 || p.cost_micro > 0 || (p.answers ?? 0) > 0).map((p) => p.app),
  ]);
  const items = filterItems(usedApps.size ? usedApps : new Set(APPS), split);
  const shown = items.flatMap((x) => (x.kind === "unit" ? [x.unit] : []));
  const selected = shown.find((u) => u.id === filter);
  const units = selected ? [selected] : shown;

  // 拆开 / 合并时筛选一排的过渡：留下来的按钮从原来的位置滑过去，新出来的按钮放大淡入（FLIP）
  const row = useRef<HTMLDivElement>(null);
  const before = useRef<Map<string, DOMRect> | null>(null);
  useLayoutEffect(() => {
    const prev = before.current;
    before.current = null;
    if (!prev || !row.current || reduced()) return;
    const ease = { duration: 380, easing: "cubic-bezier(.2, .8, .2, 1)" };
    for (const el of row.current.querySelectorAll<HTMLElement>("[data-k]")) {
      const r = el.getBoundingClientRect();
      const p = prev.get(el.dataset.k!);
      if (!p) el.animate([{ opacity: 0, transform: "scale(.6)" }, { opacity: 1, transform: "none" }], ease);
      else if (p.left !== r.left || p.top !== r.top) el.animate([{ transform: `translate(${p.left - r.left}px, ${p.top - r.top}px)` }, { transform: "none" }], ease);
    }
  }, [split]);

  const toggle = (pair: Pair) => {
    before.current = new Map([...(row.current?.querySelectorAll<HTMLElement>("[data-k]") ?? [])].map((el) => [el.dataset.k!, el.getBoundingClientRect()]));
    const next = !split[pair];
    setSplit({ ...split, [pair]: next });
    // 选着的那一组拆开了就改选前一家，选着其中一家时合并了就改选整组（和 App 一样）
    const apps = PAIRS[pair] as readonly App[];
    if (selected && selected.apps.some((a) => apps.includes(a))) setFilter(next ? apps[0] : apps.join("+"));
  };
  return (
    <>
      <div className="svc-filter" role="tablist" aria-label={t("按服务筛选", "Filter by service")} ref={row}>
        <button role="tab" aria-selected={!selected} onClick={() => setFilter("all")}>{t("全部", "All")}</button>
        {items.map((x) =>
          x.kind === "unit" ? (
            <button key={x.unit.id} data-k={x.unit.id} role="tab" aria-selected={selected?.id === x.unit.id} onClick={() => setFilter(x.unit.id)}>
              <UnitLogo u={x.unit} />
              {x.unit.label}
            </button>
          ) : (
            <PairButton key={`pair-${x.pair}`} pair={x.pair} split={x.split} onClick={() => toggle(x.pair)} />
          ),
        )}
      </div>
      <TokenActivity activity={activity} units={units} />
      <DailyUsage series={series} units={units} />
      <ModelDetail models={models} modelsAll={modelsAll} apps={units.flatMap((u) => u.apps)} />
    </>
  );
}

// ---------- 每日用量（近 30 天） ----------

type Metric = "cost" | "tokens" | "answers";

function DailyUsage({ series, units, days = 30 }: { series: SeriesPoint[]; units: Unit[]; days?: number }) {
  const t = useT();
  const lang = useLang();
  const [picked, setMetric] = useState<"cost" | "tokens">("cost");
  const [hover, setHover] = useState<number | null>(null);
  const today = localToday();
  const dayList = Array.from({ length: days }, (_, i) => shift(today, i - days + 1));
  const byDay = new Map<string, Partial<Record<App, SeriesPoint>>>();
  for (const p of series) byDay.set(p.day, { ...byDay.get(p.day), [p.app]: p });
  const apps = units.flatMap((u) => u.apps);
  // 只看 Gemini：没有花费和 token，换成回答次数
  const metric: Metric = onlyGemini(apps) ? "answers" : picked;
  const pick = (p: SeriesPoint | undefined) => (!p ? 0 : metric === "cost" ? p.cost_micro : metric === "tokens" ? p.tokens : (p.answers ?? 0));
  const value = (d: string, u: Unit) => u.apps.reduce((sum, a) => sum + pick(byDay.get(d)?.[a]), 0);
  const geminiAnswers = (d: string, u: Unit) => (metric !== "answers" && u.apps.includes("gemini") ? (byDay.get(d)?.gemini?.answers ?? 0) : 0);
  const totals = dayList.map((d) => units.reduce((s, u) => s + value(d, u), 0));
  const avg = totals.reduce((s, v) => s + v, 0) / days;
  const ticks = niceTicks(Math.max(...totals, 1));
  const top = ticks[ticks.length - 1] || 1;
  const fmt = (v: number) => (metric === "cost" ? fmtUSD(v) : metric === "tokens" ? fmtTokens(v) : t(`${fmtInt(Math.round(v))} 次`, `${fmtInt(Math.round(v))}`));
  const fmtAxis = (v: number) => (metric === "cost" ? `$${fmtInt(Math.round(v / 1e6))}` : metric === "tokens" ? fmtTokens(v) : fmtInt(v));
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
            {units.map((u) => (
              <UnitLogo key={u.id} u={u} />
            ))}
          </span>
          {metric === "answers" ? (
            <span className="usage-unit">{t("回答次数", "Answers")}</span>
          ) : (
            <div className="seg seg-small" role="tablist">
              <button role="tab" aria-selected={metric === "cost"} onClick={() => setMetric("cost")}>{t("费用", "Cost")}</button>
              <button role="tab" aria-selected={metric === "tokens"} onClick={() => setMetric("tokens")}>Tokens</button>
            </div>
          )}
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
                    {/* 一家一段，染所在组的颜色：合并时同组的两段换成同一个颜色，渐变过去就像并成了一段 */}
                    {units.flatMap((u) =>
                      u.apps.map((a) => {
                        const v = pick(byDay.get(d)?.[a]);
                        return v ? <i key={a} className={`fill-${u.color}`} style={{ flexGrow: v }} /> : null;
                      }),
                    )}
                  </div>
                  {hover === i && (
                    <div className={`daily-tip${i > days * 0.7 ? " tip-left" : i < days * 0.3 ? " tip-right" : ""}`}>
                      <b>{lang === "zh" ? `${Number(d.slice(5, 7))}月${Number(d.slice(8))}日` : label(d)}</b>
                      {units.map((u) => (
                        <span key={u.id}>
                          <UnitLogo u={u} size={11} /> {u.label}
                          <em>
                            {fmt(value(d, u))}
                            {geminiAnswers(d, u) > 0 && <small>{t(` · Gemini ${fmtInt(geminiAnswers(d, u))} 次`, ` · Gemini ${fmtInt(geminiAnswers(d, u))} answers`)}</small>}
                          </em>
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

type Range = "yesterday" | "7d" | "30d" | "all";
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
  answers: number;
}

function ModelDetail({ models, modelsAll, apps }: { models: ModelRow[]; modelsAll?: ModelTotalRow[]; apps: App[] }) {
  const t = useT();
  const [range, setRange] = useState<Range>("30d");
  const [sort, setSort] = useState<{ col: Col; desc: boolean }>({ col: "tokens", desc: true });
  const today = localToday();
  // App 只传已经过完的天，所以是「昨天」不是「今天」；「全部」用服务端加好的所有日子（旧接口没有就退回近 30 天）
  const since = range === "yesterday" ? shift(today, -1) : range === "7d" ? shift(today, -6) : range === "30d" ? shift(today, -29) : "";
  const until = range === "yesterday" ? shift(today, -1) : today;
  const source: (ModelTotalRow & { day?: string })[] = range === "all" ? (modelsAll ?? models) : models;
  // 按选的时间段、服务把每天的行加起来
  const totals = new Map<string, ModelTotal>();
  for (const r of source) {
    if ((r.day !== undefined && (r.day < since || r.day > until)) || !apps.includes(r.app)) continue;
    const key = `${r.app}\u0000${r.model}`;
    const m = totals.get(key) ?? { app: r.app, model: r.model, input: 0, output: 0, cache_read: 0, cache_write: 0, tokens: 0, cost_micro: 0, answers: 0 };
    m.input += r.input;
    m.output += r.output;
    m.cache_read += r.cache_read;
    m.cache_write += r.cache_write;
    m.tokens += r.input + r.output + r.cache_read + r.cache_write;
    m.cost_micro += r.cost_micro;
    m.answers += r.answers ?? 0;
    totals.set(key, m);
  }
  const list = [...totals.values()].filter((m) => m.tokens > 0 || m.cost_micro > 0 || m.answers > 0);
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
              ["yesterday", t("昨天", "Yesterday")],
              ["7d", t("7 天", "7 days")],
              ["30d", t("30 天", "30 days")],
              ["all", t("全部", "All")],
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
              {rows.map((m) =>
                m.app === "gemini" ? (
                  // Gemini 没有 token 和花费：模型名后面写回答次数，数字列都是「—」
                  <tr key={`${m.app}/${m.model}`}>
                    <td>
                      <ServiceLogo app={m.app} size={13} /> {m.model} <span className="muted small">{t(`${fmtInt(m.answers)} 次回答`, `${fmtInt(m.answers)} answers`)}</span>
                    </td>
                    {[0, 1, 2, 3, 4, 5].map((k) => (
                      <td key={k} className="num muted">—</td>
                    ))}
                  </tr>
                ) : (
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
                ),
              )}
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

function TokenActivity({ activity, units }: { activity: ActivityPoint[]; units: Unit[] }) {
  const t = useT();
  const lang = useLang();
  const [mode, setMode] = useState<Mode>("daily");
  const [hover, setHover] = useState<{ col: number; row: number } | null>(null);
  const apps = units.flatMap((u) => u.apps);
  // 只看 Gemini：没有 token，按回答次数画（「回答活动」）
  const answers = onlyGemini(apps);
  const key = `${apps.join(",")}|${answers}`;
  const model = useMemo(
    () => buildActivity(activity.filter((p) => apps.includes(p.app)).map((p) => ({ ...p, tokens: answers ? (p.answers ?? 0) : p.tokens }))),
    [activity, key],
  );
  const { daily, starts, today, weekTotals, cumulative, thresholds, streaks, total, peak } = model;
  const values = mode === "weekly" ? weekTotals : cumulative;
  const maxValue = Math.max(...values, 1);
  // 只选了一个服务（或一组）时用它的识别色（四档深浅），全部时用和「今天」火苗同一套暖色
  const tint = units.length === 1 ? units[0].color : null;

  const level = (v: number) => (v <= 0 ? 0 : v <= thresholds[0] ? 1 : v <= thresholds[1] ? 2 : v <= thresholds[2] ? 3 : 4);
  const longDate = (d: string) => (lang === "zh" ? `${d.slice(0, 4)}年${Number(d.slice(5, 7))}月${Number(d.slice(8))}日` : new Date(`${d}T00:00:00Z`).toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" }));
  const shortDate = (d: string) => (lang === "zh" ? `${Number(d.slice(5, 7))}月${Number(d.slice(8))}日` : new Date(`${d}T00:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" }));
  const tokens = (v: number) => (answers ? t(`${fmtInt(v)} 次回答`, `${fmtInt(v)} answers`) : t(`${fmtTokens(v)} 个 Token`, `${fmtTokens(v)} tokens`));
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
        <div><b>{answers ? fmtInt(total) : fmtTokens(total)}</b><span>{answers ? t("累计回答次数", "Total answers") : t("累计 Token 数", "Total tokens")}</span></div>
        <div><b>{answers ? fmtInt(peak) : fmtTokens(peak)}</b><span>{answers ? t("单日最多回答", "Peak day") : t("Token 使用峰值", "Peak day")}</span></div>
        <div><b>{t(`${streaks.longest} 天`, `${streaks.longest} days`)}</b><span>{t("最长连续天数", "Longest streak")}</span></div>
        <div><b>{t(`${streaks.current} 天`, `${streaks.current} days`)}</b><span>{t("当前连续天数", "Current streak")}</span></div>
      </div>
      <div className="usage-head">
        <h2>{answers ? t("回答活动", "Answer activity") : t("Token 活动", "Token activity")}</h2>
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
