import { Link, NavLink, Outlet } from "react-router";
import { fmtInt } from "./api";
import { Avatar, LoginButton } from "./components";
import { useMe } from "./useMe";

export function Layout() {
  const { me } = useMe();
  const user = me?.user;
  return (
    <div className="shell">
      <header className="topbar">
        <Link to="/" className="brand" aria-label="yybar 大厅">
          <img src="/icon.png" alt="" width={26} height={26} />
          <span>yybar</span>
        </Link>
        <nav>
          <NavLink to="/" end>大厅</NavLink>
          <NavLink to="/board">名人墙</NavLink>
          {user ? (
            <NavLink to="/me" className="me-link">
              <span className="chip-count">{fmtInt(me?.points?.balance ?? 0)}</span>
              <Avatar url={user.avatarUrl} login={user.login} size={26} />
            </NavLink>
          ) : (
            me && <LoginButton small next="/" />
          )}
        </nav>
      </header>
      <main>
        <Outlet />
      </main>
      <footer className="footer">
        <p>筹码只能用记录下来的 AI 花费换取（$1 = 100），不能充值、购买或兑现。</p>
        <p>用量由每个人自己的 yybar App 在本机统计后上传。</p>
      </footer>
    </div>
  );
}
