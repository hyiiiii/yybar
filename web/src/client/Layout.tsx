import { Link, NavLink, Outlet, useLocation } from "react-router";
import { fmtInt } from "./api";
import { Avatar, LoginButton } from "./components";
import { BarIcon, CartIcon, PodiumIcon, TrophyIcon } from "./icons";
import { setLang, useLang, useT } from "./i18n";
import { useMe } from "./useMe";

export function Layout() {
  const { me } = useMe();
  const user = me?.user;
  const location = useLocation();
  const lang = useLang();
  const t = useT();
  return (
    <div className="shell">
      <header className="topbar">
        <div className="brand-row">
          <Link to="/" className="brand" aria-label={t("yybar 大厅", "yybar lobby")}>
            <img src="/icon.png" alt="" width={26} height={26} />
            <span>yybar</span>
          </Link>
          {/* 中英切换 */}
          <button
            className="lang-toggle"
            onClick={() => setLang(lang === "zh" ? "en" : "zh")}
            aria-label={lang === "zh" ? "Switch to English" : "切换到中文"}
            title={lang === "zh" ? "Switch to English" : "切换到中文"}
          >
            <span className={lang === "zh" ? "on" : ""}>中</span>
            <span className={lang === "en" ? "on" : ""}>EN</span>
          </button>
        </div>
        <nav>
          {/* 入口都只用图标：Bar（牌桌）、商场、排行榜、成就 */}
          <NavLink to="/" end className={({ isActive }) => `nav-icon${isActive || /^\/(table|bar)/.test(location.pathname) ? " active" : ""}`} aria-label="Bar" title="Bar">
            <BarIcon />
          </NavLink>
          <NavLink to="/shop" className="nav-icon" aria-label={t("商场", "Shop")} title={t("商场", "Shop")}>
            <CartIcon />
          </NavLink>
          <NavLink to="/board" className="nav-icon" aria-label={t("排行榜", "Leaderboard")} title={t("排行榜", "Leaderboard")}>
            <PodiumIcon />
          </NavLink>
          <NavLink to="/achievements" className="nav-icon" aria-label={t("成就", "Achievements")} title={t("成就", "Achievements")}>
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
