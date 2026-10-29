import { useEffect, useState, type ReactNode } from "react";
import { APP_LABEL, fmtInt, type App, type PlanSummary } from "./api";
import { SUIT_GLYPH, SUIT_LABEL, type Suit } from "./suits";
import { DEFAULT_BACK, DEFAULT_FACE } from "../shared/cosmetics";
import { EmoteSprite } from "./Dealer";
import { pick, useLang, useT } from "./i18n";
import { findAchievement } from "../shared/achievements";
import { loginHref, notifyMeChanged } from "./useMe";
import { DiceIcon, RobotIcon } from "./icons";
import { BOT_FACES } from "./bots";
import { ServiceLogo } from "./UsageCharts";

const DEMO = !!import.meta.env.VITE_DEMO;

export function Avatar({ url, login, size = 32 }: { url: string | null; login: string; size?: number }) {
  return url ? (
    <img className="avatar" src={url} alt="" width={size} height={size} />
  ) : (
    <span className="avatar avatar-fallback" style={{ width: size, height: size, fontSize: size * 0.42 }}>
      {login.slice(0, 1).toUpperCase()}
    </span>
  );
}

export function LoginButton({ next, small, label }: { next?: string; small?: boolean; label?: string }) {
  const t = useT();
  label ??= t("用 GitHub 登录", "Sign in with GitHub");
  const cls = small ? "btn btn-small" : "btn";
  if (DEMO) {
    return (
      <button
        className={cls}
        onClick={async () => {
          (await import("./demo")).demoLogin();
          notifyMeChanged();
        }}
      >
        {label}
      </button>
    );
  }
  return <a className={cls} href={loginHref(next)}>{label}</a>;
}

export function SuitIcon({ suit, size = 16 }: { suit: Suit; size?: number }) {
  const g = SUIT_GLYPH[suit];
  return (
    <svg className={`suit suit-${suit}`} viewBox={g.viewBox} width={size} height={size} aria-label={SUIT_LABEL[suit]} role="img">
      {g.paths.map((p, i) => (
        <path key={i} d={p.d} fillRule={p.rule} fill="currentColor" />
      ))}
    </svg>
  );
}

export type CardSpec = { rank: string; suit: Suit } | "back";

/** 整面上色的牌（四色牌），左上角大号点数，正中一个 AI 标。 */
/** 所有位置的牌都用同一个尺寸。 */
/** back、face 是这张牌主人在商场换上的牌背、牌面；extra 加额外的类（例如偷看到的牌） */
export function PlayingCard({ card, back, face, extra = "" }: { card: CardSpec; back?: string | null; face?: string | null; extra?: string }) {
  if (card === "back") {
    return (
      <span className={`card card-back back-${back || DEFAULT_BACK} ${extra}`} aria-label="背面" />
    );
  }
  return (
    <span className={`card card-${card.suit} face-${face || DEFAULT_FACE} ${extra}`} aria-label={`${SUIT_LABEL[card.suit]} ${card.rank}`}>
      <b className="card-rank">{card.rank}</b>
      <span className="card-icon">
        <SuitIcon suit={card.suit} size={30} />
      </span>
    </span>
  );
}

export interface Seat {
  /** 真实座位号：入座后桌子会转，按它保持同一个元素，座位才能滑到新位置 */
  id: number;
  /** 有人的座位：这手的位置（BTN、SB…）或「等开局」，写在名牌上；空位：几号 */
  position: string;
  login?: string;
  /** GitHub 头像，画在座位圆盘里 */
  avatarUrl?: string | null;
  bot?: boolean;
  /** 筹码，1 个筹码按 $1 显示 */
  stack?: number;
  bet?: number;
  you?: boolean;
  folded?: boolean;
  acting?: boolean;
  cards?: CardSpec[];
  /** 刚弃掉的牌，播一下收走的动画 */
  mucked?: CardSpec[];
  /** 轮到这个座位时的倒计时：key 换了就重新开始；total、elapsed 单位毫秒 */
  timer?: { key: string; total: number; elapsed: number };
  /** 有人点了这个空位（或在这桌输光了）正在买入：灰色头像 + 橙色倒计时，走过的部分变白 */
  held?: { key: string; total: number; elapsed: number };
  /** 这手赢了：赢了多少、什么牌（别人都弃了就没有牌型） */
  win?: { amount: number };
  /** 赢了没摊牌时丢到桌面上亮给大家的牌（第 1 位第一张，第 2 位第二张） */
  tossed?: number;
  /** 能亮牌时点自己的牌调用，k 是第几张 */
  onShow?: (k: number) => void;
  /** 头像上方的小标签：刚才的动作、牌型 */
  note?: string;
  /** 弃了牌的人一手结束后亮出来的牌（位掩码）：这几张不变暗，原地翻过来 */
  upMask?: number;
  /** 标签的 key：每次新动作都换一个，哪怕字一样（连着两条街都过牌）也重新弹一下 */
  noteKey?: string;
  /** note 是赢家的牌型：标成金色 */
  noteWin?: boolean;
  /** 这个人的牌背、牌面（商场里换的），同桌的人都看得到 */
  back?: string | null;
  face?: string | null;
  /** 自己用偷偷看看到的这个人的底牌（只有自己看得到） */
  peeked?: CardSpec[];
  /** 自己座位下面的小工具条（道具、表情） */
  tools?: ReactNode;
  /** 刚发的表情或掷的骰子（roll 是点数），key 换了重新播 */
  emote?: { id: string; key: number; roll?: number };
  /** 显示用的名字（机器人按语言翻译） */
  name?: string;
  /** 名字后面戴的成就徽章 */
  badges?: string[];
  /** 点头像看这个人的统计 */
  onInfo?: () => void;
  /** 头像旁边弹出的统计卡 */
  info?: ReactNode;
  /** 「入座」「买入中…」这些字，按语言给 */
  labels?: { join: string; buying: string; you: string };
}

/** 座位圆盘里的头像：GitHub 头像，没有就用名字首字母；机器人桌的机器人用它们的 Q 版头像，别的机器人画个机器人。 */
function SeatFace({ login, avatarUrl, bot }: { login: string; avatarUrl?: string | null; bot?: boolean }) {
  if (bot && BOT_FACES[login]) return <img className="seat-face" src={BOT_FACES[login]} alt="" draggable={false} />;
  if (bot) {
    return (
      <span className="seat-face seat-face-bot" aria-hidden>
        <RobotIcon />
      </span>
    );
  }
  return avatarUrl ? (
    <img className="seat-face" src={avatarUrl} alt="" draggable={false} />
  ) : (
    <span className="seat-face seat-face-letter" aria-hidden>{login.slice(0, 1).toUpperCase()}</span>
  );
}

/**
 * 跑道形牌桌：上下两条直边、左右半圆。6 个显示位顺时针排列，0 号在左上。
 * seats 按显示位给；center 放在桌面正中（发牌员、公共牌、底池），button 是庄家所在的显示位。
 */
export function FeltTable({
  seats,
  center,
  button = null,
  className = "",
  onEmptySeat,
  overlay,
}: {
  seats: Seat[];
  className?: string;
  center: ReactNode;
  /** 盖在整张桌子上的一层（扔番茄的动画） */
  overlay?: ReactNode;
  button?: number | null;
  onEmptySeat?: (index: number) => void;
}) {
  // 按真实座位号排 DOM，换位置时元素不变，CSS 过渡让座位滑过去
  const order = seats.map((s, d) => ({ s, d })).sort((a, b) => a.s.id - b.s.id);
  return (
    <div className={`felt-wrap ${className}`}>
      <div className="felt">{center}</div>
      {button !== null && <span className={`dealer-chip dealer-at-${button}`} aria-label="庄家">D</span>}
      {order.map(({ s, d }) => (
        <div
          key={s.id}
          className={`seat pos-${d}${s.you ? " seat-you" : ""}${s.login ? "" : " seat-empty"}${s.folded ? " seat-folded" : ""}${s.acting ? " seat-acting" : ""}${s.held ? " seat-held" : ""}${s.win ? " seat-win" : ""}${s.info ? " seat-info-open" : ""}`}
        >
          {s.login ? (
            <>
              {s.info && <div className="seat-info">{s.info}</div>}
              <div className={`seat-disc${s.onInfo ? " seat-disc-click" : ""}`} title={s.you ? "你" : s.login} onClick={s.onInfo}>
                <SeatFace login={s.login} avatarUrl={s.avatarUrl} bot={s.bot} />
                {s.timer && <TurnRing key={s.timer.key} total={s.timer.total} elapsed={s.timer.elapsed} />}
                {s.held && <TurnRing key={s.held.key} total={s.held.total} elapsed={s.held.elapsed} hold />}
              </div>
              {s.note && <span key={s.noteKey ?? s.note} className={`seat-note${s.noteWin ? " seat-note-win" : ""}`}>{s.note}</span>}
              {s.emote && s.emote.roll !== undefined ? (
                <span key={s.emote.key} className="seat-emote seat-roll" aria-label={String(s.emote.roll)}>
                  <RollNumber n={s.emote.roll} />
                </span>
              ) : (
                s.emote && (
                  <span key={s.emote.key} className="seat-emote" aria-label={s.emote.id}>
                    <EmoteSprite id={s.emote.id} size={60} />
                  </span>
                )
              )}
              {s.peeked && (
                <div className="seat-cards seat-cards-peeked seat-cards-up" title="偷偷看">
                  {s.peeked.map((c, j) => <PlayingCard key={j} card={c} face={s.face} extra="card-peeked" />)}
                </div>
              )}
              {/* 弃了牌：自己的牌留在手里变暗；别人的只有一手结束后亮了才摆出来 */}
              {!s.peeked && s.cards && (!s.folded || s.you || s.cards.some((c) => c !== "back")) && (
                <div
                  className={`seat-cards${s.onShow ? " seat-cards-showable" : ""}${s.folded ? " seat-cards-folded" : ""}${s.cards.some((c) => c !== "back") ? " seat-cards-up" : ""}`}
                >
                  {/* key 带上牌面和亮没亮：背面翻成正面（摊牌）、弃了的牌亮出来时重新挂载，播翻牌动画 */}
                  {s.cards.map((c, j) => {
                    const up = ((s.upMask ?? 0) >> j) & 1;
                    const key = `${j}-${cardKey(c)}-${up}`;
                    const extra = up ? "card-up" : "";
                    return ((s.tossed ?? 0) >> j) & 1 ? null : s.you ? (
                      <button
                        key={key}
                        className="card-btn"
                        disabled={!s.onShow || !!up}
                        onClick={() => s.onShow?.(j)}
                        aria-label={s.onShow ? "把这张牌亮给大家" : undefined}
                      >
                        <PlayingCard card={c} back={s.back} face={s.face} extra={extra} />
                      </button>
                    ) : (
                      <PlayingCard key={key} card={c} back={s.back} face={s.face} extra={extra} />
                    );
                  })}
                </div>
              )}
              {!!s.tossed && s.cards && (
                <div className="seat-tossed">
                  {/* 两张牌各占固定的位置：先丢一张、再丢一张时，桌上那张不会挪 */}
                  {s.cards.map((c, j) => (((s.tossed ?? 0) >> j) & 1 ? <PlayingCard key={j} card={c} face={s.face} /> : <span key={`slot-${j}`} className="card card-slot" />))}
                </div>
              )}
              {s.mucked && (
                <div className="seat-cards seat-cards-muck" aria-hidden>
                  {s.mucked.map((c, j) => (
                    <PlayingCard key={j} card={c} back={s.back} />
                  ))}
                </div>
              )}
              {s.win ? (
                <div className="seat-plate seat-plate-win" key="win">
                  <b className="win-mark">WIN</b>
                  <span className="win-amount">+{fmtMoney(s.win.amount)}</span>
                  <small>{s.you ? (s.labels?.you ?? "你") : (s.name ?? s.login)}</small>
                </div>
              ) : (
                <div className="seat-plate">
                  <span className="plate-name">
                    {s.position && !s.held && <b className="plate-pos">{s.position}</b>}
                    {s.you ? (s.labels?.you ?? "你") : (s.name ?? s.login)}
                    <Badges ids={s.badges} />
                  </span>
                  <b className="plate-stack">{s.held ? (s.labels?.buying ?? "买入中…") : fmtMoney(s.stack ?? 0)}</b>
                </div>
              )}
              {!!s.bet && <div key={s.bet} className="seat-bet">{fmtMoney(s.bet)}</div>}
              {s.tools && <div className="seat-tools">{s.tools}</div>}
            </>
          ) : (
            <button className="seat-disc seat-open" onClick={() => onEmptySeat?.(d)}>
              <span className="seat-pos">{s.position}</span>
              <span className="seat-join">{s.labels?.join ?? "入座"}</span>
            </button>
          )}
        </div>
      ))}
      {overlay}
    </div>
  );
}

/** 桌子上方的 yybar 招牌，四周一圈跑马灯。 */
export function MarqueeSign({ text }: { text: string }) {
  const W = 300, H = 108, step = 18;
  const bulbs: { x: number; y: number }[] = [];
  for (let x = 10; x <= W - 10; x += step) bulbs.push({ x, y: 9 });
  for (let y = 9 + step; y <= H - 9; y += step) bulbs.push({ x: W - 10, y });
  for (let x = W - 10 - step; x >= 10; x -= step) bulbs.push({ x, y: H - 9 });
  for (let y = H - 9 - step; y > 9; y -= step) bulbs.push({ x: 10, y });
  return (
    <div className="sign" aria-label={text}>
      <svg viewBox={`0 0 ${W} ${H}`} className="sign-svg" aria-hidden>
        <rect x={1} y={1} width={W - 2} height={H - 2} rx={14} className="sign-board" />
      </svg>
      <span className="sign-text">{text}</span>
      {/* 灯泡单独一层压在字上面，字的光晕不会把灯挡住 */}
      <svg viewBox={`0 0 ${W} ${H}`} className="sign-svg sign-bulbs" aria-hidden>
        {bulbs.map((b, i) => (
          <circle key={i} cx={b.x} cy={b.y} r={3.2} className={`bulb bulb-${i % 3}`} />
        ))}
      </svg>
    </div>
  );
}

/** 绕着头像的一圈绿条，随行动时间慢慢缩短。开始时刻在挂载时定下来，之后重绘不会让它跳。 */
function TurnRing({ total, elapsed, hold }: { total: number; elapsed: number; hold?: boolean }) {
  const [delay] = useState(() => `${-Math.max(0, elapsed)}ms`);
  return (
    <svg className={`turn-ring${hold ? " turn-ring-hold" : ""}`} viewBox="0 0 100 100" aria-hidden>
      {/* 底下一圈白色轨道：走过的部分露出白色 */}
      <circle className="turn-ring-track" cx="50" cy="50" r="47" />
      <circle className="turn-ring-bar" cx="50" cy="50" r="47" pathLength={100} style={{ animationDuration: `${total}ms`, animationDelay: delay }} />
    </svg>
  );
}

const cardKey = (c: CardSpec) => (c === "back" ? "b" : c.rank + c.suit);

/** 名字后面戴的几枚徽章 */
export function Badges({ ids }: { ids?: string[] | null }) {
  return <>{(ids ?? []).map((id) => <Badge key={id} id={id} />)}</>;
}

/** 订阅档次，和 App 设置里的套餐标签一样着色：免费灰、标准档蓝、高档紫、团队 / 企业青。
 *  同名档次在不同服务里不一样：ChatGPT Pro 是最高档，Claude Pro 是标准档、Max 才是高档。 */
export function planTier(app: App, plan: string): "free" | "standard" | "premium" | "team" {
  const p = plan.toLowerCase();
  if (p.includes("free") || p === "guest") return "free";
  if (["team", "business", "enterprise", "edu"].some((k) => p.includes(k))) return "team";
  if (app === "codex") return p.includes("pro") ? "premium" : "standard";
  if (app === "claude") return p.includes("max") ? "premium" : "standard";
  return p.includes("heavy") || p.includes("ultra") ? "premium" : "standard";
}

/** ChatGPT 的套餐代号（Codex 登录里的 chatgpt_plan_type）：Pro 分 Lite / 标准 / Max 三档 */
const CODEX_PLAN_NAMES: Record<string, string> = { prolite: "Pro Lite", pro: "Pro 20x", promax: "Pro Max", go: "Go", self_serve_business_prolite: "Business Pro Lite" };

/** 套餐名：首字母大写；ChatGPT 的代号换成名字（prolite → Pro Lite）；Claude Max 带档位（max_20x → Max 20x）；
 *  Google 的去掉前面的「Google」（前面已经有 Gemini 的标） */
export function planLabel(app: App, plan: string): string {
  const named = app === "codex" ? CODEX_PLAN_NAMES[plan.toLowerCase()] : undefined;
  if (named) return named;
  let p = plan.replace(/[_]+/g, " ").trim();
  if (app === "gemini" || app === "agy") p = p.replace(/^google\s+/i, "");
  return p.charAt(0).toUpperCase() + p.slice(1);
}

/** 同一服务里的先后：高档在前（同是高档再看档位：Pro Max > Pro > Pro Lite、Max 20x > Max 5x），免费在最后 */
function planRank(app: App, plan: string): number {
  const p = plan.toLowerCase();
  const base = { premium: 30, team: 20, standard: 10, free: 0 }[planTier(app, plan)];
  const sub = /max$|20x|heavy|ultra/.test(p) ? 2 : /lite|5x/.test(p) ? 0 : 1;
  return base + sub;
}

const APP_ORDER: App[] = ["codex", "claude", "grok", "grokBot", "gemini", "agy"];

/** 个人主页 @ 后面的订阅：服务的标 + 套餐，同一套餐几个账号写「× n」。按服务排，同一服务里高档在前，免费的灰色排最后。 */
export function PlanChips({ plans }: { plans?: PlanSummary[] | null }) {
  const t = useT();
  const list = [...(plans ?? [])].sort(
    (a, b) => APP_ORDER.indexOf(a.app) - APP_ORDER.indexOf(b.app) || planRank(b.app, b.plan) - planRank(a.app, a.plan) || b.count - a.count,
  );
  if (list.length === 0) return null;
  return (
    <span className="plan-chips">
      {list.map((p) => {
        const label = planLabel(p.app, p.plan);
        return (
          <span
            key={`${p.app}|${p.plan}`}
            className={`plan-chip tier-${planTier(p.app, p.plan)}`}
            title={t(`${APP_LABEL[p.app]} ${label} · ${p.count} 个账号`, `${APP_LABEL[p.app]} ${label} · ${p.count} account${p.count > 1 ? "s" : ""}`)}
          >
            <ServiceLogo app={p.app} size={12} />
            {label}
            {p.count > 1 && <span className="plan-count">×{p.count}</span>}
          </span>
        );
      })}
    </span>
  );
}

/** 德州统计的一行小字：手数、胜率、VPIP、PFR、3B */
export function StatLine({ stats }: { stats: { hands: number; winRate: number | null; vpip: number | null; pfr: number | null; threeBet: number | null } }) {
  const pct = (x: number | null) => (x === null ? "—" : `${Math.round(x * 100)}%`);
  const items: [string, string, string][] = [
    ["Hands", fmtInt(stats.hands), "总手数 / Hands played"],
    ["Win", pct(stats.winRate), "胜率 / Hands won"],
    ["VPIP", pct(stats.vpip), "入局率：翻牌前主动跟注或加注 / Voluntarily put in pot"],
    ["PFR", pct(stats.pfr), "翻牌前加注率 / Preflop raise"],
    ["3B", pct(stats.threeBet), "3-bet 率：面对一次加注时再加注 / 3-bet"],
  ];
  return (
    <span className="stat-line">
      {items.map(([k, v, title]) => (
        <span key={k} title={title}>
          <small>{k}</small>
          <b>{v}</b>
        </span>
      ))}
    </span>
  );
}

/** 成就徽章：小小一枚，戴在名字后面；悬停显示是哪个成就 */
export function Badge({ id, big }: { id?: string | null; big?: boolean }) {
  const lang = useLang();
  const a = id ? findAchievement(id) : undefined;
  if (!a) return null;
  return (
    <span className={`badge badge-${a.badge.tier}${big ? " badge-big" : ""}`} title={pick(a.name, lang)} aria-label={pick(a.name, lang)}>
      {a.badge.label}
    </span>
  );
}

/** 筹码按美元显示：$1,250 */
export function fmtMoney(n: number): string {
  return `$${Math.round(n).toLocaleString("en-US")}`;
}

export function Stat({ label, value, hint, help }: { label: string; value: string; hint?: string; help?: ReactNode }) {
  return (
    <div className="stat">
      <div className="stat-label">
        {label}
        {help}
      </div>
      <div className="stat-value">{value}</div>
      {hint && <div className="stat-hint">{hint}</div>}
    </div>
  );
}


/** 掷骰子的点数：先乱跳一小会儿，再停在掷出的数上 */
function RollNumber({ n }: { n: number }) {
  const still = typeof matchMedia !== "undefined" && matchMedia("(prefers-reduced-motion: reduce)").matches;
  const [shown, setShown] = useState(() => (still ? n : Math.floor(Math.random() * 101)));
  const [landed, setLanded] = useState(still);
  useEffect(() => {
    if (still) return;
    let k = 0;
    const id = setInterval(() => {
      if (++k < 8) return setShown(Math.floor(Math.random() * 101));
      clearInterval(id);
      setShown(n);
      setLanded(true);
    }, 55);
    return () => clearInterval(id);
  }, [n]);
  return (
    <>
      <DiceIcon rolling={!still} />
      <b className={landed ? "landed" : undefined}>{shown}</b>
    </>
  );
}
