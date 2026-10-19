import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router";
import { api, fmtInt } from "../api";
import { FeltTable, MarqueeSign, PlayingCard, fmtMoney, type CardSpec, type Seat } from "../components";
import { Dealer } from "../Dealer";
import type { Suit } from "../suits";
import { DEFAULT_TABLE, TABLES } from "../tables";
import { useSeatWatch, useTable } from "../useTable";
import { loginHref, notifyMeChanged, useMe } from "../useMe";
import type { Card } from "../../shared/poker/cards";
import { BLIND_LEVELS, BUY_IN_BB, MAX_BUY_IN_BB, MIN_BUY_IN_BB } from "../../shared/poker/room";
import { DEFAULT_BACK, DEFAULT_FACE } from "../../shared/cosmetics";
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

/** 登录后发牌员说的一句问候，像 Claude 官网那样：「又开工了，hyi」 */
function greeting(name: string) {
  const h = new Date().getHours();
  const byTime = h < 5 ? "夜深了" : h < 11 ? "早上好" : h < 14 ? "中午好" : h < 18 ? "下午好" : h < 23 ? "晚上好" : "夜深了";
  const lines = [`又开工了，${name}`, `${name}，来两手？`, `欢迎回来，${name}`, `${byTime}，${name}`, `${byTime}，${name}`];
  return lines[Math.floor(Math.random() * lines.length)];
}

/** 入座后桌子转动时每走一格的时长，和 styles.css 里 .seat 的 transition 一致 */
const ROTATE_STEP_MS = 360;

/**
 * 大厅就是一张牌桌：右下角切桌、开桌、铃铛，点空位先占座再选带入。牌局在服务端跑（每张桌一个 Durable Object），
 * 这里只显示自己能看到的部分，再把弃牌、跟注、加注发回去。可以同时坐几张桌：坐着的其他桌在后台连着，
 * 轮到你行动时铃铛会响（手机上震动），点铃铛回到那张桌。
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
  const [confirmLeave, setConfirmLeave] = useState(false);
  /** 自己坐着的桌（桌号） */
  const [mySeats, setMySeats] = useState<Set<number>>(new Set());
  /** 开桌后等连上新桌自动入座 */
  const [pendingSit, setPendingSit] = useState<{ no: number; buyIn: number } | null>(null);
  const conn = useTable(table);
  const view = conn.view;
  /** 切到另一张桌之后要显示的话（切桌会清掉旧的提示） */
  const flash = useRef<string | null>(null);
  /** 占座的面板开着时，服务端是否已经确认占到了 */
  const holdSeen = useRef(false);

  const loadTables = () =>
    DEMO
      ? Promise.resolve()
      : api<{ tables: Omit<TableEntry, "id">[]; mine?: number[] }>("/api/tables").then(
          (r) => {
            if (r.tables.length) setTables(r.tables.map((t) => ({ ...t, id: String(t.no) })));
            if (r.mine?.length) setMySeats((m) => new Set([...m, ...r.mine!]));
          },
          () => {},
        );
  useEffect(() => {
    loadTables();
  }, [!!me?.user]);
  useEffect(() => {
    setNote(flash.current);
    flash.current = null;
    setPanel(null);
    setConfirmLeave(false);
  }, [table.no]);
  useEffect(() => {
    if (!conn.error) return;
    setNote(conn.error);
    // 没占到座（被别人抢了）就收起选带入的面板
    if (panel?.kind === "sit" && !holdSeen.current) setPanel(null);
  }, [conn.error]);
  // 行动、占座倒计时
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
    setMySeats((m) => ((m = new Set(m)), m.delete(gone), m));
    setSlide("slide-prev");
    flash.current = `#${gone} 没人了，已经收桌`;
    navigate(`/table/${DEFAULT_TABLE.id}`);
  }, [conn.closed]);

  const signedIn = !!me?.user;
  /** 自己在商场换上的牌背（桌上的背面牌都用它）和牌面（只有自己看得到） */
  const look = me?.look ?? { back: DEFAULT_BACK, face: DEFAULT_FACE };
  // 登录后发牌员打个招呼，几秒后气泡自己消失
  const [greet, setGreet] = useState<string | null>(null);
  useEffect(() => {
    if (me?.user) setGreet(greeting(me.user.name || me.user.login));
  }, [me?.user?.login]);
  const balance = me?.points?.balance ?? 0;
  const bb = table.blinds[1];
  const you = view?.you ?? null;
  // 入座后把自己转到下方（3 号显示位），其他人按顺时针相对位置排。
  // rot 一格一格追上目标，座位沿着桌边一个位置一个位置走过去，看得出桌子在转
  const rotTarget = you === null ? 0 : (3 - you + SEAT_COUNT) % SEAT_COUNT;
  const [rot, setRot] = useState(rotTarget);
  // 刚切到一张桌（第一次拿到牌桌）直接摆好，不转
  const placed = useRef<number | null>(null);
  useEffect(() => {
    if (!view || placed.current === view.no) return;
    placed.current = view.no;
    setRot(rotTarget);
  }, [view?.no, rotTarget]);
  useEffect(() => {
    if (rot === rotTarget || placed.current !== view?.no) return;
    const step = (rotTarget - rot + SEAT_COUNT) % SEAT_COUNT <= SEAT_COUNT / 2 ? 1 : -1;
    const t = setTimeout(() => setRot((r) => (r + step + SEAT_COUNT) % SEAT_COUNT), ROTATE_STEP_MS);
    return () => clearTimeout(t);
  }, [rot, rotTarget]);
  // 还没摆好（刚切桌的第一帧）就按目标摆，免得从上一张桌的角度滑过来
  const shownRot = placed.current === view?.no ? rot : rotTarget;
  const toDisplay = (i: number) => (i + shownRot) % SEAT_COUNT;
  const fromDisplay = (d: number) => (d - shownRot + SEAT_COUNT) % SEAT_COUNT;
  // 入座扣了带入、离桌退回筹码，顶栏的余额跟着刷新
  useEffect(() => {
    if (view) notifyMeChanged();
    if (you !== null) setPanel(null);
  }, [you === null]);
  // 余额晚到一步（刚登录）时，把带入重新放回默认值
  useEffect(() => {
    if (panel) setBuyIn(defaultBuyIn(panel.kind === "open" ? openBlinds[1] : bb, balance));
  }, [balance]);

  // 记下自己坐在哪几张桌
  useEffect(() => {
    if (!view || view.no !== table.no) return;
    setMySeats((m) => {
      const has = m.has(view.no), seated = view.you !== null;
      if (has === seated) return m;
      m = new Set(m);
      if (seated) m.add(view.no);
      else m.delete(view.no);
      return m;
    });
  }, [view?.no, view?.you]);
  const watchList = useMemo(() => tables.filter((t) => mySeats.has(t.no) && t.no !== table.no), [tables, mySeats, table.no]);
  const watched = useSeatWatch(watchList);
  useEffect(() => {
    const left = [...watched].filter(([, v]) => v.you === null).map(([no]) => no);
    if (left.length) setMySeats((m) => new Set([...m].filter((no) => !left.includes(no))));
  }, [watched]);
  /** 别的桌里轮到自己行动的 */
  const turnElsewhere = [...watched].filter(([, v]) => v.legal).map(([no]) => no);
  const myTurnKey = [...turnElsewhere, ...(view?.legal ? [table.no] : [])].join();
  const [ring, setRing] = useState(0);
  // 新轮到自己时震动，铃铛晃一下
  const lastTurns = useRef("");
  useEffect(() => {
    const before = new Set(lastTurns.current.split(",").filter(Boolean));
    lastTurns.current = myTurnKey;
    if (myTurnKey.split(",").some((no) => no && !before.has(no))) {
      navigator.vibrate?.([120, 60, 120]);
      setRing((r) => r + 1);
    }
  }, [myTurnKey]);

  // 在这桌输光了：服务端替你占着座位 10 秒，有余额就弹出买入面板，没余额直接放开
  const rebuyFor = useRef("");
  useEffect(() => {
    if (!view || you !== null || !me?.points) return;
    const i = view.holds.findIndex((h) => h?.you);
    const h = view.holds[i];
    if (!h) return;
    // 每次占座只处理一次；自己点空位占的（面板已经开着）也记下，免得取消后又弹出来
    const key = `${view.no}-${i}-${h.start}`;
    if (rebuyFor.current === key) return;
    rebuyFor.current = key;
    if (panel) return;
    if (balance < MIN_BUY_IN_BB * bb) {
      conn.send({ t: "release" });
      return;
    }
    holdSeen.current = true;
    setBuyIn(defaultBuyIn(bb, balance));
    setPanel({ kind: "sit", seat: i });
    setNote("筹码输光了，10 秒内可以在原位再买入");
  }, [view, you, panel, me?.points]);

  // 占座：服务端确认后才算占到；10 秒没入座被放开，就收起面板
  useEffect(() => {
    if (panel?.kind !== "sit" || !view) return;
    if (view.holds[panel.seat]?.you) holdSeen.current = true;
    else if (holdSeen.current && you === null) {
      setPanel(null);
      setNote("10 秒内没入座，座位放开了");
    }
  }, [view, panel]);

  // 开桌后连上新桌就自动坐到第一个空位
  useEffect(() => {
    if (!pendingSit || !view || view.no !== pendingSit.no) return;
    setPendingSit(null);
    if (you !== null) return;
    const free = view.seats.findIndex((x, i) => !x && !view.holds[i]);
    if (free >= 0) conn.send({ t: "sit", seat: free, buyIn: pendingSit.buyIn });
  }, [pendingSit, view]);

  // 刚弃掉的牌：记下这一手每个座位最后看到的牌，弃牌时播一下收走的动画
  const seen = useRef<{ hand: number; cards: (CardSpec[] | undefined)[] }>({ hand: -1, cards: [] });
  const seats: Seat[] = useMemo(() => {
    const list: Seat[] = Array.from({ length: SEAT_COUNT }, (_, d) => ({ id: fromDisplay(d), position: `${fromDisplay(d) + 1} 号` }));
    if (!view) return list;
    if (seen.current.hand !== view.handNo) seen.current = { hand: view.handNo, cards: [] };
    const pos = positions(view);
    const clock = Date.now() + conn.skew;
    view.holds.forEach((h, i) => {
      if (!h || view.seats[i]) return;
      list[toDisplay(i)] = {
        id: i,
        position: `${i + 1} 号`,
        login: h.login,
        you: h.you,
        held: { key: `hold-${i}-${h.start}`, total: h.until - h.start, elapsed: clock - h.start },
      };
    });
    view.seats.forEach((x, i) => {
      if (!x) return;
      const showdown = view.street === "showdown";
      let seatNote: string | undefined;
      if (showdown && x.hand && !x.folded) seatNote = x.hand;
      else if (x.leaving) seatNote = "离桌";
      else if (x.away) seatNote = "掉线";
      else if (x.last) seatNote = x.last;
      const cards = x.cards.length ? x.cards.map(toSpec) : undefined;
      if (cards && !x.folded) seen.current.cards[i] = cards;
      const acting = view.toAct === i && view.turnStart !== null && view.turnMs !== null;
      const canShow = i === you && showdown && x.inHand && !x.folded && x.showMask < 3;
      list[toDisplay(i)] = {
        id: i,
        position: pos[i] ?? (view.street === "idle" ? "等开局" : "下一手"),
        login: x.login,
        you: i === you,
        stack: x.stack,
        bet: x.bet,
        folded: x.folded,
        acting: view.toAct === i,
        cards,
        back: x.back,
        mucked: x.folded && x.inHand ? seen.current.cards[i] : undefined,
        timer: acting ? { key: `${view.handNo}-${view.street}-${i}-${view.turnStart}`, total: view.turnMs!, elapsed: clock - view.turnStart! } : undefined,
        win: showdown && x.won > 0 ? { amount: x.won, hand: x.hand } : undefined,
        // 摊牌亮出来的牌留在手里翻开；赢了没摊牌主动亮的丢到桌面上
        tossed: x.hand ? 0 : x.showMask,
        onShow: canShow ? (k) => conn.send({ t: "show", which: k }) : undefined,
        note: seatNote,
      };
    });
    return list;
  }, [view, you, shownRot, conn.skew]);

  const board: CardSpec[] = [0, 1, 2, 3, 4].map((i) => (view?.board[i] ? toSpec(view.board[i]) : "back"));
  const stage = view ? STAGE[view.street] : 0;
  const legal = view?.legal ?? null;
  const presets = view ? raisePresets(view) : [];
  const left = view?.deadline ? Math.max(0, Math.ceil((view.deadline - (now + conn.skew)) / 1000)) : null;
  const buttonAt = view && view.street !== "idle" && view.button >= 0 ? toDisplay(view.button) : null;
  const yourSeat = you !== null ? view?.seats[you] : null;
  const canShow = !!yourSeat && view?.street === "showdown" && yourSeat.inHand && !yourSeat.folded && yourSeat.showMask < 3;
  // 每次轮到自己，滑杆先放在第一个快捷额度上
  useEffect(() => {
    if (legal?.canRaise) setRaiseTo(presets[0]?.to ?? legal.minRaiseTo);
  }, [view?.handNo, view?.street, legal?.canRaise, legal?.minRaiseTo, legal?.maxRaiseTo]);

  const goTo = (no: number) => {
    const i = tables.findIndex((t) => t.no === no), cur = tables.indexOf(table);
    if (i < 0) return;
    if (i !== cur) setSlide(i > cur ? "slide-next" : "slide-prev");
    navigate(`/table/${tables[i].id}`);
  };

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
    goTo(t.no);
    setSearching(false);
    setQuery("");
  };

  /** 铃铛：先去轮到你行动的那张桌，没有就去你坐着的另一张桌。 */
  const ringBell = () => {
    const target = turnElsewhere[0] ?? [...mySeats].find((no) => no !== table.no);
    if (target !== undefined) goTo(target);
    else setNote(mySeats.has(table.no) ? "你只坐了这一张桌，轮到你时铃铛会响" : "坐下后，轮到你行动时铃铛会响");
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
    // 坐着的时候不能开新桌，免得一个人开一堆桌
    const sitting = [...mySeats];
    if (sitting.length) {
      setPanel(null);
      setNote(`你还坐在 #${sitting.join("、#")}，离桌后才能开新桌`);
      return;
    }
    const blinds = BLIND_LEVELS.find(([s, b]) => s === table.blinds[0] && b === table.blinds[1]) ?? BLIND_LEVELS[1];
    setOpenBlinds(blinds);
    setBuyIn(defaultBuyIn(blinds[1], balance));
    setNote(null);
    setConfirmLeave(false);
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

  /** 点空位：先占座 10 秒，再选带入。 */
  const pickSeat = async (display: number) => {
    if (!(await ensureSignedIn())) return;
    const seat = fromDisplay(display);
    setNote(null);
    setConfirmLeave(false);
    setBuyIn(defaultBuyIn(bb, balance));
    holdSeen.current = false;
    setPanel({ kind: "sit", seat });
    conn.send({ t: "hold", seat });
  };

  const closePanel = () => {
    if (panel?.kind === "sit") conn.send({ t: "release" });
    setPanel(null);
  };

  const sit = (seat: number) => {
    setNote(null);
    conn.send({ t: "sit", seat, buyIn });
  };

  const act = (action: "fold" | "check" | "call" | "raise", amount?: number) => {
    setNote(null);
    conn.send({ t: "act", action, amount });
  };

  const leave = () => {
    setConfirmLeave(false);
    conn.send({ t: "leave" });
  };

  const status = (() => {
    if (!view) return conn.connected ? null : "正在连接牌桌…";
    if (you === null) return null;
    if (legal) return `轮到你了${left !== null ? `，还剩 ${left} 秒` : ""}`;
    if (canShow) return "点自己的牌，可以亮给大家看";
    if (view.street === "idle") return "等人入座，凑够两个人就开局";
    if (!view.seats[you]?.inHand) return "下一手开始时发牌给你";
    return null;
  })();

  const current = Math.max(0, ...(view?.seats.map((x) => x?.bet ?? 0) ?? [0]));
  const raiseLabel = legal
    ? raiseTo >= legal.maxRaiseTo ? `全下 ${fmtMoney(legal.maxRaiseTo)}` : `${current === 0 ? "下注" : "加注到"} ${fmtMoney(raiseTo)}`
    : "";

  const panelView = panel ? (
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
        <button className="btn btn-text" onClick={closePanel}>取消</button>
      </div>
    </div>
  ) : null;

  const inHand = !!yourSeat?.inHand && !yourSeat.folded && view?.street !== "showdown" && view?.street !== "idle";
  const leaveView = confirmLeave ? (
    <div className="panel">
      <span className="panel-hint">{inHand ? "这手会先弃牌，打完后剩下的筹码退回余额。" : "剩下的筹码会退回余额。"}确定离桌？</span>
      <div className="panel-row">
        <button className="btn" onClick={leave}>离桌</button>
        <button className="btn btn-text" onClick={() => setConfirmLeave(false)}>再坐会儿</button>
      </div>
    </div>
  ) : null;
  const leaveButton = <button className="btn btn-text" onClick={() => setConfirmLeave(true)}>离桌</button>;

  return (
    <div className={`lobby face-${look.face}`}>
      <MarqueeSign text="yybar" />

      <FeltTable
        key={table.id}
        className={slide}
        seats={seats}
        button={buttonAt}
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
            <button
              key={ring}
              className={`icon-btn icon-btn-bell${turnElsewhere.length ? " ringing" : ""}${ring ? " rang" : ""}`}
              onClick={ringBell}
              aria-label={turnElsewhere.length ? `轮到你了：#${turnElsewhere.join("、#")}` : "回到我坐着的桌"}
              title={turnElsewhere.length ? `#${turnElsewhere[0]} 轮到你了` : "轮到你行动时会响，点一下回到你坐着的桌"}
            >
              <svg viewBox="0 0 12 12" aria-hidden className="stroke">
                <path d="M3 8.6V5.4a3 3 0 0 1 6 0v3.2l.9 1H2.1z" />
                <path d="M5 10.6a1.1 1.1 0 0 0 2 0" />
              </svg>
            </button>
            <button className="icon-btn icon-btn-new" onClick={showOpenPanel} aria-label="开一张桌" title="开一张桌">
              <svg viewBox="0 0 12 12" aria-hidden><path d="M6 2v8M2 6h8" /></svg>
            </button>
          </>
        }
        center={
          <div className="felt-center">
            <Dealer stage={stage} say={greet} />
            <div className="board-cards">
              {board.map((c, i) => (
                <PlayingCard key={`${i}-${c === "back" ? "b" : c.rank + c.suit}`} card={c} back={look.back} />
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
          leaveView ??
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
                {leaveButton}
              </>
            ) : canShow ? (
              <>
                <button className="btn btn-ghost" onClick={() => conn.send({ t: "show", which: 2 })}>两张都亮</button>
                {leaveButton}
              </>
            ) : (
              <>
                <button className="btn btn-ghost" disabled>弃牌</button>
                <button className="btn btn-ghost" disabled>过牌</button>
                <button className="btn" disabled>加注</button>
                {leaveButton}
              </>
            )
          ) : null)}
      </div>
      {(note ?? status) && <p className="note" role="status">{note ?? status}</p>}
    </div>
  );
}
