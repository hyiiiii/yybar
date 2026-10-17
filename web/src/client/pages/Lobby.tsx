import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router";
import { api, fmtInt, fmtUSD, type LeaderboardRow } from "../api";
import { Avatar, FeltTable, LoginButton, PlayingCard, SuitIcon, type Seat } from "../components";
import { TABLES } from "../tables";
import { useMe } from "../useMe";

export function LobbyPage() {
  const { me } = useMe();
  const navigate = useNavigate();
  const [top, setTop] = useState<LeaderboardRow[]>([]);
  useEffect(() => {
    api<{ rows: LeaderboardRow[] }>("/api/leaderboard?range=7d").then((r) => setTop(r.rows), () => {});
  }, []);

  // 大厅主桌：用本周榜上的人坐满，留下正下方的空位给访客
  const names = top.map((r) => r.login);
  const seats: Seat[] = [
    {},
    { login: names[1] ?? "nightowl", stack: 18_420, state: "跟注" , bet: 400 },
    { login: names[2] ?? "token-burner", stack: 9_870, state: "弃牌" },
    { login: names[0] ?? "hyiiiii", stack: 41_300, bet: 1_200, state: "加注", dealer: true, cards: ["back", "back"] },
    { login: names[3] ?? "vibe-coder", stack: 6_050, state: "思考中…", cards: ["back", "back"] },
    { login: names[4] ?? "mia", stack: 12_760, bet: 400, state: "跟注" },
  ];
  const signedIn = !!me?.user;

  return (
    <>
      <section className="hero">
        <div className="hero-copy">
          <p className="eyebrow">
            <SuitIcon suit="gpt" /> <SuitIcon suit="claude" /> <SuitIcon suit="gemini" /> <SuitIcon suit="grok" />
            <span>yybar · 德州</span>
          </p>
          <h1>
            你烧掉的 token，<br />
            在这里变成筹码。
          </h1>
          <p className="lede">
            yybar 自动记下你每天在 Codex、Claude Code、Grok 上的花费。每花 $1 换 100 筹码，拿来和其他人打德州。
          </p>
          <div className="hero-cta">
            {signedIn ? (
              <button className="btn" onClick={() => navigate("/table/practice")}>入座练习桌</button>
            ) : (
              <LoginButton label="用 GitHub 登录，领筹码" />
            )}
            <a className="btn btn-ghost" href="#tables">看看有哪些桌</a>
          </div>
          {signedIn && me?.points && (
            <p className="your-stack">
              你的筹码 <b>{fmtInt(me.points.balance)}</b>
            </p>
          )}
        </div>
        <FeltTable
          label="常客桌 · 盲注 50 / 100"
          seats={seats}
          pot={3_850}
          board={[{ rank: "A", suit: "claude" }, { rank: "K", suit: "gpt" }, { rank: "10", suit: "gemini" }, { rank: "J", suit: "grok" }, "back"]}
          onEmptySeat={() => navigate("/table/regulars")}
        />
      </section>

      <section id="tables" className="section">
        <div className="section-head">
          <h2>开着的桌</h2>
          <p className="muted">入座时从你的筹码里带入，离桌时剩多少带回多少。</p>
        </div>
        <div className="tables">
          {TABLES.map((t) => {
            const enough = (me?.points?.balance ?? 0) >= t.minBuyIn;
            return (
              <article key={t.id} className={`table-card${t.bots ? " is-bots" : ""}`}>
                <header>
                  <h3>{t.name}</h3>
                  <span className="seats-dots" aria-label={`${t.seated}/${t.seats} 人`}>
                    {Array.from({ length: t.seats }, (_, i) => (
                      <i key={i} className={i < t.seated ? "on" : undefined} />
                    ))}
                  </span>
                </header>
                <p>{t.blurb}</p>
                <dl>
                  <div>
                    <dt>盲注</dt>
                    <dd>{fmtInt(t.blinds[0])} / {fmtInt(t.blinds[1])}</dd>
                  </div>
                  <div>
                    <dt>最低带入</dt>
                    <dd>{fmtInt(t.minBuyIn)}</dd>
                  </div>
                  <div>
                    <dt>{t.bots ? "对手" : "在座"}</dt>
                    <dd>{t.bots ? "机器人" : `${t.seated} / ${t.seats}`}</dd>
                  </div>
                </dl>
                <button className="btn btn-small" onClick={() => navigate(`/table/${t.id}`)}>
                  {signedIn && !enough ? "筹码不够，先去看看" : "入座"}
                </button>
              </article>
            );
          })}
        </div>
      </section>

      <section className="section split">
        <div>
          <div className="section-head">
            <h2>筹码从哪来</h2>
          </div>
          <ol className="steps">
            <li>
              <b>装上 yybar</b>
              <span>macOS 菜单栏小工具，从 GitHub 拉下来编译安装。</span>
            </li>
            <li>
              <b>连接网站</b>
              <span>在 App 设置里用 GitHub 登录，之后每天自动上传 token 用量和花费，只传汇总数字。</span>
            </li>
            <li>
              <b>$1 = 100 筹码</b>
              <span>花费越多筹码越多。筹码只在这里玩，不能充值也不能兑现。</span>
            </li>
          </ol>
          <div className="deck-row" aria-hidden>
            <PlayingCard card={{ rank: "A", suit: "gpt" }} size="lg" />
            <PlayingCard card={{ rank: "A", suit: "claude" }} size="lg" />
            <PlayingCard card={{ rank: "A", suit: "gemini" }} size="lg" />
            <PlayingCard card={{ rank: "A", suit: "grok" }} size="lg" />
          </div>
          <p className="muted small">四种花色换成了 GPT、Claude、Gemini、Grok。</p>
        </div>
        <div>
          <div className="section-head">
            <h2>本周名人墙</h2>
            <Link to="/board" className="more">全部 →</Link>
          </div>
          <ol className="mini-board">
            {top.slice(0, 5).map((r) => (
              <li key={r.login}>
                <span className={`rank rank-${r.rank}`}>{r.rank}</span>
                <Avatar url={r.avatarUrl} login={r.login} size={28} />
                <Link to={`/u/${r.login}`} className="who">{r.name || r.login}</Link>
                <span className="num">{fmtUSD(r.costMicro)}</span>
              </li>
            ))}
            {top.length === 0 && <li className="empty">这周还没人上榜。</li>}
          </ol>
        </div>
      </section>
    </>
  );
}
