import { Link, NavLink, Outlet, useLocation } from "react-router";
import { fmtInt } from "./api";
import { Avatar, LoginButton } from "./components";
import { BarIcon, CartIcon, TrophyIcon } from "./icons";
import { useMe } from "./useMe";

export function Layout() {
  const { me } = useMe();
  const user = me?.user;
  const location = useLocation();
  return (
    <div className="shell">
      <header className="topbar">
        <Link to="/" className="brand" aria-label="yybar 大厅">
          <img src="/icon.png" alt="" width={26} height={26} />
          <span>yybar</span>
        </Link>
        <nav>
          {/* 三个入口都只用图标：Bar（牌桌）、商场、排行榜 */}
          <NavLink to="/" end className={({ isActive }) => `nav-icon${isActive || /^\/(table|bar)/.test(location.pathname) ? " active" : ""}`} aria-label="Bar" title="Bar">
            <BarIcon />
          </NavLink>
          <NavLink to="/shop" className="nav-icon" aria-label="商场" title="商场">
            <CartIcon />
          </NavLink>
          <NavLink to="/board" className="nav-icon" aria-label="排行榜" title="排行榜">
            <TrophyIcon />
          </NavLink>
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
    </div>
  );
}
