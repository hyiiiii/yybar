import { useState, type ReactNode } from "react";
import { APP_LABEL, fmtInt, fmtTokens, fmtUSD, type App, type ModelRow, type SeriesPoint } from "./api";
import { SUIT_GLYPH, SUIT_LABEL, type Suit } from "./suits";
import { DEFAULT_BACK, DEFAULT_FACE } from "../shared/cosmetics";
import { EmoteSprite } from "./Dealer";
import { pick, useLang, useT } from "./i18n";
import { findAchievement } from "../shared/achievements";
import { loginHref, notifyMeChanged } from "./useMe";

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
  position: string;
  login?: string;
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
  win?: { amount: number; hand: string | null };
  /** 赢了没摊牌时丢到桌面上亮给大家的牌（第 1 位第一张，第 2 位第二张） */
  tossed?: number;
  /** 能亮牌时点自己的牌调用，k 是第几张 */
  onShow?: (k: number) => void;
  /** 头像上方的小标签：刚才的动作、牌型 */
  note?: string;
  /** 这个人的牌背、牌面（商场里换的），同桌的人都看得到 */
  back?: string | null;
  face?: string | null;
  /** 自己用偷偷看看到的这个人的底牌（只有自己看得到） */
  peeked?: CardSpec[];
  /** 自己座位下面的小工具条（道具、表情） */
  tools?: ReactNode;
  /** 刚发的表情，key 换了重新播 */
  emote?: { id: string; key: number };
  /** 显示用的名字（机器人按语言翻译） */
  name?: string;
  /** 名字后面戴的成就徽章 */
  badge?: string | null;
  /** 「入座」「买入中…」这些字，按语言给 */
  labels?: { join: string; buying: string; you: string };
}

/**
 * 跑道形牌桌：上下两条直边、左右半圆。6 个显示位顺时针排列，0 号在左上。
 * seats 按显示位给；center 放在桌面正中（发牌员、公共牌、底池），button 是庄家所在的显示位。
 */
export function FeltTable({
  seats,
  center,
  corner,
  button = null,
  className = "",
  onEmptySeat,
}: {
  seats: Seat[];
  className?: string;
  center: ReactNode;
  /** 桌子右下角的控件（切桌、开桌） */
  corner?: ReactNode;
  button?: number | null;
  onEmptySeat?: (index: number) => void;
}) {
  // 按真实座位号排 DOM，换位置时元素不变，CSS 过渡让座位滑过去
  const order = seats.map((s, d) => ({ s, d })).sort((a, b) => a.s.id - b.s.id);
  return (
    <div className={`felt-wrap ${className}`}>
      <div className="felt">{center}</div>
      {corner && <div className="felt-corner">{corner}</div>}
      {button !== null && <span className={`dealer-chip dealer-at-${button}`} aria-label="庄家">D</span>}
      {order.map(({ s, d }) => (
        <div
          key={s.id}
          className={`seat pos-${d}${s.you ? " seat-you" : ""}${s.login ? "" : " seat-empty"}${s.folded ? " seat-folded" : ""}${s.acting ? " seat-acting" : ""}${s.held ? " seat-held" : ""}${s.win ? " seat-win" : ""}`}
        >
          {s.login ? (
            <>
              <div className="seat-disc" title={s.you ? "你" : s.login}>
                {s.timer && <TurnRing key={s.timer.key} total={s.timer.total} elapsed={s.timer.elapsed} />}
                {s.held && <TurnRing key={s.held.key} total={s.held.total} elapsed={s.held.elapsed} hold />}
                <span className="seat-pos">{s.position}</span>
              </div>
              {s.note && !s.win && <span key={s.note} className="seat-note">{s.note}</span>}
              {s.emote && (
                <span key={s.emote.key} className="seat-emote" aria-label={s.emote.id}>
                  <EmoteSprite id={s.emote.id} size={60} />
                </span>
              )}
              {s.peeked && (
                <div className="seat-cards seat-cards-peeked" title="偷偷看">
                  {s.peeked.map((c, j) => <PlayingCard key={j} card={c} face={s.face} extra="card-peeked" />)}
                </div>
              )}
              {!s.peeked && s.cards && !s.folded && (
                <div className={`seat-cards${s.onShow ? " seat-cards-showable" : ""}`}>
                  {/* key 带上牌面：背面翻成正面（摊牌）时重新挂载，播翻牌动画 */}
                  {s.cards.map((c, j) =>
                    ((s.tossed ?? 0) >> j) & 1 ? null : s.you ? (
                      <button
                        key={`${j}-${cardKey(c)}`}
                        className="card-btn"
                        disabled={!s.onShow}
                        onClick={() => s.onShow?.(j)}
                        aria-label={s.onShow ? "把这张牌亮到桌上" : undefined}
                      >
                        <PlayingCard card={c} back={s.back} face={s.face} />
                      </button>
                    ) : (
                      <PlayingCard key={`${j}-${cardKey(c)}`} card={c} back={s.back} face={s.face} />
                    ),
                  )}
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
                  <small>{s.win.hand ?? (s.you ? (s.labels?.you ?? "你") : (s.name ?? s.login))}</small>
                </div>
              ) : (
                <div className="seat-plate">
                  <span className="plate-name">
                    {s.you ? (s.labels?.you ?? "你") : (s.name ?? s.login)}
                    <Badge id={s.badge} />
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

export function Stat({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <div className="stat">
      <div className="stat-label">{label}</div>
      <div className="stat-value">{value}</div>
      {hint && <div className="stat-hint">{hint}</div>}
    </div>
  );
}

const APPS: App[] = ["codex", "claude", "grok"];

/** 近 30 天每日花费，按 App 堆叠。 */
export function DailyChart({ series, days = 30 }: { series: SeriesPoint[]; days?: number }) {
  const t = useT();
  const today = new Date();
  const dayList: string[] = [];
  for (let i = days - 1; i >= 0; i--) {
    const d = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate() - i));
    dayList.push(d.toISOString().slice(0, 10));
  }
  const byDay = new Map<string, Partial<Record<App, number>>>();
  for (const p of series) {
    const m = byDay.get(p.day) ?? {};
    m[p.app] = (m[p.app] ?? 0) + p.cost_micro;
    byDay.set(p.day, m);
  }
  const totals = dayList.map((d) => APPS.reduce((s, a) => s + (byDay.get(d)?.[a] ?? 0), 0));
  const max = Math.max(...totals, 1);
  const W = 600, H = 150, gap = 3;
  const bw = (W - gap * (days - 1)) / days;

  return (
    <figure className="chart">
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={t("近 30 天每日花费", "Daily spend, last 30 days")}>
        {dayList.map((d, i) => {
          let y = H;
          return (
            <g key={d}>
              <title>{`${d}  ${fmtUSD(totals[i])}`}</title>
              <rect x={i * (bw + gap)} y={0} width={bw} height={H} className="chart-hit" />
              {APPS.map((a) => {
                const v = byDay.get(d)?.[a] ?? 0;
                if (!v) return null;
                const h = Math.max((v / max) * (H - 4), 1.5);
                y -= h;
                return <rect key={a} x={i * (bw + gap)} y={y} width={bw} height={h} rx={1.5} className={`fill-${a}`} />;
              })}
            </g>
          );
        })}
      </svg>
      <figcaption className="legend">
        {APPS.map((a) => (
          <span key={a}>
            <i className={`dot fill-${a}`} /> {APP_LABEL[a]}
          </span>
        ))}
        <span className="legend-max">{t("最高单日", "Peak day")} {fmtUSD(max === 1 ? 0 : max)}</span>
      </figcaption>
    </figure>
  );
}

export function ModelTable({ models }: { models: ModelRow[] }) {
  const t = useT();
  if (!models.length) return <p className="empty">{t("还没有数据。", "No data yet.")}</p>;
  return (
    <div className="table-scroll">
      <table className="table">
        <thead>
          <tr>
            <th>{t("模型", "Model")}</th>
            <th className="num">Token</th>
            <th className="num">{t("花费", "Cost")}</th>
          </tr>
        </thead>
        <tbody>
          {models.map((m) => (
            <tr key={`${m.app}/${m.model}`}>
              <td>
                <i className={`dot fill-${m.app}`} /> {m.model}
              </td>
              <td className="num">{fmtTokens(m.tokens)}</td>
              <td className="num">{fmtUSD(m.cost_micro)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
