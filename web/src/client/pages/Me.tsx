import { useState } from "react";
import { useNavigate } from "react-router";
import { api, type Profile } from "../api";
import { Avatar, LoginButton } from "../components";
import { notifyMeChanged, useMe } from "../useMe";
import { ProfileView } from "./User";

export function MePage() {
  const { me, error, reload } = useMe();
  const navigate = useNavigate();
  const [newToken, setNewToken] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);

  if (error) return <p className="error">{error}</p>;
  if (!me) return <p className="empty">加载中…</p>;
  if (!me.user) {
    return (
      <section className="card-box center">
        <h2>先入场</h2>
        <p>用 GitHub 账号登录后，就能把 yybar 的用量同步上来。</p>
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
      setActionError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const createToken = () =>
    run(async () => {
      const { token } = await api<{ token: string }>("/api/me/tokens", { method: "POST", json: { label: "手动创建" } });
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
          <h1>{me.user.name || me.user.login}</h1>
          <span className="muted">@{me.user.login}</span>
        </div>
        <button className="btn btn-ghost push-right" onClick={logout} disabled={busy}>退出登录</button>
      </div>

      {me.totals && me.totals.active_days === 0 && (
        <section className="card-box notice">
          还没有收到数据。在 yybar App 的设置里点「连接网站」，或者在下面创建一个上传令牌填进 App。
        </section>
      )}

      <ProfileView profile={me as Profile} />

      <section className="card-box">
        <h2>设置</h2>
        <label className="row">
          <input type="checkbox" checked={me.user.showOnBoard} onChange={toggleBoard} disabled={busy} />
          在排行榜和公开主页上显示我
        </label>
      </section>

      <section className="card-box">
        <div className="card-head">
          <h2>上传令牌</h2>
          <button className="btn btn-small" onClick={createToken} disabled={busy}>新建令牌</button>
        </div>
        <p className="muted">App 用它上传每日汇总（只有 token 数和花费，不含对话内容）。不用的可以随时撤销。</p>
        {newToken && (
          <div className="token-reveal">
            <code>{newToken}</code>
            <button className="btn btn-small" onClick={() => navigator.clipboard.writeText(newToken)}>复制</button>
            <small>只显示这一次，关掉页面就看不到了。</small>
          </div>
        )}
        {actionError && <p className="error">{actionError}</p>}
        {me.tokens && me.tokens.length > 0 ? (
          <table className="table">
            <thead>
              <tr><th>名称</th><th>创建</th><th>最近使用</th><th /></tr>
            </thead>
            <tbody>
              {me.tokens.map((t) => (
                <tr key={t.id}>
                  <td>{t.label}</td>
                  <td>{t.created_at.slice(0, 10)}</td>
                  <td>{t.last_used_at ? t.last_used_at.slice(0, 16).replace("T", " ") : "未使用"}</td>
                  <td className="num"><button className="link-danger" onClick={() => revoke(t.id)} disabled={busy}>撤销</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : (
          <p className="empty">还没有令牌。</p>
        )}
      </section>
    </>
  );
}
