import { useEffect, useState } from "react";
import { Link } from "react-router";
import { api, fmtInt, fmtTokens, fmtUSD, type LeaderboardRow } from "../api";
import { Avatar } from "../components";
import { loginHref, useMe } from "../useMe";

const RANGES = [
  { key: "today", label: "今天" },
  { key: "7d", label: "7 天" },
  { key: "30d", label: "30 天" },
  { key: "all", label: "总榜" },
] as const;

export function HomePage() {
  const [range, setRange] = useState<(typeof RANGES)[number]["key"]>("7d");
  const [rows, setRows] = useState<LeaderboardRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const { me } = useMe();

  useEffect(() => {
    setRows(null);
    setError(null);
    api<{ rows: LeaderboardRow[] }>(`/api/leaderboard?range=${range}`).then((r) => setRows(r.rows), (e: Error) => setError(e.message));
  }, [range]);

  return (
    <>
      <section className="hero">
        <h1>谁在 AI 上烧得最多？</h1>
        <p>
          装上 yybar，Codex、Claude Code、Grok 的每日 token 和花费自动上传到这里。
          花掉的每 1 美元记 100 积分，可以拿去 Bar 里打德州。
        </p>
        {me && !me.user && (
          <a className="btn" href={loginHref("/me")}>用 GitHub 登录</a>
        )}
      </section>

      <section className="card">
        <div className="card-head">
          <h2>排行榜</h2>
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
              <li key={r.login} className={r.rank <= 3 ? `top top-${r.rank}` : undefined}>
                <span className="rank">{r.rank}</span>
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
    </>
  );
}
