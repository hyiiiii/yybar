// 扔番茄、送玫瑰：从扔的人的座位（旁观的人从桌子下边）划一道弧线飞到对方头像上。
// 番茄啪一下糊在上面，过一会儿滑落消失；玫瑰轻轻落在头像上，冒几颗小心心，过一会儿淡掉。
// 直接在牌桌外层（.felt-wrap）里加元素、用 Web Animations 播，不走 React 状态，五连发也不会让整桌重画。
import { forwardRef, useImperativeHandle, useRef } from "react";
import { sfx } from "./sound";
import type { ThrowItem } from "../shared/cosmetics";

export interface Thrower {
  /** from、to 是显示位（0 是自己那一格）；from 为 null 表示旁观的人从桌子下边扔 */
  throw(item: ThrowItem, from: number | null, to: number, n: number): void;
}

const TOMATO_SVG = `<svg viewBox="0 0 32 32" aria-hidden><ellipse cx="16" cy="18" rx="12" ry="11" fill="#e8442e"/><ellipse cx="11.5" cy="14" rx="3.4" ry="2.2" fill="#ff8a70" opacity=".75"/><path d="M16 8.5l-2.2-3.2 3 1.4 2.4-2.4-.2 3.4 3.4.6-3.4 1.6z" fill="#3f9b3a"/></svg>`;
const SPLAT_SVG = `<svg viewBox="0 0 64 64" aria-hidden><path d="M32 12c4 0 5 7 9 7s7-6 10-3-3 8-1 11 9 2 9 6-7 4-8 8 5 8 2 11-8-2-11 0-3 9-8 9-5-8-9-8-7 6-10 3 2-8 0-11-9-3-9-7 7-3 8-7-6-7-3-10 8 3 11 0 2-9 9-9z" fill="#e8442e"/><circle cx="25" cy="27" r="3" fill="#ff8a70" opacity=".7"/><circle cx="10" cy="20" r="2.4" fill="#e8442e"/><circle cx="55" cy="46" r="2.8" fill="#e8442e"/><circle cx="50" cy="12" r="1.8" fill="#e8442e"/></svg>`;
const ROSE_SVG = `<svg viewBox="0 0 32 32" aria-hidden><path d="M16 17c.5 4 .2 8-.6 12" stroke="#3f9b3a" stroke-width="1.8" fill="none" stroke-linecap="round"/><path d="M15.7 22.5c-2.6-2.2-5.6-2.3-7.4-1 2 2.1 4.8 2.5 7.4 1z" fill="#4caf50"/><path d="M16 22c2.3-2.4 5.3-2.8 7.2-1.6-1.8 2.3-4.6 2.9-7.2 1.6z" fill="#3f9b3a"/><path d="M9 9.5c0-3.3 3.1-5.8 7-5.8s7 2.5 7 5.8c0 4.2-3.1 7.8-7 7.8s-7-3.6-7-7.8z" fill="#d6234a"/><path d="M12 8.6c1.1-2 3.2-2.9 4.9-2.3 1.9.7 2.6 2.8 1.4 4.6-1 1.5-3.3 1.8-4.5.6-.9-.9-.6-2.4.6-2.6" fill="none" stroke="#9e1233" stroke-width="1.1" stroke-linecap="round"/><path d="M9.2 10.6c1.7 1.4 3.7 2 6 1.8M22.8 10.6c-1.6 1.6-3.7 2.3-6 2" fill="none" stroke="#9e1233" stroke-width="1" stroke-linecap="round"/></svg>`;
const HEART_SVG = `<svg viewBox="0 0 16 16" aria-hidden><path d="M8 14s-5.5-3.4-5.5-7.2C2.5 4.6 4 3.2 5.7 3.2c1 0 1.8.5 2.3 1.3.5-.8 1.3-1.3 2.3-1.3 1.7 0 3.2 1.4 3.2 3.6C13.5 10.6 8 14 8 14z" fill="#f0436b"/></svg>`;

const reduced = () => typeof matchMedia !== "undefined" && matchMedia("(prefers-reduced-motion: reduce)").matches;

type Point = { x: number; y: number };

export const ThrowLayer = forwardRef<Thrower>(function ThrowLayer(_, ref) {
  const layer = useRef<HTMLDivElement>(null);

  useImperativeHandle(ref, () => ({
    throw(item, from, to, n) {
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
      for (let k = 0; k < n; k++) setTimeout(() => fly(el, item, start, target, k, n), k * 220);
    },
  }));

  return <div className="throw-layer" ref={layer} aria-hidden />;
});

/** 先把位置、透明度写好再挂到页面上：不然第一帧会在左上角（0, 0）闪一下 */
function spawn(layer: HTMLElement, cls: string, svg: string, style: Partial<CSSStyleDeclaration>): HTMLElement {
  const el = document.createElement("span");
  el.className = cls;
  el.innerHTML = svg;
  Object.assign(el.style, style);
  layer.appendChild(el);
  return el;
}

function fly(layer: HTMLElement, item: ThrowItem, from: Point, to: Point, k: number, n: number) {
  // 五连发每个落点稍微错开一点
  const jitter = n > 1 ? { x: (Math.random() - 0.5) * 26, y: (Math.random() - 0.5) * 22 } : { x: 0, y: 0 };
  const end = { x: to.x + jitter.x, y: to.y + jitter.y - (item === "rose" ? 6 : 0) };
  const dist = Math.hypot(end.x - from.x, end.y - from.y);
  const lift = Math.min(160, 50 + dist * 0.3);
  // 番茄一路翻滚；玫瑰轻轻转半圈，落地时花朝上
  const spin = item === "rose" ? 200 : 540;
  const at = (p: number) => {
    const x = from.x + (end.x - from.x) * p;
    const y = from.y + (end.y - from.y) * p - lift * 4 * p * (1 - p);
    return `translate(${x}px, ${y}px) rotate(${(p - 1) * spin}deg) scale(${1 - 0.15 * p})`;
  };
  const t = spawn(layer, item === "rose" ? "thrown thrown-rose" : "thrown", item === "rose" ? ROSE_SVG : TOMATO_SVG, { transform: at(0) });
  const dur = reduced() ? 1 : (item === "rose" ? 700 : 520) + Math.min(260, dist * 0.35);
  const anim = t.animate(
    [0, 0.2, 0.4, 0.6, 0.8, 1].map((p) => ({ transform: at(p) })),
    { duration: dur, easing: item === "rose" ? "ease-out" : "linear", fill: "forwards" },
  );
  anim.onfinish = () => (item === "rose" ? landRose(layer, t, end) : splat(layer, t, end, k, n));
}

/** 番茄：换成一摊，弹一下，最后一个落下后一起往下滑、淡掉 */
function splat(layer: HTMLElement, tomato: HTMLElement, end: Point, k: number, n: number) {
  sfx.splat();
  const s = spawn(layer, "tomato-splat", SPLAT_SVG, {
    transform: `translate(${end.x}px, ${end.y}px) rotate(${Math.round(Math.random() * 360)}deg)`,
    opacity: "0",
  });
  // 一摊挂上去了再拿掉番茄，中间不会空一帧
  tomato.remove();
  const keep = 2200 + (n - 1 - k) * 220;
  s.animate(
    [
      { opacity: 1, scale: 0.4 },
      { opacity: 1, scale: 1.15, offset: 0.06 },
      { opacity: 1, scale: 1, offset: 0.12 },
      { opacity: 1, translate: "0 6px", offset: 0.75 },
      { opacity: 0, translate: "0 18px" },
    ],
    { duration: reduced() ? 1200 : keep, easing: "ease-out", fill: "forwards" },
  ).onfinish = () => s.remove();
}

/** 玫瑰：落在头像上停一会儿，冒几颗小心心往上飘，然后一起淡掉 */
function landRose(layer: HTMLElement, rose: HTMLElement, end: Point) {
  sfx.rose();
  rose.animate(
    [
      { transform: rose.style.transform, opacity: 1 },
      { transform: `translate(${end.x}px, ${end.y}px) scale(1.12)`, opacity: 1, offset: 0.08 },
      { transform: `translate(${end.x}px, ${end.y}px) scale(1)`, opacity: 1, offset: 0.16 },
      { transform: `translate(${end.x}px, ${end.y}px) scale(1)`, opacity: 1, offset: 0.8 },
      { transform: `translate(${end.x}px, ${end.y - 8}px) scale(.9)`, opacity: 0 },
    ],
    { duration: reduced() ? 1200 : 2600, easing: "ease-out", fill: "forwards" },
  ).onfinish = () => rose.remove();
  if (reduced()) return;
  for (let h = 0; h < 4; h++) {
    const dx = (h - 1.5) * 12 + (Math.random() - 0.5) * 6;
    const heart = spawn(layer, "rose-heart", HEART_SVG, { transform: `translate(${end.x}px, ${end.y}px) scale(.4)`, opacity: "0" });
    heart.animate(
      [
        { transform: `translate(${end.x}px, ${end.y}px) scale(.4)`, opacity: 0 },
        { transform: `translate(${end.x + dx * 0.5}px, ${end.y - 18}px) scale(1)`, opacity: 1, offset: 0.25 },
        { transform: `translate(${end.x + dx}px, ${end.y - 52}px) scale(.8)`, opacity: 0 },
      ],
      { duration: 1300, delay: 120 + h * 140, easing: "ease-out", fill: "both" },
    ).onfinish = () => heart.remove();
  }
}

/** 头像卡片上按钮用的小图标 */
export function ThrowIcon({ item }: { item: ThrowItem }) {
  return <span className="throw-icon" dangerouslySetInnerHTML={{ __html: item === "rose" ? ROSE_SVG : TOMATO_SVG }} />;
}
