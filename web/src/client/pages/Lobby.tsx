import { useEffect, useMemo, useState } from "react";
import { useNavigate, useParams } from "react-router";
import { api, fmtInt } from "../api";
import { FeltTable, MarqueeSign, PlayingCard, fmtBB, type CardSpec, type Seat } from "../components";
import { Dealer } from "../Dealer";
import type { Suit } from "../suits";
import { DEFAULT_TABLE, TABLES } from "../tables";
import { useTable } from "../useTable";
import { loginHref, notifyMeChanged, useMe } from "../useMe";
import type { Card } from "../../shared/poker/cards";
import type { TableView } from "../../shared/poker/types";

const DEMO = !!import.meta.env.VITE_DEMO;
const SEAT_COUNT = 6;
const SUITS: Suit[] = ["gpt", "claude", "gemini", "grok"];
const RANK_LABEL: Record<number, string> = { 11: "J", 12: "Q", 13: "K", 14: "A" };
const STAGE: Record<TableView["street"], number> = { idle: 0, preflop: 0, flop: 1, turn: 2, river: 3, showdown: 4 };
/** 从庄家起顺时针，按这一手的人数叫位置 */
const POSITION_NAMES: Record<number, string[]> = {
  2: ["BTN", "BB"],
  3: ["BTN", "SB", "BB"],
  4: ["BTN", "SB", "BB", "CO"],
  5: ["BTN", "SB", "BB", "HJ", "CO"],
  6: ["BTN", "SB", "BB", "UTG", "HJ", "CO"],
};

type TableEntry = { no: number; id: string; blinds: [number, number]; bots?: boolean; seated: number };

const toSpec = (c: Card | null): CardSpec => (c ? { rank: RANK_LABEL[c.r] ?? String(c.r), suit: SUITS[c.s] } : "back");

function positions(view: TableView): (string | null)[] {
  const out: (string | null)[] = Array(SEAT_COUNT).fill(null);
  const playing = view.street !== "idle";
  const ring: number[] = [];
  for (let k = 0; k < SEAT_COUNT; k++) {
    const i = (Math.max(view.button, 0) + k) % SEAT_COUNT;
    const x = view.seats[i];
    if (x && (playing ? x.inHand : true)) ring.push(i);
  }
  const names = POSITION_NAMES[ring.length];
  if (names && playing) ring.forEach((i, k) => (out[i] = names[k]));
  return out;
}

/** 加注的几个快捷额度（单位筹码）：常规、底池、全下。 */
function raiseOptions(view: TableView) {
  const legal = view.legal;
  if (!legal?.canRaise) return [];
  const [sb, bb] = view.blinds;
  const current = Math.max(0, ...view.seats.map((x) => x?.bet ?? 0));
  const clamp = (n: number) => Math.min(legal.maxRaiseTo, Math.max(legal.minRaiseTo, Math.round(n / sb) * sb));
  const standard = current <= bb ? (view.street === "preflop" ? 2.5 * bb : current + view.pot / 2) : 3 * current;
  const potSize = current + view.pot + legal.toCall;
  const list = [clamp(standard), clamp(potSize), legal.maxRaiseTo];
  return [...new Set(list)].map((to) => ({
    to,
    label: to === legal.maxRaiseTo ? `全下 ${fmtBB(to / bb)} bb` : `${current === 0 ? "下注" : "加注到"} ${fmtBB(to / bb)} bb`,
  }));
}

/**
 * 大厅就是一张牌桌：右下角切桌，点空位入座。牌局在服务端跑（每张桌一个 Durable Object），
 * 这里只显示自己能看到的部分，再把弃牌、跟注、加注发回去。
 */
export function LobbyPage() {
  const { id } = useParams();
  const navigate = useNavigate();
  const { me } = useMe();
  const [tables, setTables] = useState<TableEntry[]>(TABLES);
  const table = tables.find((t) => t.id === id) ?? tables.find((t) => t.no === DEFAULT_TABLE.no) ?? tables[0];
  const [slide, setSlide] = useState<"" | "slide-next" | "slide-prev">("");
  const [searching, setSearching] = useState(false);
  const [query, setQuery] = useState("");
  const [note, setNote] = useState<string | null>(null);
  const [now, setNow] = useState(Date.now());
  const conn = useTable(table);
  const view = conn.view;

  const loadTables = () =>
    DEMO
      ? Promise.resolve()
      : api<{ tables: { no: number; blinds: [number, number]; bots: boolean; seated: number }[] }>("/api/tables").then(
          (r) => r.tables.length && setTables(r.tables.map((t) => ({ ...t, id: String(t.no) }))),
          () => {},
        );
  useEffect(() => {
    loadTables();
  }, []);
  useEffect(() => setNote(null), [table.no]);
  useEffect(() => {
    if (conn.error) setNote(conn.error);
  }, [conn.error]);
  // 行动倒计时
  useEffect(() => {
    if (!view?.deadline) return;
    setNow(Date.now());
    const t = setInterval(() => setNow(Date.now()), 500);
    return () => clearInterval(t);
  }, [view?.deadline]);

  const signedIn = !!me?.user;
  const bb = table.blinds[1];
  const you = view?.you ?? null;
  // 入座后把自己转到下方中间（4 号位），其他人按顺时针相对位置排
  const toDisplay = (i: number) => (you === null ? i : (i - you + 3 + SEAT_COUNT) % SEAT_COUNT);
  // 入座扣了买入、离桌退回筹码，顶栏的余额跟着刷新
  useEffect(() => {
    if (!DEMO && view) notifyMeChanged();
  }, [you === null]);
  const fromDisplay = (d: number) => (you === null ? d : (d + you - 3 + SEAT_COUNT) % SEAT_COUNT);

  const seats: Seat[] = useMemo(() => {
    const list: Seat[] = Array.from({ length: SEAT_COUNT }, (_, d) => ({ position: `${fromDisplay(d) + 1} 号` }));
    if (!view) return list;
    const pos = positions(view);
    view.seats.forEach((x, i) => {
      if (!x) return;
      const showdown = view.street === "showdown";
      let seatNote: string | undefined;
      if (showdown && x.won) seatNote = `赢 ${fmtBB(x.won / bb)} bb`;
      else if (x.leaving) seatNote = "离桌";
      else if (x.away) seatNote = "掉线";
      else if (x.last) seatNote = x.last.replace(/\d[\d,]*/g, (n) => `${fmtBB(Number(n.replace(/,/g, "")) / bb)} bb`);
      list[toDisplay(i)] = {
        position: pos[i] ?? (view.street === "idle" ? "等开局" : "下一手"),
        login: x.login,
        you: i === you,
        stack: x.stack / bb,
        bet: x.bet / bb,
        dealer: view.button === i && view.street !== "idle",
        folded: x.folded,
        acting: view.toAct === i,
        cards: x.cards.length ? x.cards.map(toSpec) : undefined,
        note: showdown && x.hand && !x.folded ? `${x.hand}${seatNote ? ` · ${seatNote}` : ""}` : seatNote,
      };
    });
    return list;
  }, [view, you, bb]);

  const board: CardSpec[] = [0, 1, 2, 3, 4].map((i) => (view?.board[i] ? toSpec(view.board[i]) : "back"));
  const stage = view ? STAGE[view.street] : 0;
  const lines = useMemo(() => ["", "翻牌！", "转牌～", "河牌！", view?.say ?? "摊牌，看看谁赢？"], [view?.say]);
  const legal = view?.legal ?? null;
  const left = view?.deadline ? Math.max(0, Math.ceil((view.deadline - (now + conn.skew)) / 1000)) : null;

  const switchTable = (step: number) => {
    const i = tables.findIndex((t) => t.id === table.id);
    setSlide(step > 0 ? "slide-next" : "slide-prev");
    navigate(`/table/${tables[(i + step + tables.length) % tables.length].id}`);
  };

  const findTable = () => {
    const no = query.trim().replace(/^#/, "");
    if (!no) return setSearching(false);
    const t = tables.find((x) => x.id === no);
    if (!t) return setNote(`没有 #${no} 这张桌`);
    const i = tables.indexOf(t), cur = tables.indexOf(table);
    if (t !== table) setSlide(i > cur ? "slide-next" : "slide-prev");
    navigate(`/table/${t.id}`);
    setSearching(false);
    setQuery("");
  };

  /** 开桌：盲注和当前这张桌一样。 */
  const openTable = async () => {
    if (!signedIn && !DEMO) {
      location.href = loginHref(`/table/${table.id}`);
      return;
    }
    try {
      let created: TableEntry;
      if (DEMO) {
        created = { no: Math.max(...tables.map((t) => t.no)) + 1, id: "", blinds: table.blinds, seated: 0 };
        created.id = String(created.no);
        setTables([...tables, created]);
      } else {
        const r = await api<{ table: { no: number; blinds: [number, number]; bots: boolean; seated: number } }>("/api/tables", {
          method: "POST",
          json: { from: table.no },
        });
        created = { ...r.table, id: String(r.table.no) };
        setTables((ts) => [...ts, created]);
      }
      setSlide("slide-next");
      navigate(`/table/${created.id}`);
      setNote(`开好了 #${created.no}，盲注 ${fmtInt(created.blinds[0])}/${fmtInt(created.blinds[1])}，坐下等人来。`);
    } catch (e) {
      setNote((e as Error).message);
    }
  };

  const sit = async (display: number) => {
    if (!signedIn) {
      if (!DEMO) {
        location.href = loginHref(`/table/${table.id}`);
        return;
      }
      (await import("../demo")).demoLogin();
      notifyMeChanged();
    }
    setNote(null);
    conn.send({ t: "sit", seat: fromDisplay(display) });
  };

  const act = (action: "fold" | "check" | "call" | "raise", amount?: number) => {
    setNote(null);
    conn.send({ t: "act", action, amount });
  };

  const status = (() => {
    if (!view) return conn.connected ? null : "正在连接牌桌…";
    if (you === null) return null;
    if (legal) return `轮到你了${left !== null ? `，还剩 ${left} 秒` : ""}`;
    if (view.street === "idle") return "等人入座，凑够两个人就开局";
    if (!view.seats[you]?.inHand) return "下一手开始时发牌给你";
    return null;
  })();

  return (
    <div className="lobby">
      <MarqueeSign text="yybar" />

      <FeltTable
        key={table.id}
        className={slide}
        seats={seats}
        onEmptySeat={(i) => sit(i)}
        corner={
          <>
            <button className="icon-btn" onClick={() => switchTable(-1)} aria-label="上一张桌">
              <svg viewBox="0 0 12 12" aria-hidden><path d="M8.5 1.8v8.4L2.2 6z" /></svg>
            </button>
            {searching ? (
              <form className="corner-search" onSubmit={(e) => { e.preventDefault(); findTable(); }}>
                <input
                  autoFocus
                  inputMode="numeric"
                  placeholder="桌号"
                  value={query}
                  onChange={(e) => setQuery(e.target.value)}
                  onKeyDown={(e) => e.key === "Escape" && setSearching(false)}
                  aria-label="输入桌号"
                />
              </form>
            ) : (
              <span className="corner-label">
                #{table.no}
                <small>{fmtInt(table.blinds[0])}/{fmtInt(table.blinds[1])}</small>
              </span>
            )}
            <button className="icon-btn" onClick={() => switchTable(1)} aria-label="下一张桌">
              <svg viewBox="0 0 12 12" aria-hidden><path d="M3.5 1.8v8.4L9.8 6z" /></svg>
            </button>
            <button className="icon-btn" onClick={() => (searching ? findTable() : setSearching(true))} aria-label="按桌号找桌" title="按桌号找桌">
              <svg viewBox="0 0 12 12" aria-hidden className="stroke"><circle cx="5.2" cy="5.2" r="3.4" /><path d="M7.8 7.8 10.4 10.4" /></svg>
            </button>
            <button className="icon-btn icon-btn-new" onClick={openTable} aria-label="开一张桌" title="开一张同样盲注的桌">
              <svg viewBox="0 0 12 12" aria-hidden><path d="M6 2v8M2 6h8" /></svg>
            </button>
          </>
        }
        center={
          <div className="felt-center">
            <Dealer stage={stage} onAdvance={() => you === null && view?.street === "idle" && setNote("点空位入座，凑够两个人就开局。")} lines={lines} />
            <div className="board-cards">
              {board.map((c, i) => (
                <PlayingCard key={`${i}-${c === "back" ? "b" : c.rank + c.suit}`} card={c} />
              ))}
            </div>
            <div className="pot">
              <span>底池</span>
              <b>{fmtBB((view?.pot ?? 0) / bb)} bb</b>
              <small>盲注 {fmtInt(table.blinds[0])}/{fmtInt(table.blinds[1])}</small>
            </div>
          </div>
        }
      />

      <div className="actions">
        {you !== null ? (
          legal ? (
            <>
              <button className="btn btn-ghost" onClick={() => act("fold")}>弃牌</button>
              <button className="btn btn-ghost" onClick={() => act(legal.canCheck ? "check" : "call")}>
                {legal.canCheck ? "过牌" : `跟注 ${fmtBB(legal.toCall / bb)} bb`}
              </button>
              {raiseOptions(view!).map((o) => (
                <button key={o.to} className="btn" onClick={() => act("raise", o.to)}>{o.label}</button>
              ))}
              <button className="btn btn-text" onClick={() => conn.send({ t: "leave" })}>离桌</button>
            </>
          ) : (
            <>
              <button className="btn btn-ghost" disabled>弃牌</button>
              <button className="btn btn-ghost" disabled>过牌</button>
              <button className="btn" disabled>加注</button>
              <button className="btn btn-text" onClick={() => conn.send({ t: "leave" })}>离桌</button>
            </>
          )
        ) : null}
      </div>
      {(note ?? status) && <p className="note" role="status">{note ?? status}</p>}

    </div>
  );
}
