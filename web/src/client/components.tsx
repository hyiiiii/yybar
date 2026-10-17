import { APP_LABEL, fmtTokens, fmtUSD, type App, type ModelRow, type SeriesPoint } from "./api";

export function Avatar({ url, login, size = 32 }: { url: string | null; login: string; size?: number }) {
  return url ? (
    <img className="avatar" src={url} alt="" width={size} height={size} />
  ) : (
    <span className="avatar avatar-fallback" style={{ width: size, height: size }}>
      {login.slice(0, 1).toUpperCase()}
    </span>
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
  const W = 600, H = 160, gap = 3;
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
  );
}
