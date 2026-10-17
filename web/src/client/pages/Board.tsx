import { useEffect, useState } from "react";
import { Link } from "react-router";
import { api, fmtInt, fmtTokens, fmtUSD, type LeaderboardRow } from "../api";
import { Avatar } from "../components";

const RANGES = [
  { key: "today", label: "今天" },
  { key: "7d", label: "7 天" },
  { key: "30d", label: "30 天" },
  { key: "all", label: "总榜" },
] as const;

export function BoardPage() {
  const [range, setRange] = useState<(typeof RANGES)[number]["key"]>("7d");
  const [rows, setRows] = useState<LeaderboardRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setRows(null);
    setError(null);
    api<{ rows: LeaderboardRow[] }>(`/api/leaderboard?range=${range}`).then((r) => setRows(r.rows), (e: Error) => setError(e.message));
  }, [range]);

  return (
    <section className="section">
      <div className="section-head">
        <div>
          <h1>名人墙</h1>
          <p className="muted">按记录下来的 AI 花费排名。不想上墙可以在「我的」里关掉。</p>
        </div>
        <div className="seg" role="tablist">
          {RANGES.map((r) => (
            <button key={r.key} role="tab" aria-selected={range === r.key} onClick={() => setRange(r.key)}>
              {r.label}
            </button>
          ))}
        </div>
      </div>
      {error && <p className="error">{error}</p>}
      {!rows && !error && <p className="empty">加载中…</p>}
      {rows && rows.length === 0 && <p className="empty">这个时间段还没有人上榜。</p>}
      {rows && rows.length > 0 && (
        <ol className="board">
          {rows.map((r) => (
            <li key={r.login}>
              <span className={`rank rank-${r.rank}`}>{r.rank}</span>
              <Avatar url={r.avatarUrl} login={r.login} />
              <Link to={`/u/${r.login}`} className="who">
                <strong>{r.name || r.login}</strong>
                <small>@{r.login}</small>
              </Link>
              <span className="num tokens" title={`${fmtInt(r.tokens)} tokens`}>{fmtTokens(r.tokens)}</span>
              <span className="num cost">{fmtUSD(r.costMicro)}</span>
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}
