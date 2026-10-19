import { useState } from "react";
import { Link, NavLink, Outlet, useLocation } from "react-router";
import { api, fmtInt } from "./api";
import { Guide } from "./Guide";
import { Avatar, LoginButton } from "./components";
import { BarIcon, BookIcon, CartIcon, GiftIcon, PodiumIcon, TrophyIcon } from "./icons";
import { setLang, useLang, useT } from "./i18n";
import { loginHref, notifyMeChanged, useMe } from "./useMe";

const DEMO = !!import.meta.env.VITE_DEMO;

/** 每日礼盒：没领时在跳，点一下拆开（盖子飞起、冒出 +$100），今天就停在拆开的样子 */
function DailyGift() {
  const { me } = useMe();
  const t = useT();
  const [popped, setPopped] = useState<number | null>(null);
  const claimed = !!me?.daily?.claimed;
  const amount = me?.daily?.amount ?? 100;
  const open = async () => {
    if (!me?.user) {
      if (DEMO) {
        (await import("./demo")).demoLogin();
        notifyMeChanged();
      } else location.href = loginHref();
      return;
    }
    if (claimed) return;
    const r = await api<{ amount: number }>("/api/me/daily", { method: "POST", json: {} });
    setPopped(r.amount);
    notifyMeChanged();
  };
  return (
    <button
      className={`head-icon gift-btn${!claimed && me?.user ? " gift-waiting" : ""}${claimed ? " gift-done" : ""}`}
      onClick={open}
      aria-label={claimed ? t("今天的礼盒已经拆了", "Today's gift is opened") : t("拆每日礼盒", "Open the daily gift")}
      title={claimed ? t("今天的礼盒已经拆了，明天再来", "Opened — come back tomorrow") : t(`每日礼盒：每天 $${amount}`, `Daily gift: $${amount} every day`)}
    >
      <GiftIcon open={claimed} />
      {popped !== null && popped > 0 && <span className="gift-pop" key={popped}>+${popped}</span>}
    </button>
  );
}

export function Layout() {
  const { me } = useMe();
  const user = me?.user;
  const location = useLocation();
  const lang = useLang();
  const t = useT();
  const [guide, setGuide] = useState(false);
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
          <button className="head-icon" onClick={() => setGuide(true)} aria-label={t("德州扑克入门", "Hold'em basics")} title={t("德州扑克入门", "Hold'em basics")}>
            <BookIcon />
          </button>
          <DailyGift />
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
      {guide && <Guide onClose={() => setGuide(false)} />}
    </div>
  );
}
