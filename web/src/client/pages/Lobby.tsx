import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router";
import { api, fmtInt } from "../api";
import { FeltTable, MarqueeSign, PlayingCard, fmtMoney, type CardSpec, type Seat } from "../components";
import { Dealer } from "../Dealer";
import type { Suit } from "../suits";
import { DEFAULT_TABLE, TABLES } from "../tables";
import { useTable } from "../useTable";
import { loginHref, notifyMeChanged, useMe } from "../useMe";
import type { Card } from "../../shared/poker/cards";
import { BLIND_LEVELS, BUY_IN_BB, MAX_BUY_IN_BB, MIN_BUY_IN_BB } from "../../shared/poker/room";
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

type TableEntry = { no: number; id: string; blinds: [number, number]; bots?: boolean; seated: number; temporary?: boolean };

/** 底部面板：入座选带入，或者开桌选盲注和带入 */
type Panel = { kind: "sit"; seat: number } | { kind: "open" };

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

/** 加注滑杆旁的几个快捷额度（单位筹码）：常规、半池、底池。全下拖到头就是。 */
function raisePresets(view: TableView) {
  const legal = view.legal;
  if (!legal?.canRaise) return [];
  const [sb, bb] = view.blinds;
  const current = Math.max(0, ...view.seats.map((x) => x?.bet ?? 0));
  const clamp = (n: number) => Math.min(legal.maxRaiseTo, Math.max(legal.minRaiseTo, Math.round(n / sb) * sb));
  const afterCall = view.pot + legal.toCall;
  const list = [
    { label: current <= bb && view.street === "preflop" ? "2.5x" : current > bb ? "3x" : "最小", to: clamp(current <= bb ? (view.street === "preflop" ? 2.5 * bb : 0) : 3 * current) },
    { label: "半池", to: clamp(current + afterCall / 2) },
    { label: "底池", to: clamp(current + afterCall) },
  ];
  return list.filter((o, k) => list.findIndex((x) => x.to === o.to) === k);
}

/** 滑杆按小盲取整，但两头的最小加注和全下要能取到。 */
function snap(n: number, min: number, max: number, step: number) {
  if (n >= max) return max;
  if (n <= min) return min;
  return Math.min(max, Math.max(min, Math.round(n / step) * step));
}

/** 带入滑杆：min～max 之间按大盲取整，默认 100 个大盲。 */
function BuyInSlider({ bb, balance, value, onChange }: { bb: number; balance: number; value: number; onChange: (n: number) => void }) {
  const min = MIN_BUY_IN_BB * bb;
  const max = Math.min(MAX_BUY_IN_BB * bb, balance);
  if (max < min) return <span className="panel-hint">筹码不够：最少要带 {fmtMoney(min)}，你有 {fmtMoney(balance)}</span>;
  return (
    <label className="slider">
      <span className="slider-label">带入</span>
      <input type="range" min={min} max={max} step={bb} value={value} onChange={(e) => onChange(snap(Number(e.target.value), min, max, bb))} />
      <b className="slider-value">{fmtMoney(value)}</b>
    </label>
  );
}

const defaultBuyIn = (bb: number, balance: number) =>
  Math.max(MIN_BUY_IN_BB * bb, Math.min(BUY_IN_BB * bb, MAX_BUY_IN_BB * bb, balance));

/**
 * 大厅就是一张牌桌：右下角切桌、开桌，点空位选带入后入座。牌局在服务端跑（每张桌一个 Durable Object），
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
  const [panel, setPanel] = useState<Panel | null>(null);
  const [buyIn, setBuyIn] = useState(0);
  const [openBlinds, setOpenBlinds] = useState<[number, number]>(BLIND_LEVELS[1]);
  const [raiseTo, setRaiseTo] = useState(0);
  /** 开桌后等连上新桌自动入座 */
  const [pendingSit, setPendingSit] = useState<{ no: number; buyIn: number } | null>(null);
  const conn = useTable(table);
  const view = conn.view;
  /** 切到另一张桌之后要显示的话（切桌会清掉旧的提示） */
  const flash = useRef<string | null>(null);

  const loadTables = () =>
    DEMO
      ? Promise.resolve()
      : api<{ tables: Omit<TableEntry, "id">[] }>("/api/tables").then(
          (r) => r.tables.length && setTables(r.tables.map((t) => ({ ...t, id: String(t.no) }))),
          () => {},
        );
  useEffect(() => {
    loadTables();
  }, []);
  useEffect(() => {
    setNote(flash.current);
    flash.current = null;
    setPanel(null);
  }, [table.no]);
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
  // 玩家开的桌没人了被收掉：从列表里拿掉，回到默认那张桌
  useEffect(() => {
    if (!conn.closed) return;
    const gone = table.no;
    setTables((ts) => ts.filter((t) => t.no !== gone));
    setSlide("slide-prev");
    flash.current = `#${gone} 没人了，已经收桌`;
    navigate(`/table/${DEFAULT_TABLE.id}`);
  }, [conn.closed]);

  const signedIn = !!me?.user;
  const balance = me?.points?.balance ?? 0;
  const bb = table.blinds[1];
  const you = view?.you ?? null;
  // 入座后把自己转到下方中间（4 号位），其他人按顺时针相对位置排
  const toDisplay = (i: number) => (you === null ? i : (i - you + 3 + SEAT_COUNT) % SEAT_COUNT);
  // 入座扣了带入、离桌退回筹码，顶栏的余额跟着刷新
  useEffect(() => {
    if (view) notifyMeChanged();
    if (you !== null) setPanel(null);
  }, [you === null]);
  const fromDisplay = (d: number) => (you === null ? d : (d + you - 3 + SEAT_COUNT) % SEAT_COUNT);
  // 余额晚到一步（刚登录）时，把带入重新放回默认值
  useEffect(() => {
    if (panel) setBuyIn(defaultBuyIn(panel.kind === "open" ? openBlinds[1] : bb, balance));
  }, [balance]);

  // 开桌后连上新桌就自动坐到第一个空位
  useEffect(() => {
    if (!pendingSit || !view || view.no !== pendingSit.no) return;
    setPendingSit(null);
    if (you !== null) return;
    const free = view.seats.findIndex((x) => !x);
    if (free >= 0) conn.send({ t: "sit", seat: free, buyIn: pendingSit.buyIn });
  }, [pendingSit, view]);

  // 刚弃掉的牌：记下这一手每个座位最后看到的牌，弃牌时播一下收走的动画
  const seen = useRef<{ hand: number; cards: (CardSpec[] | undefined)[] }>({ hand: -1, cards: [] });
  const seats: Seat[] = useMemo(() => {
    const list: Seat[] = Array.from({ length: SEAT_COUNT }, (_, d) => ({ position: `${fromDisplay(d) + 1} 号` }));
    if (!view) return list;
    if (seen.current.hand !== view.handNo) seen.current = { hand: view.handNo, cards: [] };
    const pos = positions(view);
    view.seats.forEach((x, i) => {
      if (!x) return;
      const showdown = view.street === "showdown";
      let seatNote: string | undefined;
      if (showdown && x.won) seatNote = `赢 ${fmtMoney(x.won)}`;
      else if (x.leaving) seatNote = "离桌";
      else if (x.away) seatNote = "掉线";
      else if (x.last) seatNote = x.last;
      const cards = x.cards.length ? x.cards.map(toSpec) : undefined;
      if (cards && !x.folded) seen.current.cards[i] = cards;
      const acting = view.toAct === i && view.turnStart !== null && view.turnMs !== null;
      list[toDisplay(i)] = {
        position: pos[i] ?? (view.street === "idle" ? "等开局" : "下一手"),
        login: x.login,
        you: i === you,
        stack: x.stack,
        bet: x.bet,
        dealer: view.button === i && view.street !== "idle",
        folded: x.folded,
        acting: view.toAct === i,
        cards,
        mucked: x.folded && x.inHand ? seen.current.cards[i] : undefined,
        timer: acting
          ? {
              key: `${view.handNo}-${view.street}-${i}-${view.turnStart}`,
              total: view.turnMs!,
              elapsed: Date.now() + conn.skew - view.turnStart!,
            }
          : undefined,
        note: showdown && x.hand && !x.folded ? `${x.hand}${seatNote ? ` · ${seatNote}` : ""}` : seatNote,
      };
    });
    return list;
  }, [view, you, conn.skew]);

  const board: CardSpec[] = [0, 1, 2, 3, 4].map((i) => (view?.board[i] ? toSpec(view.board[i]) : "back"));
  const stage = view ? STAGE[view.street] : 0;
  const lines = useMemo(() => ["", "翻牌！", "转牌～", "河牌！", view?.say ?? "摊牌，看看谁赢？"], [view?.say]);
  const legal = view?.legal ?? null;
  const presets = view ? raisePresets(view) : [];
  const left = view?.deadline ? Math.max(0, Math.ceil((view.deadline - (now + conn.skew)) / 1000)) : null;
  // 每次轮到自己，滑杆先放在第一个快捷额度上
  useEffect(() => {
    if (legal?.canRaise) setRaiseTo(presets[0]?.to ?? legal.minRaiseTo);
  }, [view?.handNo, view?.street, legal?.canRaise, legal?.minRaiseTo, legal?.maxRaiseTo]);

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

  /** 先登录：线上跳 GitHub，预览版直接切成已登录。返回 false 表示正在跳走。 */
  const ensureSignedIn = async () => {
    if (signedIn) return true;
    if (!DEMO) {
      location.href = loginHref(`/table/${table.id}`);
      return false;
    }
    (await import("../demo")).demoLogin();
    notifyMeChanged();
    return true;
  };

  const showOpenPanel = async () => {
    if (!(await ensureSignedIn())) return;
    const blinds = BLIND_LEVELS.find(([s, b]) => s === table.blinds[0] && b === table.blinds[1]) ?? BLIND_LEVELS[1];
    setOpenBlinds(blinds);
    setBuyIn(defaultBuyIn(blinds[1], balance));
    setNote(null);
    setPanel({ kind: "open" });
  };

  /** 开桌：选好盲注和带入，开好后自动入座。 */
  const openTable = async () => {
    try {
      let created: TableEntry;
      if (DEMO) {
        created = { no: Math.max(...tables.map((t) => t.no)) + 1, id: "", blinds: openBlinds, seated: 0, temporary: true };
        created.id = String(created.no);
        setTables([...tables, created]);
      } else {
        const r = await api<{ table: Omit<TableEntry, "id"> }>("/api/tables", { method: "POST", json: { blinds: openBlinds } });
        created = { ...r.table, id: String(r.table.no) };
        setTables((ts) => [...ts, created]);
      }
      setPanel(null);
      setPendingSit({ no: created.no, buyIn });
      setSlide("slide-next");
      flash.current = `开好了 #${created.no}，盲注 ${fmtMoney(created.blinds[0])}/${fmtMoney(created.blinds[1])}。没人坐的桌会自动收掉。`;
      navigate(`/table/${created.id}`);
    } catch (e) {
      setNote((e as Error).message);
    }
  };

  const pickSeat = async (display: number) => {
    if (!(await ensureSignedIn())) return;
    setNote(null);
    setBuyIn(defaultBuyIn(bb, balance));
    setPanel({ kind: "sit", seat: fromDisplay(display) });
  };

  const sit = (seat: number) => {
    setNote(null);
    conn.send({ t: "sit", seat, buyIn });
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

  const current = Math.max(0, ...(view?.seats.map((x) => x?.bet ?? 0) ?? [0]));
  const raiseLabel = legal
    ? raiseTo >= legal.maxRaiseTo ? `全下 ${fmtMoney(legal.maxRaiseTo)}` : `${current === 0 ? "下注" : "加注到"} ${fmtMoney(raiseTo)}`
    : "";

  const panelView = panel && (
    <div className="panel">
      {panel.kind === "open" && (
        <div className="seg" role="tablist" aria-label="盲注">
          {BLIND_LEVELS.map((b) => (
            <button
              key={b[1]}
              role="tab"
              aria-selected={b === openBlinds}
              onClick={() => {
                setOpenBlinds(b);
                setBuyIn(defaultBuyIn(b[1], balance));
              }}
            >
              {fmtMoney(b[0])}/{fmtMoney(b[1])}
            </button>
          ))}
        </div>
      )}
      <div className="panel-row">
        <BuyInSlider bb={panel.kind === "open" ? openBlinds[1] : bb} balance={balance} value={buyIn} onChange={setBuyIn} />
        {panel.kind === "open" ? (
          <button className="btn" disabled={balance < MIN_BUY_IN_BB * openBlinds[1]} onClick={openTable}>开桌并入座</button>
        ) : (
          <button className="btn" disabled={balance < MIN_BUY_IN_BB * bb} onClick={() => sit(panel.seat)}>入座</button>
        )}
        <button className="btn btn-text" onClick={() => setPanel(null)}>取消</button>
      </div>
    </div>
  );

  return (
    <div className="lobby">
      <MarqueeSign text="yybar" />

      <FeltTable
        key={table.id}
        className={slide}
        seats={seats}
        onEmptySeat={(i) => pickSeat(i)}
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
                <small>{fmtMoney(table.blinds[0])}/{fmtMoney(table.blinds[1])}</small>
              </span>
            )}
            <button className="icon-btn" onClick={() => switchTable(1)} aria-label="下一张桌">
              <svg viewBox="0 0 12 12" aria-hidden><path d="M3.5 1.8v8.4L9.8 6z" /></svg>
            </button>
            <button className="icon-btn" onClick={() => (searching ? findTable() : setSearching(true))} aria-label="按桌号找桌" title="按桌号找桌">
              <svg viewBox="0 0 12 12" aria-hidden className="stroke"><circle cx="5.2" cy="5.2" r="3.4" /><path d="M7.8 7.8 10.4 10.4" /></svg>
            </button>
            <button className="icon-btn icon-btn-new" onClick={showOpenPanel} aria-label="开一张桌" title="开一张桌">
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
              <b key={view?.pot ?? 0}>{fmtMoney(view?.pot ?? 0)}</b>
              <small>盲注 {fmtMoney(table.blinds[0])}/{fmtMoney(table.blinds[1])}</small>
            </div>
          </div>
        }
      />

      <div className="actions">
        {panelView ??
          (you !== null ? (
            legal ? (
              <>
                {legal.canRaise && (
                  <div className="raise">
                    {presets.map((o) => (
                      <button key={o.label} className={`btn btn-small btn-ghost${raiseTo === o.to ? " on" : ""}`} onClick={() => setRaiseTo(o.to)}>
                        {o.label}
                      </button>
                    ))}
                    <input
                      type="range"
                      aria-label="加注额"
                      min={legal.minRaiseTo}
                      max={legal.maxRaiseTo}
                      step={view!.blinds[0]}
                      value={raiseTo}
                      onChange={(e) => setRaiseTo(snap(Number(e.target.value), legal.minRaiseTo, legal.maxRaiseTo, view!.blinds[0]))}
                    />
                  </div>
                )}
                <button className="btn btn-ghost" onClick={() => act("fold")}>弃牌</button>
                <button className="btn btn-ghost" onClick={() => act(legal.canCheck ? "check" : "call")}>
                  {legal.canCheck ? "过牌" : `跟注 ${fmtMoney(legal.toCall)}`}
                </button>
                {legal.canRaise && <button className="btn" onClick={() => act("raise", raiseTo)}>{raiseLabel}</button>}
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
          ) : null)}
      </div>
      {(note ?? status) && <p className="note" role="status">{note ?? status}</p>}
    </div>
  );
}
