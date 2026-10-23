// 牌桌音效：全用 Web Audio 现场合成，不带音频文件。浏览器要求用户先点过页面才能出声，
// 所以第一次点击时才建 AudioContext；静音设置记在浏览器里。
import { useSyncExternalStore } from "react";

const KEY = "yyb:muted";
let ctx: AudioContext | null = null;
let master: GainNode | null = null;
let muted = (() => {
  try {
    return localStorage.getItem(KEY) === "1";
  } catch {
    return false;
  }
})();
const listeners = new Set<() => void>();

function unlock() {
  if (ctx) return;
  try {
    ctx = new AudioContext();
    master = ctx.createGain();
    master.gain.value = 0.35;
    master.connect(ctx.destination);
  } catch {
    // 不支持就静默
  }
}
if (typeof window !== "undefined") addEventListener("pointerdown", unlock, { once: true });

export function setMuted(m: boolean) {
  muted = m;
  try {
    localStorage.setItem(KEY, m ? "1" : "0");
  } catch {
    // 存不了就只在这次打开里生效
  }
  listeners.forEach((fn) => fn());
}

export function useMuted() {
  return useSyncExternalStore(
    (fn) => (listeners.add(fn), () => listeners.delete(fn)),
    () => muted,
  );
}

/** 拿到能用的 AudioContext；静音、还没点过页面、标签页在后台时返回 null */
function audio(): AudioContext | null {
  if (muted || !ctx || !master || document.hidden) return null;
  if (ctx.state === "suspended") ctx.resume();
  return ctx;
}

/** 一段音：振荡器，带起音和衰减 */
function tone(freq: number, at: number, dur: number, { type = "sine", gain = 0.5, to }: { type?: OscillatorType; gain?: number; to?: number } = {}) {
  const a = audio();
  if (!a) return;
  const t = a.currentTime + at;
  const osc = a.createOscillator();
  const g = a.createGain();
  osc.type = type;
  osc.frequency.setValueAtTime(freq, t);
  if (to) osc.frequency.exponentialRampToValueAtTime(to, t + dur);
  g.gain.setValueAtTime(0.0001, t);
  g.gain.exponentialRampToValueAtTime(gain, t + 0.008);
  g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
  osc.connect(g).connect(master!);
  osc.start(t);
  osc.stop(t + dur + 0.02);
}

/** 一段噪声：过一个带通滤波器，模拟筹码碰撞、纸牌摩擦 */
function noise(at: number, dur: number, { freq = 3000, q = 1.5, gain = 0.4, to }: { freq?: number; q?: number; gain?: number; to?: number } = {}) {
  const a = audio();
  if (!a) return;
  const t = a.currentTime + at;
  const len = Math.ceil(a.sampleRate * dur);
  const buf = a.createBuffer(1, len, a.sampleRate);
  const data = buf.getChannelData(0);
  for (let i = 0; i < len; i++) data[i] = (Math.random() * 2 - 1) * (1 - i / len);
  const src = a.createBufferSource();
  src.buffer = buf;
  const f = a.createBiquadFilter();
  f.type = "bandpass";
  f.Q.value = q;
  f.frequency.setValueAtTime(freq, t);
  if (to) f.frequency.exponentialRampToValueAtTime(to, t + dur);
  const g = a.createGain();
  g.gain.setValueAtTime(gain, t);
  g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
  src.connect(f).connect(g).connect(master!);
  src.start(t);
}

export const sfx = {
  /** 下注、跟注、加注：两三下筹码碰撞 */
  chips(n = 2) {
    for (let k = 0; k < n; k++) {
      noise(k * 0.055, 0.05, { freq: 4200 + Math.random() * 900, q: 6, gain: 0.5 });
      tone(2600 + Math.random() * 500, k * 0.055, 0.04, { type: "triangle", gain: 0.08 });
    }
  },
  /** 过牌：敲两下桌子 */
  check() {
    for (const at of [0, 0.11]) {
      tone(150, at, 0.09, { gain: 0.6, to: 80 });
      noise(at, 0.03, { freq: 900, q: 1, gain: 0.25 });
    }
  },
  /** 弃牌：牌滑出去的一声 */
  fold() {
    noise(0, 0.28, { freq: 2400, q: 0.8, gain: 0.35, to: 500 });
  },
  /** 发一张牌：轻轻一弹 */
  deal(at = 0) {
    noise(at, 0.07, { freq: 5200, q: 1.2, gain: 0.3, to: 2500 });
  },
  /** 轮到自己：两声提示 */
  turn() {
    tone(880, 0, 0.18, { gain: 0.25 });
    tone(1320, 0.12, 0.26, { gain: 0.22 });
  },
  /** 最后几秒倒计时 */
  tick() {
    tone(1600, 0, 0.05, { type: "square", gain: 0.06 });
  },
  /** 赢了：一串上行的音加筹码声 */
  win() {
    [660, 880, 1100, 1320].forEach((f, k) => tone(f, k * 0.08, 0.3, { type: "triangle", gain: 0.25 }));
    for (let k = 0; k < 4; k++) noise(0.3 + k * 0.05, 0.05, { freq: 4500, q: 6, gain: 0.4 });
  },
  /** 番茄砸到头上：啪叽一下 */
  splat() {
    noise(0, 0.16, { freq: 900, q: 0.9, gain: 0.55, to: 260 });
    tone(220, 0, 0.12, { gain: 0.25, to: 90 });
  },
  /** 发表情、拆礼盒：啵一下 */
  pop() {
    tone(420, 0, 0.12, { gain: 0.35, to: 980 });
  },
};
