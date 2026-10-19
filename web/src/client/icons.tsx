// 顶栏和排行榜用的小图标：24×24 线条图标，跟着文字颜色走。

const Icon = ({ children, label }: { children: React.ReactNode; label?: string }) => (
  <svg className="icon" viewBox="0 0 24 24" aria-hidden={!label} aria-label={label} role={label ? "img" : undefined}>
    {children}
  </svg>
);

/** 酒杯：Bar（牌桌） */
export const BarIcon = () => (
  <Icon>
    <path d="M4.5 4.5h15L12 13z" />
    <path d="M12 13v6.5M8 19.5h8" />
    <path d="M15.5 8.5h-7" />
  </Icon>
);

/** 购物车：商场 */
export const CartIcon = () => (
  <Icon>
    <path d="M3 4h2.4l2.2 10.2a1.4 1.4 0 0 0 1.4 1.1h7.8a1.4 1.4 0 0 0 1.4-1.1L19.8 8H6.4" />
    <circle cx="9.5" cy="19.2" r="1.3" />
    <circle cx="16.5" cy="19.2" r="1.3" />
  </Icon>
);

/** 奖杯：排行榜 */
export const TrophyIcon = () => (
  <Icon>
    <path d="M7.5 4.5h9v4.8a4.5 4.5 0 0 1-9 0z" />
    <path d="M7.5 6.5H5a2.5 2.5 0 0 0 2.6 3.4M16.5 6.5H19a2.5 2.5 0 0 1-2.6 3.4" />
    <path d="M12 13.8v3.4M8.5 20h7M9.5 17.2h5" />
  </Icon>
);

/** 一摞筹码：财富榜 */
export const CoinsIcon = () => (
  <Icon>
    <ellipse cx="12" cy="6.5" rx="6.5" ry="2.5" />
    <path d="M5.5 6.5v4c0 1.4 2.9 2.5 6.5 2.5s6.5-1.1 6.5-2.5v-4" />
    <path d="M5.5 10.5v4c0 1.4 2.9 2.5 6.5 2.5s6.5-1.1 6.5-2.5v-4" />
    <path d="M5.5 14.5v3c0 1.4 2.9 2.5 6.5 2.5s6.5-1.1 6.5-2.5v-3" />
  </Icon>
);

/** 火苗：燃烧 token 榜 */
export const FlameIcon = () => (
  <Icon>
    <path d="M12 21c-3.9 0-6.5-2.6-6.5-6.1 0-3.6 2.9-5.4 3.6-9.4 2.4 1.5 3.4 3.6 3.4 5.4 1-.6 1.7-1.7 1.9-3 2.4 2 4.1 4.3 4.1 7.1 0 3.5-2.6 6-6.5 6z" />
    <path d="M12 21c-1.6 0-2.7-1.1-2.7-2.6 0-1.6 1.3-2.4 1.7-4 1.1.8 1.6 1.7 1.6 2.6.5-.2.9-.6 1.1-1.2.9.9 1 1.7 1 2.6 0 1.5-1.1 2.6-2.7 2.6z" />
  </Icon>
);
