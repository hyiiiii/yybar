import { useEffect, useState } from "react";
import { api, fmtInt, fmtTokens } from "../api";
import { Badge, LoginButton, fmtMoney } from "../components";
import { pick, tr, useLang, useT } from "../i18n";
import { notifyMeChanged, useMe } from "../useMe";
import type { Achievement } from "../../shared/achievements";

type Row = Achievement & { unlockedAt: string | null };
type Progress = { streak: number; tokens: number; spend: number };
type Response = { achievements: Row[]; progress: Progress | null; badge: string | null };

/** 有进度条的成就现在走到哪了 */
function progressOf(a: Row, p: Progress | null): number | null {
  if (!a.target || !p) return null;
  if (a.id.startsWith("streak_")) return p.streak;
  if (a.id.startsWith("tokens_")) return p.tokens;
  if (a.id === "spend_1k") return p.spend;
  return null;
}

/** 成就：达成送筹码，解锁的徽章可以挑一个戴在名字后面。 */
export function AchievementsPage() {
  const { me } = useMe();
  const lang = useLang();
  const t = useT();
  const [data, setData] = useState<Response | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const signedIn = !!me?.user;

  const load = () => api<Response>("/api/achievements").then(setData, (e: Error) => setNote(tr(e.message, lang)));
  useEffect(() => {
    load();
  }, [signedIn]);
  // 打开页面时可能刚解锁了新的，顶栏余额跟着刷新
  useEffect(() => {
    if (data?.progress) notifyMeChanged();
  }, [!!data?.progress]);

  const wear = async (id: string | null) => {
    setBusy(true);
    setNote(null);
    try {
      await api("/api/achievements/wear", { method: "POST", json: { id } });
      notifyMeChanged();
      await load();
    } catch (e) {
      setNote(tr((e as Error).message, lang));
    } finally {
      setBusy(false);
    }
  };

  const unlocked = data?.achievements.filter((a) => a.unlockedAt).length ?? 0;
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
        <p className="muted ach-summary">
          {t(`已解锁 ${unlocked} / ${data.achievements.length}。点「戴上」把徽章挂在名字后面。`, `${unlocked} of ${data.achievements.length} unlocked. Tap "Wear" to show a badge after your name.`)}
        </p>
      )}
      {note && <p className="note shop-note" role="status">{note}</p>}
      <div className="ach-grid">
        {(data?.achievements ?? []).map((a) => {
          const done = !!a.unlockedAt;
          const wearing = data?.badge === a.id;
          const now = progressOf(a, data?.progress ?? null);
          return (
            <article key={a.id} className={`ach${done ? " done" : ""}${wearing ? " wearing" : ""}`}>
              <div className="ach-badge">
                <Badge id={a.id} big />
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
                <span className="ach-reward">+{fmtMoney(a.reward)}</span>
                {done ? (
                  wearing ? (
                    <button className="btn btn-small btn-ghost" disabled={busy} onClick={() => wear(null)}>{t("摘下", "Take off")}</button>
                  ) : (
                    <button className="btn btn-small" disabled={busy} onClick={() => wear(a.id)}>{t("戴上", "Wear")}</button>
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
