import { Link, NavLink, Outlet } from "react-router";
import { loginHref, useMe } from "./useMe";

export function Layout() {
  const { me } = useMe();
  const user = me?.user;
  return (
    <div className="shell">
      <header className="topbar">
        <Link to="/" className="brand">
          <img src="/icon.png" alt="" width={28} height={28} />
          <span>yybar</span>
        </Link>
        <nav>
          <NavLink to="/" end>排行榜</NavLink>
          <NavLink to="/bar">Bar</NavLink>
          {user ? (
            <NavLink to="/me" className="me-link">
              {user.avatarUrl && <img src={user.avatarUrl} alt="" width={22} height={22} />}
              {user.login}
            </NavLink>
          ) : (
            me && <a href={loginHref("/me")} className="btn btn-small">GitHub 登录</a>
          )}
        </nav>
      </header>
      <main>
        <Outlet />
      </main>
      <footer className="footer">
        yybar · 用量数据由各自的 yybar App 在本机统计后上传 · 积分仅供站内娱乐，不能充值或兑现
      </footer>
    </div>
  );
}
