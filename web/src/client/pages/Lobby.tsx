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
 * 大厅就是一张牌桌：选桌、点空位入座，点发牌员推进牌局。
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

  const bb = table.blinds[1];
  const signedIn = !!me?.user;
  const buyIn = Math.min(Math.max(me?.points?.balance ?? 0, 0), table.minBuyIn * 5);

  const seats: Seat[] = useMemo(() => {
    const names = top.map((r) => r.login).filter((n) => n !== me?.user?.login);
    const others = table.bots ? ["bot-紧凶", "bot-松鱼", "bot-跟注站", "bot-诈唬王", "bot-老实人"] : names.length ? names : ["nightowl", "token-burner", "vibe-coder", "mia", "lazy-dev"];
    const list: Seat[] = Array.from({ length: SEAT_COUNT }, () => ({}));
    // 0 号位（正下方）留给访客，其余按桌上人数坐人
    let k = 0;
    for (let i = 1; i < SEAT_COUNT && k < Math.min(table.seated, SEAT_COUNT - 1); i++) {
      if (i === seatIndex) continue;
      const showdown = stage === 4 && k === 0;
      list[i] = {
        login: others[k],
        stack: table.minBuyIn * (2 + ((k * 7) % 5)),
        bet: stage < 4 && k % 2 === 0 ? bb * (stage + 1) : undefined,
        state: stage === 4 ? (showdown ? "亮牌" : undefined) : ["跟注", "加注", "思考中…", "弃牌", "过牌"][(k + stage) % 5],
        dealer: k === 1,
        cards: k < 3 ? (showdown ? [deck[7 + k * 2], deck[8 + k * 2]] : ["back", "back"]) : undefined,
      };
      k++;
    }
    if (seatIndex !== null) {
      list[seatIndex] = { login: me?.user?.login ?? "guest", you: true, stack: buyIn, cards: [deck[5], deck[6]] };
    }
    return list;
  }, [top, table, seatIndex, stage, deck, me, buyIn, bb]);

  const board: CardSpec[] = [0, 1, 2, 3, 4].map((i) => (i < [0, 3, 4, 5, 5][stage] ? deck[i] : "back"));
  const pot = bb * [1.5, 6, 12, 20, 20][stage];

  const advance = () => {
    setNote(null);
    if (stage >= 4) {
      setDeck(shuffledDeck());
      setStage(0);
    } else {
      setStage(stage + 1);
    }
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

      <div className="table-picker" role="tablist" aria-label="选桌">
        {TABLES.map((t) => (
          <button key={t.id} role="tab" aria-selected={t.id === table.id} onClick={() => navigate(`/table/${t.id}`)}>
            {t.name}
            <small>{fmtInt(t.blinds[0])}/{fmtInt(t.blinds[1])}</small>
          </button>
        ))}
      </div>

      <FeltTable
        seats={seats}
        onEmptySeat={(i) => sit(i)}
        center={
          <div className="felt-center">
            <Dealer stage={stage} onAdvance={advance} lines={lines} />
            <div className="board-cards">
              {board.map((c, i) => (
                <PlayingCard key={`${i}-${c === "back" ? "b" : c.rank + c.suit}`} card={c} />
              ))}
            </div>
            <div className="pot">
              底池 <b>{fmtInt(pot)}</b>
            </div>
          </div>
        }
      />

      <div className="actions">
        {seatIndex !== null ? (
          <>
            <button className="btn btn-ghost" onClick={() => { setStage(4); setNote("你弃牌了。点发牌员开下一手。"); }}>弃牌</button>
            <button className="btn btn-ghost" onClick={advance}>跟注 {fmtInt(bb * (stage + 1))}</button>
            <button className="btn" onClick={advance}>加注到 {fmtInt(bb * (stage + 1) * 3)}</button>
            <button className="btn btn-text" onClick={() => setSeatIndex(null)}>离桌</button>
          </>
        ) : (
          <button className="btn" onClick={() => sit(seats.findIndex((s, i) => i === 0 || !s.login))}>
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
