import { useEffect, useState } from "react";
import { sfx } from "./sound";
import { Link, NavLink, Outlet, useLocation } from "react-router";
import { api, fmtInt } from "./api";
import { Guide } from "./Guide";
import { Avatar, LoginButton } from "./components";
import { BarIcon, BookIcon, CartIcon, EyeIcon, GiftIcon, GitHubIcon, MailIcon, PodiumIcon, RunoutIcon, TimeIcon, TrophyIcon } from "./icons";
import { pick, setLang, useLang, useT } from "./i18n";
import { findItem, type ItemId } from "../shared/cosmetics";
import { loginHref, notifyMeChanged, useMe } from "./useMe";

const DEMO = !!import.meta.env.VITE_DEMO;
/** 页面右下角的联系方式 */
const CONTACT = { github: "https://github.com/hyiiiii", email: "hyi030618@proton.me" };

/** 礼盒拆到一半要先登录：记下这个意图，登录回来自动拆 */
const GIFT_INTENT = "yyb:open-gift";
/** 礼盒送的道具用图标表示 */
const ITEM_ICON: Record<ItemId, () => React.JSX.Element> = { timecard: TimeIcon, peek: EyeIcon, runout: RunoutIcon };

/** 每日礼盒：没领就一直在跳，点一下直接领（盖子飞起、冒出 +$100），今天就停在拆开的样子 */
function DailyGift() {
  const { me } = useMe();
  const t = useT();
  const lang = useLang();
  const [popped, setPopped] = useState<{ amount: number; item: ItemId | null } | null>(null);
  const claimed = !!me?.daily?.claimed;
  const amount = me?.daily?.amount ?? 100;
  const claim = async () => {
    const r = await api<{ amount: number; item: ItemId | null }>("/api/me/daily", { method: "POST", json: {} });
    if (r.amount) sfx.pop();
    setPopped(r);
    notifyMeChanged();
  };
  // 登录回来接着拆
  useEffect(() => {
    if (!me?.user || claimed) return;
    try {
      if (sessionStorage.getItem(GIFT_INTENT)) {
        sessionStorage.removeItem(GIFT_INTENT);
        claim();
      }
    } catch {
      // 读不了就算了，用户再点一下
    }
  }, [me?.user?.login, claimed]);
  const open = async () => {
    if (claimed) return;
    if (me?.user) return claim();
    if (DEMO) {
      (await import("./demo")).demoLogin();
      await claim();
      return;
    }
    try {
      sessionStorage.setItem(GIFT_INTENT, "1");
    } catch {
      // 存不了就登录回来再点一下
    }
    location.href = loginHref();
  };
  return (
    <button
      className={`head-icon gift-btn${claimed ? " gift-done" : " gift-waiting"}`}
      onClick={open}
      aria-label={claimed ? t("今天的礼盒已经拆了", "Today's gift is opened") : t("拆每日礼盒", "Open the daily gift")}
      title={claimed ? t("今天的礼盒已经拆了，明天再来", "Opened — come back tomorrow") : t(`每日礼盒：每天 $${amount}，再随机送一个道具`, `Daily gift: $${amount} plus a random item, every day`)}
    >
      <GiftIcon open={claimed} />
      {popped !== null && popped.amount > 0 && (
        <span className="gift-pop" key={popped.amount}>
          +${popped.amount}
          {popped.item && (
            <small title={pick(findItem(popped.item)!.name, lang)}>
              +1 {(() => {
                const Icon = ITEM_ICON[popped.item];
                return <Icon />;
              })()}
            </small>
          )}
        </span>
      )}
    </button>
  );
}

/** 顶栏入口从左到右的顺序；切页面时往右的从右边滑进来，往左的从左边滑进来 */
function sectionOf(path: string): number {
  if (path === "/" || path.startsWith("/table") || path.startsWith("/bar")) return 0;
  const order = ["/shop", "/board", "/achievements", "/me", "/u/", "/connect"];
  const k = order.findIndex((p) => path.startsWith(p));
  return k < 0 ? 9 : k + 1;
}

export function Layout() {
  const { me } = useMe();
  const user = me?.user;
  const location = useLocation();
  const lang = useLang();
  const t = useT();
  const [guide, setGuide] = useState(false);
  // 方向在换入口的那一刻定下来，之后重绘（比如余额刷新）也不变，免得动画被打断
  const section = sectionOf(location.pathname);
  const [nav, setNav] = useState({ section, dir: "" });
  if (nav.section !== section) setNav({ section, dir: section > nav.section ? "page-next" : "page-prev" });
  const dir = nav.section === section ? nav.dir : "";
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
          <NavLink
            to="/achievements"
            className="nav-icon"
            aria-label={me?.achievementsReady ? t(`成就：${me.achievementsReady} 个可以领取`, `Achievements: ${me.achievementsReady} to claim`) : t("成就", "Achievements")}
            title={me?.achievementsReady ? t(`有 ${me.achievementsReady} 个成就可以领取`, `${me.achievementsReady} achievements to claim`) : t("成就", "Achievements")}
          >
            <TrophyIcon />
            {!!me?.achievementsReady && <span key={me.achievementsReady} className="nav-badge">{me.achievementsReady}</span>}
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
        {/* 换到另一个入口时整页重新挂载，按方向滑进来；同一个入口里（比如切桌）不动 */}
        <div key={section} className={`page ${dir}`}>
          <Outlet />
        </div>
      </main>
      <footer className="footer site-footer">
        <a href={CONTACT.github} target="_blank" rel="noreferrer" title="GitHub">
          <GitHubIcon />
          {CONTACT.github.replace(/^https:\/\//, "")}
        </a>
        <a href={`mailto:${CONTACT.email}`} title={t("发邮件", "Email")}>
          <MailIcon />
          {CONTACT.email}
        </a>
      </footer>
      {guide && <Guide onClose={() => setGuide(false)} />}
    </div>
  );
}
