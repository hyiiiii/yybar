// 主窗口 · bar（对应 Mac `BarView`）：和统计、设置都不同的独立页，不放标题和说明文字。
// 上面是一间像素风的木头小酒馆，直接画在页面上（不另起背景卡片）：屋顶立着 yybar 跑马灯招牌，门口站着 Claude 风格的
// 像素小家伙招手；点酒馆任意处用浏览器打开 yybar 网站的个人主页（/me）。
// 下面是上传卡片：连接 GitHub、待上传 / 已上传、自动上传（每天 12:00）、一键上传（每天一次），逻辑在后台 web.rs。
// 像素画照 Mac 版逐格搬过来（4px 一格，酒馆 104 × 70 格）。

import { memo, useEffect, useMemo, useState, type ReactNode } from "react";
import { api, useTicker } from "../../shared/api";
import { Icon, Toggle } from "../../shared/design";
import { relativeShort } from "../../shared/format";
import { tr } from "../../shared/l10n";
import type { StateSnapshot, WebProfile, WebView } from "../../shared/types";
import "./bar.css";

const PX = 4;
const SCENE_W = 104;
/** 地面比酒馆左右各宽 28 格，两头淡出 */
const GROUND_PAD = 28;

const hex = (c: number) => `#${c.toString(16).padStart(6, "0")}`;

type R = [x: number, y: number, w: number, h: number, c: number, a?: number];

/** 小酒馆本体（不动的部分）：屋顶、木板墙、门、两扇亮着的窗、酒桶。坐标单位是像素格。 */
function tavernRects(): R[] {
  const out: R[] = [];
  const r = (x: number, y: number, w: number, h: number, c: number, a?: number) => out.push([x, y, w, h, c, a]);
  // 招牌的两根立柱
  r(37, 14, 2, 6, 0x3a2213);
  r(65, 14, 2, 6, 0x3a2213);
  // 屋顶：梯形，两格一排瓦，错开的瓦缝
  for (let y = 14; y < 28; y++) {
    const inset = Math.floor(((27 - y) * 14) / 13);
    const left = 6 + inset;
    const width = 92 - inset * 2;
    r(left, y, width, 1, Math.floor(y / 2) % 2 === 0 ? 0x5a2f22 : 0x6a3727);
    if (y % 2 === 1) {
      for (let x = left + (Math.floor(y / 2) % 2) * 2; x < left + width; x += 5) r(x, y, 1, 1, 0x44231a);
    }
  }
  r(20, 13, 64, 1, 0x7e4632); // 屋脊
  r(5, 28, 94, 1, 0x3a1d14); // 屋檐
  // 木板墙：4 格一块板，最下一行是板缝，接缝错开
  for (let i = 0; i < 8; i++) {
    const y = 29 + i * 4;
    r(16, y, 72, 3, i % 2 === 0 ? 0x9b6a3c : 0x8f6136);
    r(16, y + 3, 72, 1, 0x6e4627);
    for (const x of i % 2 === 0 ? [30, 58, 78] : [22, 46, 70]) r(x, y, 1, 3, 0x6e4627);
  }
  r(14, 61, 76, 1, 0x4a2c18); // 墙脚的地梁
  r(14, 28, 3, 34, 0x4a2c18);
  r(15, 28, 1, 34, 0x5c3920);
  r(87, 28, 3, 34, 0x4a2c18);
  r(88, 28, 1, 34, 0x5c3920);
  // 窗：木框、暖黄玻璃、十字窗棂、花箱
  for (const wx of [22, 68]) {
    r(wx, 35, 14, 11, 0x3a2213);
    r(wx + 1, 36, 12, 9, 0xffd27f);
    r(wx + 1, 36, 4, 2, 0xffe6ae);
    r(wx + 6, 36, 2, 9, 0x3a2213);
    r(wx + 1, 40, 12, 1, 0x3a2213);
    r(wx - 1, 46, 16, 2, 0x5c3920);
    let k = 0;
    for (let fx = wx; fx < wx + 14; fx += 2, k++) {
      r(fx, 45, 1, 1, 0x5f8f3e);
      r(fx + 1, 44, 1, 1, k % 2 === 0 ? 0xe2574c : 0xf2c14e);
    }
  }
  // 门：拱形门框、门里的暖光、半开的门板
  r(45, 44, 14, 18, 0x3a2213);
  r(46, 43, 12, 1, 0x3a2213);
  r(47, 42, 10, 1, 0x3a2213);
  for (let y = 44; y < 61; y++) r(46, y, 12, 1, y < 50 ? 0xffd58a : y < 56 ? 0xf8be69 : 0xf0a94a);
  r(47, 43, 10, 1, 0xffd58a);
  r(46, 44, 4, 17, 0x6b4226);
  r(47, 44, 1, 17, 0x4a2c18);
  r(49, 52, 1, 1, 0xf2c14e); // 门把手
  r(44, 61, 16, 1, 0x6e5c4b); // 台阶
  // 门里一张小桌和两把凳子的影子
  r(51, 55, 6, 1, 0x8a5530);
  r(53, 56, 2, 4, 0x8a5530);
  r(51, 58, 1, 2, 0x8a5530);
  r(56, 58, 1, 2, 0x8a5530);
  // 灯笼的支架和灯身（火苗单独画，会跳）
  r(40, 39, 4, 1, 0x2a1a10);
  r(40, 40, 1, 1, 0x2a1a10);
  r(39, 41, 3, 5, 0x2a1a10);
  // 酒桶和木箱
  r(24, 53, 8, 9, 0x8a5530);
  r(24, 53, 8, 1, 0xa36a3d);
  for (const x of [26, 29]) r(x, 54, 1, 8, 0x6e4224);
  r(24, 55, 8, 1, 0x3d2b1f);
  r(24, 59, 8, 1, 0x3d2b1f);
  r(33, 57, 6, 5, 0x8a5a32);
  r(33, 57, 6, 1, 0x6e4627);
  r(33, 61, 6, 1, 0x6e4627);
  for (let k = 0; k < 4; k++) r(34 + k, 58 + (k % 3), 1, 1, 0x6e4627);
  // 门前地上的光
  r(44, 62, 16, 2, 0xf0a94a, 0.35);
  r(42, 64, 20, 1, 0xf0a94a, 0.18);
  return out;
}

/** 地面：一条石板路，上面一行草（比酒馆宽，两头淡出）。 */
function groundRects(): R[] {
  const cols = SCENE_W + GROUND_PAD * 2 + 1;
  const out: R[] = [[0, 0, cols, 6, 0x4a3e35], [0, 0, cols, 1, 0x5e7a3e]];
  for (let row = 0; row < 3; row++) {
    for (let col = (row % 2) * 3; col < cols; col += 6) out.push([col, 1 + row * 2, 4, 1, row === 0 ? 0x66574a : 0x5a4b3f]);
  }
  return out;
}

const Rects = memo(function Rects({ rects }: { rects: R[] }) {
  return (
    <>
      {rects.map(([x, y, w, h, c, a], i) => (
        <rect key={i} x={x * PX} y={y * PX} width={w * PX} height={h * PX} fill={hex(c)} opacity={a} />
      ))}
    </>
  );
});

const reducedMotion = () => typeof matchMedia !== "undefined" && matchMedia("(prefers-reduced-motion: reduce)").matches;

/** 动画时钟（秒）：12 帧够像素画用了；系统要求减少动态效果时停在第一帧。 */
function useClock(fps = 12): number {
  const [t, setT] = useState(() => performance.now() / 1000);
  useEffect(() => {
    if (reducedMotion()) return;
    const id = setInterval(() => setT(performance.now() / 1000), 1000 / fps);
    return () => clearInterval(id);
  }, [fps]);
  return t;
}

function Scene({ onEnter }: { onEnter: () => void }) {
  const t = useClock();
  const [hover, setHover] = useState(false);
  const tavern = useMemo(tavernRects, []);
  const ground = useMemo(groundRects, []);
  const flicker = Math.floor(t * 2) % 3;
  const w = (SCENE_W + GROUND_PAD * 2) * PX;
  return (
    <div className="bar-scene" onClick={onEnter} title={tr("Open my page on the yybar website", "打开 yybar 网站的个人主页")}>
      <div className="bar-scene-inner">
      <svg width={w} height={68 * PX} viewBox={`${-GROUND_PAD * PX} 0 ${w} ${68 * PX}`} shapeRendering="crispEdges" aria-hidden>
        <defs>
          <linearGradient id="bar-ground-fade" x1="0" x2="1">
            <stop offset="0" stopColor="#fff" stopOpacity="0" />
            <stop offset="0.2" stopColor="#fff" stopOpacity="1" />
            <stop offset="0.8" stopColor="#fff" stopOpacity="1" />
            <stop offset="1" stopColor="#fff" stopOpacity="0" />
          </linearGradient>
          {/* 遮罩用被遮的那一组自己的坐标（组已经平移到地面的左上角） */}
          <mask id="bar-ground-mask" maskUnits="userSpaceOnUse" x={0} y={0} width={w} height={6 * PX}>
            <rect x={0} y={0} width={w} height={6 * PX} fill="url(#bar-ground-fade)" />
          </mask>
          {/* 门口和灯笼的暖光（在墙前面晕开，自己淡到透明） */}
          <radialGradient id="bar-glow" cx={52 * PX} cy={54 * PX} r={24 * PX} gradientUnits="userSpaceOnUse">
            <stop offset="0" stopColor="#ffc86e" stopOpacity="0.45" />
            <stop offset="1" stopColor="#ffc86e" stopOpacity="0" />
          </radialGradient>
        </defs>
        <g mask="url(#bar-ground-mask)" transform={`translate(${-GROUND_PAD * PX} ${62 * PX})`}>
          <Rects rects={ground} />
        </g>
        <rect x={0} y={0} width={SCENE_W * PX} height={62 * PX} fill="url(#bar-glow)" shapeRendering="auto" />
        <Rects rects={tavern} />
        <rect x={40 * PX} y={42 * PX} width={PX} height={3 * PX} fill={hex(flicker === 0 ? 0xffe6ae : 0xffd27f)} />
        <g transform={`translate(${64 * PX} ${49 * PX})`} onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)}>
          <Greeter t={t} hover={hover} />
        </g>
      </svg>
      <MarqueeSign t={t} left={(GROUND_PAD + 31) * PX} />
      </div>
    </div>
  );
}

/** 门口招呼客人的像素小家伙（和网站发牌员同一个造型）：上下晃、眨眼、隔一会儿招手；鼠标移上去会笑。 */
function Greeter({ t, hover }: { t: number; hover: boolean }) {
  const blink = t % 4.2 < 0.14 && !hover;
  const waving = hover || t % 5 < 1.6;
  const armUp = waving && Math.floor(t * 4) % 2 === 0;
  const bob = Math.floor(t * 2) % 2 === 0 ? 0 : -2;
  const skin = "#d97757";
  const ink = "#141413";
  const r = (x: number, y: number, w: number, h: number, c: string, key: string): ReactNode => (
    <rect key={key} x={x * PX} y={y * PX} width={w * PX} height={h * PX} fill={c} />
  );
  const parts: ReactNode[] = [
    r(2, 1, 12, 8, skin, "body"),
    r(0, 4, 2, 2, skin, "armL"),
    r(14, armUp ? 2 : 4, 2, 2, skin, "armR"),
    ...[3, 5, 10, 12].map((x) => r(x, 9, 1, 3, skin, `leg${x}`)),
  ];
  if (hover) {
    for (const ex of [4.6, 10.4]) {
      parts.push(r(ex - 0.4, 4.4, 0.6, 0.5, ink, `a${ex}`), r(ex + 0.1, 3.9, 0.6, 0.5, ink, `b${ex}`), r(ex + 0.6, 4.4, 0.6, 0.5, ink, `c${ex}`));
    }
    parts.push(r(3, 5.6, 1.4, 0.7, "#f2a08a", "cheekL"), r(11.6, 5.6, 1.4, 0.7, "#f2a08a", "cheekR"));
  } else if (blink) {
    parts.push(r(4.3, 4.4, 1.6, 0.45, ink, "eyeL"), r(10.1, 4.4, 1.6, 0.45, ink, "eyeR"));
  } else {
    parts.push(r(4.6, 3, 1, 2, ink, "eyeL"), r(10.4, 3, 1, 2, ink, "eyeR"));
  }
  return <g transform={`translate(0 ${bob})`}>{parts}</g>;
}

/** 屋顶上的 yybar 跑马灯招牌：深色底板、一圈灯泡轮流亮、霓虹手写字，和网站上的招牌一致。 */
function MarqueeSign({ t, left }: { t: number; left: number }) {
  const w = 42 * PX;
  const h = 15 * PX;
  const phase = Math.floor(t / 0.4) % 3;
  const bulbs = useMemo(() => {
    const inset = 7;
    const step = 14;
    const out: [number, number][] = [];
    for (let x = inset; x <= w - inset; x += step) out.push([x, inset]);
    for (let y = inset + step; y <= h - inset; y += step) out.push([w - inset, y]);
    for (let x = w - inset - step; x >= inset; x -= step) out.push([x, h - inset]);
    for (let y = h - inset - step; y > inset; y -= step) out.push([inset, y]);
    return out;
  }, [w, h]);
  return (
    <div className="bar-sign" style={{ left, width: w, height: h }}>
      <svg width={w} height={h} aria-hidden>
        {bulbs.map(([x, y], i) => {
          const lit = i % 3 === phase;
          return (
            <g key={i}>
              {lit && <circle cx={x} cy={y} r={5.6} fill="#f4c16a" opacity={0.3} />}
              <circle cx={x} cy={y} r={2.6} fill="#f4c16a" opacity={lit ? 1 : 0.35} />
            </g>
          );
        })}
      </svg>
      <span className="bar-sign-text" style={{ fontSize: h * 0.56 }}>
        yybar
      </span>
    </div>
  );
}

// ---------- 上传卡片 ----------

function UploadCard({ web, autoUpload }: { web: WebView; autoUpload: boolean }) {
  const now = useTicker(30_000);
  const p = web.pending;
  const usd = (v: number) => `$${v.toFixed(2)}`;
  const uploadedText =
    web.uploadedDays === 0
      ? "—"
      : web.lastUploadAt
        ? tr(`${web.uploadedDays} days · last ${relativeShort(web.lastUploadAt, now)} ago`, `${web.uploadedDays} 天 · 上次 ${relativeShort(web.lastUploadAt, now)} 前`)
        : tr(`${web.uploadedDays} days`, `${web.uploadedDays} 天`);
  const buttonTitle = web.phase === "uploading" ? tr("Uploading…", "上传中…") : web.usedManualToday ? tr("Uploaded today", "今天已经上传过了") : tr("Upload now", "一键上传");
  return (
    <div className="panel bar-card">
      <div className="bar-grid">
        <span className="bar-label">GitHub</span>
        <span className="bar-value">
          {web.connected && web.profile ? (
            <>
              <WebAvatar profile={web.profile} size={20} />
              <b>@{web.profile.login}</b>
              {web.profile.name && web.profile.name !== web.profile.login && <span className="secondary">{web.profile.name}</span>}
              <span style={{ flex: 1 }} />
              <button className="link-button muted" onClick={() => api.webDisconnect()}>
                {tr("Disconnect", "断开")}
              </button>
            </>
          ) : web.phase === "waitingForBrowser" ? (
            <>
              <span className="spinner small" />
              <span className="secondary">{tr("Approve in your browser…", "在浏览器里授权…")}</span>
              <span style={{ flex: 1 }} />
              <button className="link-button" onClick={() => api.webCancelConnect()}>
                {tr("Cancel", "取消")}
              </button>
            </>
          ) : (
            <>
              <span className="secondary">{tr("Not connected", "未连接")}</span>
              <span style={{ flex: 1 }} />
              <button className="button" onClick={() => api.webConnect()}>
                {tr("Connect GitHub…", "连接 GitHub…")}
              </button>
            </>
          )}
        </span>

        <span className="bar-label">{tr("To upload", "待上传")}</span>
        <span className="bar-value num">
          {p.days.length === 0 ? (
            <span className="secondary">{tr("Nothing new — every finished day is in", "没有新的天：今天以前的都传过了")}</span>
          ) : (
            <>
              <span>{tr(`${p.days.length} days · ${usd(p.costUsd)}`, `${p.days.length} 天 · ${usd(p.costUsd)}`)}</span>
              <span className="bar-chips" title={tr("Estimated with this PC's prices; the website prices it with its own table.", "按本机价格估的；实际以网站按它自己的价格表算的为准")}>
                {tr(`≈ ${p.chips.toLocaleString()} chips`, `≈ ${p.chips.toLocaleString()} 筹码`)}
              </span>
            </>
          )}
        </span>

        <span className="bar-label">{tr("Uploaded", "已上传")}</span>
        <span className={`bar-value num ${web.uploadedDays === 0 ? "secondary" : ""}`}>{uploadedText}</span>

        <span className="bar-label">{tr("Auto upload", "自动上传")}</span>
        <span className="bar-value">
          <Toggle small checked={web.connected && autoUpload} disabled={!web.connected} onChange={(v) => api.updateSettings({ webAutoUpload: v })} />
          <span className={web.connected ? "" : "secondary"}>{tr("Upload every day at 12:00", "每天 12:00 上传")}</span>
        </span>
      </div>
      <div className="bar-actions">
        <button
          className="button primary"
          disabled={!web.connected || web.phase !== "idle" || web.usedManualToday || p.days.length === 0}
          onClick={() => api.webUploadNow()}
        >
          <Icon name="upload" size={13} />
          {buttonTitle}
        </button>
        {web.phase === "uploading" && <span className="spinner small" />}
        {web.message && <span className={`bar-message ${web.messageIsError ? "error" : ""}`}>{web.message}</span>}
      </div>
    </div>
  );
}

/** 连接的 GitHub 头像（圆形）；图片没加载出来时是名字首字母。bar 页和侧边栏左下角共用。 */
export function WebAvatar({ profile, size = 18 }: { profile: WebProfile; size?: number }) {
  const [failed, setFailed] = useState(false);
  return (
    <span className="web-avatar" style={{ width: size, height: size, fontSize: size * 0.5 }}>
      {profile.avatarUrl && !failed ? (
        <img src={profile.avatarUrl} alt="" width={size} height={size} onError={() => setFailed(true)} />
      ) : (
        profile.login.slice(0, 1).toUpperCase()
      )}
    </span>
  );
}

export function BarPage({ state }: { state: StateSnapshot }) {
  return (
    <div className="bar-page">
      <div className="bar-inner">
        <Scene onEnter={() => api.openSite()} />
        <UploadCard web={state.web} autoUpload={state.settings.webAutoUpload} />
      </div>
    </div>
  );
}
