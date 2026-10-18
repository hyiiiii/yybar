import { useEffect, useMemo, useState } from "react";
import { Link, useNavigate, useParams } from "react-router";
import { api, fmtInt, fmtUSD, type LeaderboardRow } from "../api";
import { Avatar, FeltTable, MarqueeSign, PlayingCard, type CardSpec, type Seat } from "../components";
import { Dealer } from "../Dealer";
import type { Suit } from "../suits";
import { TABLES } from "../tables";
import { loginHref, notifyMeChanged, useMe } from "../useMe";

const RANKS = ["2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A"];
const SUITS: Suit[] = ["gpt", "claude", "gemini", "grok"];

function shuffledDeck(): { rank: string; suit: Suit }[] {
  const deck = SUITS.flatMap((suit) => RANKS.map((rank) => ({ rank, suit })));
  for (let i = deck.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [deck[i], deck[j]] = [deck[j], deck[i]];
  }
  return deck;
}

const SEAT_COUNT = 6;
const DEMO = !!import.meta.env.VITE_DEMO;

/**
 * 大厅就是一张牌桌：右下角切桌，点空位入座，点发牌员推进牌局。
 * 德州的真实逻辑（下注、比牌、结算）还没接服务端，这里先走一手演示牌。
 */
export function LobbyPage() {
  const { id } = useParams();
  const navigate = useNavigate();
  const { me } = useMe();
  const table = TABLES.find((t) => t.id === id) ?? TABLES[2];
  const [seatIndex, setSeatIndex] = useState<number | null>(null);
  const [stage, setStage] = useState(0);
  const [deck, setDeck] = useState(shuffledDeck);
  const [top, setTop] = useState<LeaderboardRow[]>([]);
  const [note, setNote] = useState<string | null>(null);

  useEffect(() => {
    api<{ rows: LeaderboardRow[] }>("/api/leaderboard?range=7d").then((r) => setTop(r.rows), () => {});
  }, []);
  useEffect(() => {
    setSeatIndex(null);
    setStage(0);
    setDeck(shuffledDeck());
  }, [table.id]);

  const signedIn = !!me?.user;

  const seats: Seat[] = useMemo(() => {
    const names = top.map((r) => r.login).filter((n) => n !== me?.user?.login);
    const others = table.bots
      ? ["bot-紧凶", "bot-松鱼", "bot-跟注站", "bot-诈唬王", "bot-老实人"]
      : names.length ? names : ["nightowl", "token-burner", "vibe-coder", "mia", "lazy-dev"];
    // 这一手的剧本（单位：大盲）：CO 翻牌弃、HJ 转牌弃，摊牌时 BTN 亮牌
    const BETS = [
      [0, 0.5, 1, 0, 0, 0],
      [0, 0, 0, 0, 0, 0],
      [5, 0, 5, 0, 0, 0],
      [0, 0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0, 0],
    ][stage];
    const SPENT = [
      [0, 0.5, 1, 0, 0, 0],
      [2.5, 2.5, 2.5, 2.5, 2.5, 0],
      [7.5, 2.5, 7.5, 7.5, 2.5, 0],
      [7.5, 2.5, 7.5, 7.5, 2.5, 0],
      [19, 2.5, 7.5, 19, 2.5, 0],
    ][stage];
    const FOLDED = [[], [5], [5, 4, 1], [5, 4, 1], [5, 4, 1, 2]][stage];
    const ACTING = [3, 0, 2, 3, -1][stage];
    const positions = ["BTN", "SB", "BB", "UTG", "HJ", "CO"];
    const seatOrder = [0, 1, 2, 4, 5]; // UTG(3) 留给访客
    const list: Seat[] = positions.map((position) => ({ position }));
    seatOrder.slice(0, Math.min(table.seated, 5)).forEach((i, k) => {
      list[i] = {
        position: positions[i],
        login: others[k],
        stack: 100 + ((k * 37) % 60) - SPENT[i],
        bet: BETS[i],
        dealer: i === 0,
        folded: FOLDED.includes(i),
        acting: ACTING === i,
        cards: stage === 4 && i === 0 ? [deck[7], deck[8]] : ["back", "back"],
      };
    });
    if (seatIndex !== null) {
      list[seatIndex] = {
        position: positions[seatIndex],
        login: me?.user?.login ?? "guest",
        you: true,
        stack: 100 - SPENT[3],
        bet: BETS[3],
        acting: ACTING === seatIndex,
        cards: [deck[5], deck[6]],
      };
    }
    return list;
  }, [top, table, seatIndex, stage, deck, me]);

  const board: CardSpec[] = [0, 1, 2, 3, 4].map((i) => (i < [0, 3, 4, 5, 5][stage] ? deck[i] : "back"));
  const pot = [1.5, 12.5, 32.5, 32.5, 57][stage];

  const advance = () => {
    setNote(null);
    if (stage >= 4) {
      setDeck(shuffledDeck());
      setStage(0);
    } else {
      setStage(stage + 1);
    }
  };

  const switchTable = (step: number) => {
    const i = TABLES.findIndex((t) => t.id === table.id);
    navigate(`/table/${TABLES[(i + step + TABLES.length) % TABLES.length].id}`);
  };

  const sit = async (index: number) => {
    if (!signedIn) {
      if (!DEMO) {
        location.href = loginHref(`/table/${table.id}`);
        return;
      }
      (await import("../demo")).demoLogin();
      notifyMeChanged();
    }
    setSeatIndex(index);
    setNote(null);
  };

  const lines = useMemo(
    () => ["", "翻牌！", "转牌～", "河牌！", seatIndex !== null ? "摊牌，看看谁赢？" : "这手结束，要不要上桌？"],
    [seatIndex],
  );

  return (
    <div className="lobby">
      <MarqueeSign text="yybar" />

      <FeltTable
        seats={seats}
        onEmptySeat={(i) => sit(i)}
        corner={
          <>
            <button className="icon-btn" onClick={() => switchTable(-1)} aria-label="上一张桌">
              <svg viewBox="0 0 12 12" aria-hidden><path d="M8.5 1.8v8.4L2.2 6z" /></svg>
            </button>
            <span className="corner-label">
              {table.name}
              <small>{fmtInt(table.blinds[0])}/{fmtInt(table.blinds[1])}</small>
            </span>
            <button className="icon-btn" onClick={() => switchTable(1)} aria-label="下一张桌">
              <svg viewBox="0 0 12 12" aria-hidden><path d="M3.5 1.8v8.4L9.8 6z" /></svg>
            </button>
            <button className="icon-btn icon-btn-new" onClick={() => setNote("开桌功能还在做，先坐现成的桌吧。")} aria-label="开一张桌" title="开桌">
              <svg viewBox="0 0 12 12" aria-hidden><path d="M6 2v8M2 6h8" /></svg>
            </button>
          </>
        }
        center={
          <div className="felt-center">
            <Dealer stage={stage} onAdvance={advance} lines={lines} />
            <div className="board-cards">
              {board.map((c, i) => (
                <PlayingCard key={`${i}-${c === "back" ? "b" : c.rank + c.suit}`} card={c} />
              ))}
            </div>
            <div className="pot">
              <span>底池</span>
              <b>{pot} bb</b>
              <small>盲注 {fmtInt(table.blinds[0])}/{fmtInt(table.blinds[1])}</small>
            </div>
          </div>
        }
      />

      <div className="actions">
        {seatIndex !== null ? (
          <>
            <button className="btn btn-ghost" onClick={() => { setStage(4); setNote("你弃牌了。点发牌员开下一手。"); }}>弃牌</button>
            <button className="btn btn-ghost" onClick={advance}>{stage === 0 ? "跟注 1 bb" : "过牌"}</button>
            <button className="btn" onClick={advance}>{stage === 0 ? "加注到 2.5 bb" : `下注 ${Math.round(pot / 2)} bb`}</button>
            <button className="btn btn-text" onClick={() => setSeatIndex(null)}>离桌</button>
          </>
        ) : (
          <button className="btn" onClick={() => sit(seats.findIndex((s) => !s.login))}>
            {signedIn ? `入座 · 带入 ${fmtInt(table.minBuyIn)}` : "用 GitHub 登录入座"}
          </button>
        )}
      </div>
      {note && <p className="note" role="status">{note}</p>}

      <section className="mini-wall">
        <div className="mini-wall-head">
          <h2>本周名人墙</h2>
          <Link to="/board" className="more">全部</Link>
        </div>
        <ol className="mini-board">
          {top.slice(0, 5).map((r) => (
            <li key={r.login}>
              <span className={`rank rank-${r.rank}`}>{r.rank}</span>
              <Avatar url={r.avatarUrl} login={r.login} size={26} />
              <Link to={`/u/${r.login}`} className="who">{r.name || r.login}</Link>
              <span className="num">{fmtUSD(r.costMicro)}</span>
            </li>
          ))}
        </ol>
      </section>
    </div>
  );
}
