import { useEffect, useState } from "react";
import { Link } from "react-router";
import { api, fmtInt, fmtTokens, type TokenRow, type WealthRow } from "../api";
import { Avatar, Badge } from "../components";
import { CoinsIcon, FlameIcon } from "../icons";
import { tr, useLang, useT } from "../i18n";

const RANGES = [
  { key: "today", label: ["今天", "Today"] },
  { key: "7d", label: ["7 天", "7 days"] },
  { key: "30d", label: ["30 天", "30 days"] },
  { key: "all", label: ["总榜", "All time"] },
] as const;

type By = "tokens" | "wealth";

/** 排行榜：用图标切换「燃烧 token」（按 token 数，带最常用的模型）和「财富」（按筹码余额）。 */
export function BoardPage() {
  const [by, setBy] = useState<By>("tokens");
  const [range, setRange] = useState<(typeof RANGES)[number]["key"]>("7d");
  const [rows, setRows] = useState<(TokenRow | WealthRow)[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const lang = useLang();
  const t = useT();

  useEffect(() => {
    setRows(null);
    setError(null);
    const q = by === "tokens" ? `by=tokens&range=${range}` : "by=wealth";
    api<{ rows: (TokenRow | WealthRow)[] }>(`/api/leaderboard?${q}`).then((r) => setRows(r.rows), (e: Error) => setError(tr(e.message, lang)));
  }, [by, range]);

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
        <ol className={`board board-${by}`}>
          {rows.map((r) => (
            <li key={r.login}>
              <span className={`rank rank-${r.rank}`}>{r.rank}</span>
              <Avatar url={r.avatarUrl} login={r.login} />
              <Link to={`/u/${r.login}`} className="who">
                <strong>
                  {r.name || r.login}
                  <Badge id={r.badge} />
                </strong>
                <small>@{r.login}</small>
              </Link>
              {"tokens" in r ? (
                <>
                  <span className="top-model" title={t("最常用的模型", "Most-used model")}>
                    <i className={`dot fill-${r.topApp}`} /> {r.topModel}
                  </span>
                  <span className="num cost" title={`${fmtInt(r.tokens)} tokens`}>{fmtTokens(r.tokens)}</span>
                </>
              ) : (
                <span className="num cost chip-count">{fmtInt(r.balance)}</span>
              )}
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}
