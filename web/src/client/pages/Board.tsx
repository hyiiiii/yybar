import { useEffect, useState } from "react";
import { Link } from "react-router";
import { api, fmtInt, fmtTokens, fmtUSD, type TokenRow, type WealthRow } from "../api";
import { Avatar, Badges, StatLine } from "../components";
import { CoinsIcon, FlameIcon } from "../icons";
import { tr, useLang, useT } from "../i18n";

const RANGES = [
  { key: "yesterday", label: ["昨天", "Yesterday"] },
  { key: "7d", label: ["7 天", "7 days"] },
  { key: "30d", label: ["30 天", "30 days"] },
  { key: "all", label: ["总榜", "All time"] },
] as const;

type By = "tokens" | "wealth";
/** 燃烧 token 榜按 token 数排还是按花费排；财富榜按余额排还是按今日输赢排 */
type Sort = "tokens" | "cost";
type WealthSort = "balance" | "today";

/** 排行榜：用图标切换「燃烧 token」（按 token 数，带最常用的模型）和「财富」（按筹码余额）。 */
export function BoardPage() {
  const [by, setBy] = useState<By>("tokens");
  const [range, setRange] = useState<(typeof RANGES)[number]["key"]>("7d");
  const [sort, setSort] = useState<Sort>("tokens");
  const [wsort, setWsort] = useState<WealthSort>("balance");
  const [rows, setRows] = useState<(TokenRow | WealthRow)[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const lang = useLang();
  const t = useT();

  useEffect(() => {
    setRows(null);
    setError(null);
    const q = by === "tokens" ? `by=tokens&range=${range}&sort=${sort}` : `by=wealth&sort=${wsort}`;
    api<{ rows: (TokenRow | WealthRow)[] }>(`/api/leaderboard?${q}`).then((r) => setRows(r.rows), (e: Error) => setError(tr(e.message, lang)));
  }, [by, range, sort, wsort]);

  return (
    <section className="section">
      <div className="section-head board-head">
        <div className="seg seg-icons" role="tablist" aria-label={t("排行方式", "Rank by")}>
          <button role="tab" aria-selected={by === "tokens"} onClick={() => setBy("tokens")} aria-label={t("燃烧 token", "Tokens burned")} title={t("燃烧 token", "Tokens burned")}>
            <FlameIcon />
          </button>
          <button role="tab" aria-selected={by === "wealth"} onClick={() => setBy("wealth")} aria-label={t("财富", "Wealth")} title={t("财富", "Wealth")}>
            <CoinsIcon />
          </button>
        </div>
        {by === "tokens" && (
          <div className="seg" role="tablist" aria-label={t("时间段", "Period")}>
            {RANGES.map((r) => (
              <button key={r.key} role="tab" aria-selected={range === r.key} onClick={() => setRange(r.key)}>
                {t(r.label[0], r.label[1])}
              </button>
            ))}
          </div>
        )}
      </div>
      {error && <p className="error">{error}</p>}
      {!rows && !error && <p className="empty">{t("加载中…", "Loading…")}</p>}
      {rows && rows.length === 0 && <p className="empty">{t("还没有人上榜。", "Nobody on the board yet.")}</p>}
      {rows && rows.length > 0 && (
        // 换榜、换时间段、换排序时整个列表重新挂载，一行一行滑进来
        <ol className={`board board-${by}`} key={`${by}-${range}-${sort}-${wsort}`}>
          {rows.map((r, i) => (
            <li key={r.login} style={{ "--i": Math.min(i, 20) } as React.CSSProperties}>
              <span className={`rank rank-${r.rank}`}>{r.rank}</span>
              <Avatar url={r.avatarUrl} login={r.login} />
              <Link to={`/u/${r.login}`} className="who">
                <strong>
                  {r.name || r.login}
                  <Badges ids={r.badges} />
                </strong>
                <small>@{r.login}</small>
              </Link>
              {"tokens" in r ? (
                <>
                  <span className="top-model" title={t("最常用的模型", "Most-used model")}>
                    <i className={`dot fill-${r.topApp}`} /> {r.topModel}
                  </span>
                  <span className={`num board-amount${sort === "tokens" ? " primary" : ""}`} title={`${fmtInt(r.tokens)} tokens`}>
                    {sort === "tokens" ? fmtTokens(r.tokens) : fmtUSD(r.costMicro)}
                    <small>{sort === "tokens" ? fmtUSD(r.costMicro) : `${fmtTokens(r.tokens)} tokens`}</small>
                  </span>
                  {/* 第一名最右边一个小按钮：点一下在按 token 排和按花费排之间切换；其他行留个空位对齐 */}
                  {i === 0 ? (
                    <button
                      className="sort-flip"
                      onClick={() => setSort(sort === "tokens" ? "cost" : "tokens")}
                      aria-label={sort === "tokens" ? t("改成按花费排", "Sort by spend") : t("改成按 token 排", "Sort by tokens")}
                      title={sort === "tokens" ? t("改成按花费排", "Sort by spend") : t("改成按 token 排", "Sort by tokens")}
                    >
                      <svg viewBox="0 0 16 16" aria-hidden><path d="M5 3v10M2.5 10.5 5 13l2.5-2.5M11 13V3M8.5 5.5 11 3l2.5 2.5" /></svg>
                      <span>{sort === "tokens" ? "$" : "T"}</span>
                    </button>
                  ) : (
                    <span />
                  )}
                </>
              ) : (
                <>
                  <StatLine stats={r.stats} />
                  <span className="num board-amount primary" title={t("今天（UTC）在牌桌上的输赢", "Today's table result (UTC)")}>
                    {wsort === "balance" ? <span className="chip-count">{fmtInt(r.balance)}</span> : <Net n={r.today} hands={r.todayHands} />}
                    <small>{wsort === "balance" ? <>{t("今日", "Today")} <Net n={r.today} hands={r.todayHands} /></> : <span className="chip-count">{fmtInt(r.balance)}</span>}</small>
                  </span>
                  {i === 0 ? (
                    <button
                      className="sort-flip"
                      onClick={() => setWsort(wsort === "balance" ? "today" : "balance")}
                      aria-label={wsort === "balance" ? t("改成按今日输赢排", "Sort by today's result") : t("改成按余额排", "Sort by balance")}
                      title={wsort === "balance" ? t("改成按今日输赢排", "Sort by today's result") : t("改成按余额排", "Sort by balance")}
                    >
                      <svg viewBox="0 0 16 16" aria-hidden><path d="M5 3v10M2.5 10.5 5 13l2.5-2.5M11 13V3M8.5 5.5 11 3l2.5 2.5" /></svg>
                      <span>{wsort === "balance" ? "±" : "$"}</span>
                    </button>
                  ) : (
                    <span />
                  )}
                </>
              )}
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}

/** 今日输赢：赢了绿色带 +，输了红色带 −，今天没打显示一道横线 */
function Net({ n, hands }: { n: number; hands: number }) {
  if (!hands) return <span className="net net-none">—</span>;
  return <span className={`net ${n > 0 ? "net-up" : n < 0 ? "net-down" : ""}`}>{n > 0 ? "+" : n < 0 ? "−" : ""}${fmtInt(Math.abs(n))}</span>;
}
