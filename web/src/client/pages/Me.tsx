import { useState } from "react";
import { useNavigate } from "react-router";
import { api, fmtInt, fmtTokens, fmtUSD, type Profile } from "../api";
import { Avatar, Badges, LoginButton } from "../components";
import { notifyMeChanged, useMe } from "../useMe";
import { ProfileView } from "./User";
import { tr, useLang, useT } from "../i18n";

export function MePage() {
  const { me, error } = useMe();
  const navigate = useNavigate();
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const lang = useLang();
  const t = useT();

  if (error) return <p className="error">{tr(error, lang)}</p>;
  if (!me) return <p className="empty">{t("加载中…", "Loading…")}</p>;
  if (!me.user) {
    return (
      <section className="card-box center">
        <h2>{t("先入场", "Come on in")}</h2>
        <p>{t("用 GitHub 账号登录后，就能把 yybar 的用量同步上来。", "Sign in with GitHub to sync your yybar usage.")}</p>
        <LoginButton next="/me" />
      </section>
    );
  }

  const run = async (fn: () => Promise<void>) => {
    setBusy(true);
    setActionError(null);
    try {
      await fn();
    } catch (e) {
      setActionError(tr((e as Error).message, lang));
    } finally {
      setBusy(false);
    }
  };

  const toggleBoard = () =>
    run(async () => { await api("/api/me", { method: "PATCH", json: { showOnBoard: !me.user!.showOnBoard } }); notifyMeChanged(); });
  const logout = () => run(async () => { await api("/auth/logout", { method: "POST", json: {} }); notifyMeChanged(); navigate("/"); });

  return (
    <>
      <div className="profile-head">
        <Avatar url={me.user.avatarUrl} login={me.user.login} size={56} />
        <div>
          <h1>
            {me.user.name || me.user.login}
            <Badges ids={me.user.badges} />
          </h1>
          <span className="muted">@{me.user.login}</span>
        </div>
        <button className="btn btn-ghost push-right" onClick={logout} disabled={busy}>{t("退出登录", "Sign out")}</button>
      </div>

      {me.totals && me.totals.active_days === 0 && (
        <section className="card-box notice">
          {t("还没有收到数据，在 yybar 的设置里连接网站上传。", "No data yet — connect the website in yybar's settings to upload.")}
        </section>
      )}

      <ProfileView profile={me as Profile} />

      <section className="card-box">
        <h2>{t("设置", "Settings")}</h2>
        <label className="row">
          <input type="checkbox" checked={me.user.showOnBoard} onChange={toggleBoard} disabled={busy} />
          {t("在排行榜和公开主页上显示我", "Show me on the leaderboard and a public profile")}
        </label>
      </section>

      <section className="card-box">
        <h2>{t("上传记录", "Uploads")}</h2>
        {actionError && <p className="error">{actionError}</p>}
        {me.uploads && me.uploads.length > 0 ? (
          <div className="table-scroll">
            <table className="table">
              <thead>
                <tr>
                  <th>{t("日期", "Day")}</th>
                  <th>{t("上传时间", "Uploaded")}</th>
                  <th className="num">Token</th>
                  <th className="num">{t("花费", "Spend")}</th>
                  <th className="num">{t("换得筹码", "Chips")}</th>
                </tr>
              </thead>
              <tbody>
                {me.uploads.map((u) => (
                  <tr key={u.day}>
                    <td>{u.day}</td>
                    <td className="muted">{localTime(u.uploaded_at)}</td>
                    <td className="num">{fmtTokens(u.tokens)}</td>
                    <td className="num">{fmtUSD(u.cost_micro)}</td>
                    <td className="num"><span className="chip-count">{fmtInt(Math.floor(u.cost_micro / 1e6))}</span></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <p className="empty">{t("还没有上传记录。", "No uploads yet.")}</p>
        )}
      </section>
    </>
  );
}

/** 上传时间按本地时区显示到分钟 */
function localTime(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}
