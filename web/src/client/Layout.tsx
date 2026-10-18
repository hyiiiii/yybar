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
          <NavLink to="/" end>牌桌</NavLink>
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
      <footer className="footer">筹码只能用 AI 花费换取（$1 = 100），不能充值或兑现。</footer>
    </div>
  );
}
