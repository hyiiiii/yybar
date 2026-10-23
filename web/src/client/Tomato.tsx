// 扔番茄：番茄从扔的人的座位（旁观的人从桌子下边）划一道弧线飞到被砸的人头像上，啪一下糊在上面，过一会儿滑落消失。
// 直接在牌桌外层（.felt-wrap）里加元素、用 Web Animations 播，不走 React 状态，五连发也不会让整桌重画。
import { forwardRef, useImperativeHandle, useRef } from "react";
import { sfx } from "./sound";

export interface TomatoThrower {
  /** from、to 是显示位（0 是自己那一格）；from 为 null 表示旁观的人从桌子下边扔 */
  throw(from: number | null, to: number, n: number): void;
}

const TOMATO_SVG = `<svg viewBox="0 0 32 32" aria-hidden><ellipse cx="16" cy="18" rx="12" ry="11" fill="#e8442e"/><ellipse cx="11.5" cy="14" rx="3.4" ry="2.2" fill="#ff8a70" opacity=".75"/><path d="M16 8.5l-2.2-3.2 3 1.4 2.4-2.4-.2 3.4 3.4.6-3.4 1.6z" fill="#3f9b3a"/></svg>`;
const SPLAT_SVG = `<svg viewBox="0 0 64 64" aria-hidden><path d="M32 12c4 0 5 7 9 7s7-6 10-3-3 8-1 11 9 2 9 6-7 4-8 8 5 8 2 11-8-2-11 0-3 9-8 9-5-8-9-8-7 6-10 3 2-8 0-11-9-3-9-7 7-3 8-7-6-7-3-10 8 3 11 0 2-9 9-9z" fill="#e8442e"/><circle cx="25" cy="27" r="3" fill="#ff8a70" opacity=".7"/><circle cx="10" cy="20" r="2.4" fill="#e8442e"/><circle cx="55" cy="46" r="2.8" fill="#e8442e"/><circle cx="50" cy="12" r="1.8" fill="#e8442e"/></svg>`;

const reduced = () => typeof matchMedia !== "undefined" && matchMedia("(prefers-reduced-motion: reduce)").matches;

export const TomatoLayer = forwardRef<TomatoThrower>(function TomatoLayer(_, ref) {
  const layer = useRef<HTMLDivElement>(null);

  useImperativeHandle(ref, () => ({
    throw(from, to, n) {
      const el = layer.current;
      const wrap = el?.parentElement;
      if (!el || !wrap) return;
      const box = wrap.getBoundingClientRect();
      const center = (d: number) => {
        const disc = wrap.querySelector(`.seat.pos-${d} .seat-disc`);
        if (!disc) return null;
        const r = disc.getBoundingClientRect();
        return { x: r.left + r.width / 2 - box.left, y: r.top + r.height / 2 - box.top };
      };
      const target = center(to);
      if (!target) return;
      const start = (from !== null && center(from)) || { x: box.width / 2, y: box.height + 40 };
      for (let k = 0; k < n; k++) setTimeout(() => fly(el, start, target, k, n), k * 220);
    },
  }));

  return <div className="tomato-layer" ref={layer} aria-hidden />;
});

function fly(layer: HTMLElement, from: { x: number; y: number }, to: { x: number; y: number }, k: number, n: number) {
  // 五连发每个落点稍微错开一点
  const jitter = n > 1 ? { x: (Math.random() - 0.5) * 26, y: (Math.random() - 0.5) * 22 } : { x: 0, y: 0 };
  const end = { x: to.x + jitter.x, y: to.y + jitter.y };
  const dist = Math.hypot(end.x - from.x, end.y - from.y);
  const lift = Math.min(160, 50 + dist * 0.3);
  const t = document.createElement("span");
  t.className = "tomato";
  t.innerHTML = TOMATO_SVG;
  layer.appendChild(t);
  const at = (p: number) => {
    const x = from.x + (end.x - from.x) * p;
    const y = from.y + (end.y - from.y) * p - lift * 4 * p * (1 - p);
    return `translate(${x}px, ${y}px) rotate(${p * 540}deg) scale(${1 - 0.15 * p})`;
  };
  const dur = reduced() ? 1 : 520 + Math.min(260, dist * 0.35);
  const anim = t.animate(
    [0, 0.2, 0.4, 0.6, 0.8, 1].map((p) => ({ transform: at(p) })),
    { duration: dur, easing: "linear", fill: "forwards" },
  );
  anim.onfinish = () => {
    t.remove();
    sfx.splat();
    const s = document.createElement("span");
    s.className = "tomato-splat";
    s.innerHTML = SPLAT_SVG;
    s.style.transform = `translate(${end.x}px, ${end.y}px) rotate(${Math.round(Math.random() * 360)}deg)`;
    layer.appendChild(s);
    // 最后一个落下后整团一起往下滑、淡掉
    const keep = 2200 + (n - 1 - k) * 220;
    s.animate(
      [
        { opacity: 0, scale: 0.3 },
        { opacity: 1, scale: 1.15, offset: 0.06 },
        { opacity: 1, scale: 1, offset: 0.12 },
        { opacity: 1, translate: "0 6px", offset: 0.75 },
        { opacity: 0, translate: "0 18px" },
      ],
      { duration: reduced() ? 1200 : keep, easing: "ease-out", fill: "forwards" },
    ).onfinish = () => s.remove();
  };
}

/** 小番茄图标：头像卡片上扔番茄的按钮用 */
export function TomatoIcon() {
  return <span className="tomato-icon" dangerouslySetInnerHTML={{ __html: TOMATO_SVG }} />;
}
