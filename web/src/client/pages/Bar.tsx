import { fmtInt } from "../api";
import { loginHref, useMe } from "../useMe";

export function BarPage() {
  const { me } = useMe();
  return (
    <section className="card center bar-teaser">
      <div className="cards" aria-hidden>🂡 🂮</div>
      <h2>yybar · 德州扑克</h2>
      <p>牌桌正在搭建中。开张后可以用积分入座，先和机器人练手，再开多人桌。</p>
      {me?.user && me.points && <p className="balance">你的积分：<strong>{fmtInt(me.points.balance)}</strong></p>}
      {me && !me.user && <a className="btn" href={loginHref("/bar")}>登录查看积分</a>}
      <p className="muted small">积分只能通过记录的 AI 花费获得，不能充值、购买或兑现。</p>
    </section>
  );
}
