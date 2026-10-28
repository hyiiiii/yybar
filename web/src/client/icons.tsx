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

/** 沙漏 +：加时卡 */
export const TimeIcon = () => (
  <Icon>
    <path d="M6.5 3.5h9M6.5 20.5h9" />
    <path d="M7.5 3.5c0 4.5 6.5 5.5 6.5 8.5s-6.5 4-6.5 8.5M14.5 3.5c0 2.5-1.4 3.8-2.9 5" />
    <path d="M18.5 9v6M15.5 12h6" />
  </Icon>
);

/** 眼睛：偷偷看 */
export const EyeIcon = () => (
  <Icon>
    <path d="M2.5 12s3.5-6 9.5-6 9.5 6 9.5 6-3.5 6-9.5 6-9.5-6-9.5-6z" />
    <circle cx="12" cy="12" r="2.6" />
  </Icon>
);

/** 两张牌翻开：发发看 */
export const RunoutIcon = () => (
  <Icon>
    <rect x="3.5" y="6" width="8" height="12" rx="1.5" />
    <rect x="12.5" y="6" width="8" height="12" rx="1.5" strokeDasharray="2 1.6" />
    <path d="M7.5 10.5v3M6 12h3" />
  </Icon>
);

/** 笑脸：发表情 */
export const SmileIcon = () => (
  <Icon>
    <circle cx="12" cy="12" r="8.5" />
    <path d="M8.5 14c1 1.4 2.1 2 3.5 2s2.5-.6 3.5-2" />
    <path d="M9 9.5v1M15 9.5v1" />
  </Icon>
);

/** 领奖台：排行榜 */
export const PodiumIcon = () => (
  <Icon>
    <path d="M9 20.5V9.5h6v11M3.5 20.5v-7h5.5M15 15.5h5.5v5M2.5 20.5h19" />
    <path d="M12 3.2l.9 1.8 2 .3-1.4 1.4.3 2-1.8-.9-1.8.9.3-2-1.4-1.4 2-.3z" />
  </Icon>
);

/** GitHub 的猫（页脚） */
export const GitHubIcon = () => (
  <svg className="icon" viewBox="0 0 24 24" aria-hidden="true" style={{ fill: "currentColor", stroke: "none" }}>
    <path d="M12 2a10 10 0 0 0-3.16 19.49c.5.09.68-.22.68-.48v-1.7c-2.78.6-3.37-1.34-3.37-1.34-.45-1.16-1.11-1.47-1.11-1.47-.91-.62.07-.6.07-.6 1 .07 1.53 1.03 1.53 1.03.9 1.52 2.34 1.08 2.91.83.09-.65.35-1.08.63-1.33-2.22-.25-4.55-1.11-4.55-4.94 0-1.09.39-1.98 1.03-2.68-.1-.25-.45-1.27.1-2.65 0 0 .84-.27 2.75 1.02a9.6 9.6 0 0 1 5 0c1.91-1.29 2.75-1.02 2.75-1.02.55 1.38.2 2.4.1 2.65.64.7 1.03 1.59 1.03 2.68 0 3.84-2.34 4.68-4.57 4.93.36.31.68.92.68 1.85v2.75c0 .27.18.58.69.48A10 10 0 0 0 12 2z" />
  </svg>
);

/** 信封：页脚邮箱 */
export const MailIcon = () => (
  <Icon>
    <rect x="3.5" y="5.5" width="17" height="13" rx="2" />
    <path d="m4 7 8 6 8-6" />
  </Icon>
);

/** 小书：德州入门 */
export const BookIcon = () => (
  <Icon>
    <path d="M4.5 5.5c2.5-1 5-1 7.5.5v13c-2.5-1.5-5-1.5-7.5-.5z" />
    <path d="M19.5 5.5c-2.5-1-5-1-7.5.5v13c2.5-1.5 5-1.5 7.5-.5z" />
  </Icon>
);

/** 礼盒：盖子单独一组，拆开时飞起来 */
export const GiftIcon = ({ open }: { open?: boolean }) => (
  <svg className={`icon gift${open ? " gift-open" : ""}`} viewBox="0 0 24 24" aria-hidden>
    <g className="gift-box">
      <rect x="5" y="11" width="14" height="9" rx="1.2" />
      <path d="M12 11v9" />
    </g>
    <g className="gift-lid">
      <rect x="4" y="7.5" width="16" height="3.5" rx="1" />
      <path d="M12 7.5v3.5M12 7.5c-1.4-2.6-4.6-3-4.6-1.2 0 1.4 2.6 1.2 4.6 1.2zM12 7.5c1.4-2.6 4.6-3 4.6-1.2 0 1.4-2.6 1.2-4.6 1.2z" />
    </g>
  </svg>
);

/** 喇叭：牌桌音效开关；muted 时画一道斜线 */
export const SpeakerIcon = ({ muted }: { muted?: boolean }) => (
  <Icon>
    <path d="M4.5 9.5h3l4-3.5v12l-4-3.5h-3z" />
    {muted ? <path d="M15.5 9.5l5 5M20.5 9.5l-5 5" /> : <path d="M15.5 9.2a4 4 0 0 1 0 5.6M18 7a7 7 0 0 1 0 10" />}
  </Icon>
);

/** 骰子：牌桌顶上掷骰子的按钮、座位上冒出来的点数；rolling 时翻滚一下 */
export const DiceIcon = ({ rolling }: { rolling?: boolean }) => (
  <svg className={`icon${rolling ? " dice-rolling" : ""}`} viewBox="0 0 24 24" aria-hidden>
    <rect x="4.5" y="4.5" width="15" height="15" rx="3.5" />
    {[[9, 9], [15, 9], [12, 12], [9, 15], [15, 15]].map(([x, y]) => (
      <circle key={`${x}-${y}`} cx={x} cy={y} r="1.3" fill="currentColor" stroke="none" />
    ))}
  </svg>
);

/** 机器人：机器人桌的桌号、机器人的头像 */
export const RobotIcon = ({ label }: { label?: string }) => (
  <Icon label={label}>
    <rect x="4.5" y="8" width="15" height="11" rx="3.2" />
    <path d="M12 8V5.2" />
    <circle cx="12" cy="4.2" r="1.1" />
    <path d="M9.3 12.4v1.4M14.7 12.4v1.4M10.2 16.2h3.6" />
    <path d="M2.6 12.2v3M21.4 12.2v3" />
  </Icon>
);
