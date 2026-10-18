import type { ReactNode } from "react";
import { APP_LABEL, fmtInt, fmtTokens, fmtUSD, type App, type ModelRow, type SeriesPoint } from "./api";
import { SUIT_GLYPH, SUIT_LABEL, type Suit } from "./suits";
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

export function LoginButton({ next, small, label = "用 GitHub 登录" }: { next?: string; small?: boolean; label?: string }) {
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

export function PlayingCard({ card, size = "md" }: { card: CardSpec; size?: "sm" | "md" | "lg" }) {
  if (card === "back") return <span className={`card card-${size} card-back`} aria-label="背面" />;
  return (
    <span className={`card card-${size} card-${card.suit}`} aria-label={`${SUIT_LABEL[card.suit]} ${card.rank}`}>
      <span className="card-corner">
        <b>{card.rank}</b>
        <SuitIcon suit={card.suit} size={size === "sm" ? 9 : 12} />
      </span>
      <span className="card-pip">
        <SuitIcon suit={card.suit} size={size === "sm" ? 18 : size === "md" ? 26 : 34} />
      </span>
    </span>
  );
}

export interface Seat {
  login?: string;
  stack?: number;
  bet?: number;
  state?: string;
  you?: boolean;
  cards?: CardSpec[];
  dealer?: boolean;
}

/** 座位绕椭圆均匀分布，0 号在正下方，顺时针。 */
function seatPosition(i: number, n: number) {
  const angle = Math.PI / 2 + (i * 2 * Math.PI) / n;
  return { left: `${50 + 51 * Math.cos(angle)}%`, top: `${50 + 54 * Math.sin(angle)}%` };
}

/** 俯视的椭圆牌桌。center 放在桌面正中（发牌员、公共牌）。 */
export function FeltTable({
  seats,
  center,
  onEmptySeat,
}: {
  seats: Seat[];
  center: ReactNode;
  onEmptySeat?: (index: number) => void;
}) {
  return (
    <div className="felt-wrap">
      <div className="rail">
        <div className="felt">{center}</div>
      </div>
      {seats.map((s, i) => (
        <div
          key={i}
          className={`seat${i === 0 ? " seat-bottom" : ""}${s.you ? " seat-you" : ""}${s.login ? "" : " seat-empty"}`}
          style={seatPosition(i, seats.length)}
        >
          {s.login ? (
            <>
              {s.cards && (
                <div className="seat-cards">
                  {s.cards.map((c, j) => (
                    <PlayingCard key={j} card={c} size={s.you ? "md" : "sm"} />
                  ))}
                </div>
              )}
              <div className="seat-plate">
                <Avatar url={null} login={s.login} size={28} />
                <div>
                  <div className="seat-name">{s.you ? "你" : s.login}</div>
                  <div className="seat-stack">{fmtInt(s.stack ?? 0)}</div>
                </div>
                {s.dealer && <span className="dealer-chip">D</span>}
              </div>
              {(s.state || !!s.bet) && (
                <div className="seat-state">
                  {s.state}
                  {!!s.bet && <span className="seat-bet">{fmtInt(s.bet)}</span>}
                </div>
              )}
            </>
          ) : (
            <button className="seat-open" onClick={() => onEmptySeat?.(i)}>
              入座
            </button>
          )}
        </div>
      ))}
    </div>
  );
}

/** 桌子上方的 yybar 招牌，四周一圈跑马灯。 */
export function MarqueeSign({ text }: { text: string }) {
  const W = 300, H = 96, step = 18;
  const bulbs: { x: number; y: number }[] = [];
  for (let x = 10; x <= W - 10; x += step) bulbs.push({ x, y: 9 });
  for (let y = 9 + step; y <= H - 9; y += step) bulbs.push({ x: W - 10, y });
  for (let x = W - 10 - step; x >= 10; x -= step) bulbs.push({ x, y: H - 9 });
  for (let y = H - 9 - step; y > 9; y -= step) bulbs.push({ x: 10, y });
  return (
    <div className="sign" aria-label={text}>
      <svg viewBox={`0 0 ${W} ${H}`} className="sign-svg" aria-hidden>
        <rect x={1} y={1} width={W - 2} height={H - 2} rx={14} className="sign-board" />
        {bulbs.map((b, i) => (
          <circle key={i} cx={b.x} cy={b.y} r={3.2} className={`bulb bulb-${i % 3}`} />
        ))}
      </svg>
      <span className="sign-text">{text}</span>
    </div>
  );
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
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label="近 30 天每日花费">
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
        <span className="legend-max">最高单日 {fmtUSD(max === 1 ? 0 : max)}</span>
      </figcaption>
    </figure>
  );
}

export function ModelTable({ models }: { models: ModelRow[] }) {
  if (!models.length) return <p className="empty">还没有数据。</p>;
  return (
    <div className="table-scroll">
      <table className="table">
        <thead>
          <tr>
            <th>模型</th>
            <th className="num">Token</th>
            <th className="num">花费</th>
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
