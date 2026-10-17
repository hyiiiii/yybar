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

/** 俯视的椭圆牌桌，6 个座位顺时针排列，0 号在正下方。 */
export function FeltTable({
  seats,
  board,
  pot,
  onEmptySeat,
  label,
}: {
  seats: Seat[];
  board: CardSpec[];
  pot: number;
  onEmptySeat?: () => void;
  label?: string;
}) {
  return (
    <div className="felt-wrap">
      <div className="felt">
        {label && <div className="felt-label">{label}</div>}
        <div className="felt-center">
          <div className="pot">
            底池 <b>{fmtInt(pot)}</b>
          </div>
          <div className="board-cards">
            {board.map((c, i) => (
              <PlayingCard key={i} card={c} />
            ))}
          </div>
        </div>
      </div>
      {seats.map((s, i) => (
        <div key={i} className={`seat seat-${i}${s.you ? " seat-you" : ""}${s.login ? "" : " seat-empty"}`}>
          {s.login ? (
            <>
              {s.cards && (
                <div className="seat-cards">
                  {s.cards.map((c, j) => (
                    <PlayingCard key={j} card={c} size="sm" />
                  ))}
                </div>
              )}
              <div className="seat-plate">
                <Avatar url={null} login={s.login} size={30} />
                <div>
                  <div className="seat-name">{s.you ? "你" : s.login}</div>
                  <div className="seat-stack">{fmtInt(s.stack ?? 0)}</div>
                </div>
                {s.dealer && <span className="dealer">D</span>}
              </div>
              {s.state && <div className="seat-state">{s.state}</div>}
              {!!s.bet && <div className="seat-bet">{fmtInt(s.bet)}</div>}
            </>
          ) : (
            <button className="seat-open" onClick={onEmptySeat}>
              空位<br />
              <span>入座</span>
            </button>
          )}
        </div>
      ))}
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
