import { useState } from "react";
import { useNavigate } from "react-router";
import { api, type Profile } from "../api";
import { Avatar, Badges, LoginButton } from "../components";
import { notifyMeChanged, useMe } from "../useMe";
import { ProfileView } from "./User";
import { tr, useLang, useT } from "../i18n";

export function MePage() {
  const { me, error, reload } = useMe();
  const navigate = useNavigate();
  const [newToken, setNewToken] = useState<string | null>(null);
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

  const createToken = () =>
    run(async () => {
      const { token } = await api<{ token: string }>("/api/me/tokens", { method: "POST", json: { label: t("手动创建", "Created manually") } });
      setNewToken(token);
      reload();
    });
  const revoke = (id: number) => run(async () => { await api(`/api/me/tokens/${id}`, { method: "DELETE" }); reload(); });
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
          {t("还没有收到数据。在 yybar App 的设置里点「连接网站」，或者在下面创建一个上传令牌填进 App。", "No data yet. In the yybar app settings, click \"Connect website\", or create an upload token below and paste it into the app.")}
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
        <div className="card-head">
          <h2>{t("上传令牌", "Upload tokens")}</h2>
          <button className="btn btn-small" onClick={createToken} disabled={busy}>{t("新建令牌", "New token")}</button>
        </div>
        <p className="muted">{t("App 用它上传每日汇总（只有 token 数和花费，不含对话内容）。不用的可以随时撤销。", "The app uses it to upload daily totals (token counts and spend only, no conversations). Revoke any you don't use.")}</p>
        {newToken && (
          <div className="token-reveal">
            <code>{newToken}</code>
            <button className="btn btn-small" onClick={() => navigator.clipboard.writeText(newToken)}>{t("复制", "Copy")}</button>
            <small>{t("只显示这一次，关掉页面就看不到了。", "Shown only once — it's gone when you leave this page.")}</small>
          </div>
        )}
        {actionError && <p className="error">{actionError}</p>}
        {me.tokens && me.tokens.length > 0 ? (
          <table className="table">
            <thead>
              <tr><th>{t("名称", "Name")}</th><th>{t("创建", "Created")}</th><th>{t("最近使用", "Last used")}</th><th /></tr>
            </thead>
            <tbody>
              {me.tokens.map((tk) => (
                <tr key={tk.id}>
                  <td>{tk.label}</td>
                  <td>{tk.created_at.slice(0, 10)}</td>
                  <td>{tk.last_used_at ? tk.last_used_at.slice(0, 16).replace("T", " ") : t("未使用", "Never")}</td>
                  <td className="num"><button className="link-danger" onClick={() => revoke(tk.id)} disabled={busy}>{t("撤销", "Revoke")}</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : (
          <p className="empty">{t("还没有令牌。", "No tokens yet.")}</p>
        )}
      </section>
    </>
  );
}
