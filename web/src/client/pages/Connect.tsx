import { useState } from "react";
import { useSearchParams } from "react-router";
import { api } from "../api";
import { useMe } from "../useMe";
import { LoginButton } from "../components";

/** yybar App 打开 /connect?state=xxx，用户确认后把令牌通过 yybar:// 交回给 App。 */
export function ConnectPage() {
  const [params] = useSearchParams();
  const state = params.get("state") ?? "";
  const { me } = useMe();
  const [done, setDone] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  if (!/^[A-Za-z0-9_-]{8,128}$/.test(state)) return <p className="error">链接不完整，请回到 yybar App 重新点「连接网站」。</p>;
  if (!me) return <p className="empty">加载中…</p>;
  if (!me.user) {
    return (
      <section className="card-box center">
        <h2>连接 yybar App</h2>
        <p>先用 GitHub 登录，再授权这台 Mac 上的 yybar 上传用量。</p>
        <LoginButton />
      </section>
    );
  }

  const approve = async () => {
    setError(null);
    try {
      const { redirect } = await api<{ redirect: string }>("/api/me/connect", { method: "POST", json: { state } });
      setDone(redirect);
      location.href = redirect;
    } catch (e) {
      setError((e as Error).message);
    }
  };

  return (
    <section className="card-box center">
      <h2>连接 yybar App</h2>
      {done ? (
        <>
          <p>已授权。如果 yybar 没有自动弹出，点下面的按钮。</p>
          <a className="btn" href={done}>打开 yybar</a>
        </>
      ) : (
        <>
          <p>
            允许这台 Mac 上的 yybar 以 <strong>@{me.user.login}</strong> 的身份上传每日 token 用量和花费？
            只上传汇总数字，不含对话内容和任何密钥。
          </p>
          <button className="btn" onClick={approve}>授权</button>
        </>
      )}
      {error && <p className="error">{error}</p>}
    </section>
  );
}
