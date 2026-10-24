import { useEffect, useState } from "react";
import { api, fmtInt, fmtTokens } from "../api";
import { Badge, LoginButton, fmtMoney } from "../components";
import { pick, tr, useLang, useT } from "../i18n";
import { sfx } from "../sound";
import { notifyMeChanged, useMe } from "../useMe";
import { MAX_BADGES, type Achievement } from "../../shared/achievements";

type Row = Achievement & { unlockedAt: string | null; claimedAt: string | null };
type Progress = { streak: number; tokens: number; spend: number };
type Response = { achievements: Row[]; progress: Progress | null; badges: string[] };

/** 有进度条的成就现在走到哪了 */
function progressOf(a: Row, p: Progress | null): number | null {
  if (!a.target || !p) return null;
  if (a.id.startsWith("streak_")) return p.streak;
  if (a.id.startsWith("tokens_")) return p.tokens;
  if (a.id === "spend_1k") return p.spend;
  return null;
}

/** 成就：达成后在这里自己领筹码（顶栏奖杯旁边会提醒），领了的徽章可以挑几个戴在名字后面。 */
export function AchievementsPage() {
  const { me } = useMe();
  const lang = useLang();
  const t = useT();
  const [data, setData] = useState<Response | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  /** 刚领的成就：奖励数字往上飘一下 */
  const [claimed, setClaimed] = useState<Set<string>>(new Set());
  const signedIn = !!me?.user;

  const load = () => api<Response>("/api/achievements").then(setData, (e: Error) => setNote(tr(e.message, lang)));
  useEffect(() => {
    load();
  }, [signedIn]);
  // 打开页面时可能刚解锁了新的，顶栏奖杯的提醒跟着刷新
  useEffect(() => {
    if (data?.progress) notifyMeChanged();
  }, [!!data?.progress]);

  const run = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    setNote(null);
    try {
      await fn();
      notifyMeChanged();
      await load();
    } catch (e) {
      setNote(tr((e as Error).message, lang));
    } finally {
      setBusy(false);
    }
  };
  const wear = (id: string, on: boolean) => run(() => api("/api/achievements/wear", { method: "POST", json: { id, on } }));
  /** 领一个（id）或者全部领了 */
  const claim = (ids: string[], one?: string) =>
    run(async () => {
      const r = await api<{ amount: number }>("/api/achievements/claim", { method: "POST", json: one ? { id: one } : {} });
      if (r.amount) {
        sfx.chips(3);
        setClaimed(new Set(ids));
      }
    });

  const rows = data?.achievements ?? [];
  const unlocked = rows.filter((a) => a.unlockedAt).length;
  const ready = rows.filter((a) => a.unlockedAt && !a.claimedAt);
  const fmtProgress = (a: Row, n: number) =>
    a.id.startsWith("tokens_") ? `${fmtTokens(n)} / ${fmtTokens(a.target!)}` : a.id === "spend_1k" ? `$${fmtInt(n)} / $${fmtInt(a.target!)}` : t(`${n} / ${a.target} 天`, `${n} / ${a.target} days`);

  return (
    <section className="section">
      {!signedIn && me && (
        <div className="card-box notice shop-login">
          <span>{t("登录后开始解锁成就。", "Sign in to start unlocking achievements.")}</span>
          <LoginButton small next="/achievements" />
        </div>
      )}
      {signedIn && data && (
        <div className="ach-summary">
          <p className="muted">
            {t(
              `已解锁 ${unlocked} / ${rows.length}。达成后在这里领奖励，领了的徽章可以「戴上」挂在名字后面，最多同时戴 ${MAX_BADGES} 个（正在戴 ${data.badges.length} 个）。`,
              `${unlocked} of ${rows.length} unlocked. Claim rewards here once you earn them; claimed badges can be worn after your name — up to ${MAX_BADGES} at once (wearing ${data.badges.length}).`,
            )}
          </p>
          {ready.length > 1 && (
            <button className="btn btn-small btn-claim" disabled={busy} onClick={() => claim(ready.map((a) => a.id))}>
              {t(`全部领取 +${fmtMoney(ready.reduce((s, a) => s + a.reward, 0))}`, `Claim all +${fmtMoney(ready.reduce((s, a) => s + a.reward, 0))}`)}
            </button>
          )}
        </div>
      )}
      {note && <p className="note shop-note" role="status">{note}</p>}
      <div className="ach-grid">
        {rows.map((a, idx) => {
          const done = !!a.unlockedAt;
          const owned = done && !!a.claimedAt;
          const waiting = done && !a.claimedAt;
          const wearing = !!data?.badges.includes(a.id);
          const full = (data?.badges.length ?? 0) >= MAX_BADGES;
          const now = progressOf(a, data?.progress ?? null);
          return (
            <article
              key={a.id}
              className={`ach${done ? " done" : ""}${waiting ? " ready" : ""}${wearing ? " wearing" : ""}`}
              style={{ "--i": idx } as React.CSSProperties}
            >
              <div className="ach-badge">
                {/* 戴上 / 摘下时换 key，徽章弹一下 */}
                <span key={wearing ? "on" : "off"} className={wearing ? "badge-wear" : undefined}>
                  <Badge id={a.id} big />
                </span>
              </div>
              <div className="ach-info">
                <h3>{pick(a.name, lang)}</h3>
                <p>{pick(a.how, lang)}</p>
                {!done && now !== null && (
                  <div className="ach-progress" title={fmtProgress(a, now)}>
                    <i style={{ width: `${Math.min(100, (now / a.target!) * 100)}%` }} />
                    <span>{fmtProgress(a, Math.min(now, a.target!))}</span>
                  </div>
                )}
              </div>
              <div className="ach-foot">
                <span className="ach-reward">
                  +{fmtMoney(a.reward)}
                  {claimed.has(a.id) && owned && <i key={a.claimedAt} className="ach-reward-pop">+{fmtMoney(a.reward)}</i>}
                </span>
                {waiting ? (
                  <button className="btn btn-small btn-claim" disabled={busy} onClick={() => claim([a.id], a.id)}>
                    {t("领取", "Claim")}
                  </button>
                ) : owned ? (
                  wearing ? (
                    <button className="btn btn-small btn-ghost" disabled={busy} onClick={() => wear(a.id, false)}>{t("摘下", "Take off")}</button>
                  ) : (
                    <button
                      className="btn btn-small"
                      disabled={busy || full}
                      title={full ? t(`最多戴 ${MAX_BADGES} 个，先摘下一个`, `Up to ${MAX_BADGES} — take one off first`) : undefined}
                      onClick={() => wear(a.id, true)}
                    >
                      {t("戴上", "Wear")}
                    </button>
                  )
                ) : (
                  <span className="muted small">{t("未解锁", "Locked")}</span>
                )}
              </div>
              {done && <span className="ach-date">{a.unlockedAt!.slice(0, 10)}</span>}
            </article>
          );
        })}
      </div>
    </section>
  );
}
