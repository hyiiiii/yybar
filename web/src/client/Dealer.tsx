import { useEffect, useRef, useState } from "react";

export type Mood = "idle" | "blink" | "happy" | "surprised" | "wink" | "sleepy" | "focus";

// 发牌员造型：Claude 的放射星芒，中间圆心是脸。星芒每根轻微伸缩，表情只靠眼睛和嘴。
const RAYS = [40, 33, 43, 31, 39, 34, 44, 30, 38, 35, 42, 32];

function Face({ mood }: { mood: Mood }) {
  const eye = (x: number, kind: Mood) => {
    switch (kind) {
      case "blink":
      case "sleepy":
        return <path d={`M${x - 2} -1 Q${x} ${kind === "sleepy" ? 0.4 : -0.2} ${x + 2} -1`} className="face-line" />;
      case "happy":
        return <path d={`M${x - 2.1} 0 Q${x} -3.2 ${x + 2.1} 0`} className="face-line" />;
      case "surprised":
        return <circle cx={x} cy={-1.2} r={2.1} className="face-fill" />;
      case "focus":
        return <ellipse cx={x} cy={-0.6} rx={1.5} ry={1.7} className="face-fill" />;
      default:
        return <ellipse cx={x} cy={-1.2} rx={1.45} ry={2.3} className="face-fill" />;
    }
  };
  const left = mood === "wink" ? "idle" : mood;
  const right = mood === "wink" ? "happy" : mood;
  return (
    <g className="face">
      {eye(-4.6, left)}
      {eye(4.6, right)}
      {mood === "surprised" ? (
        <ellipse cx={0} cy={5.2} rx={1.5} ry={1.8} className="face-fill" />
      ) : mood === "sleepy" ? (
        <path d="M-1.6 5.2 L1.6 5.2" className="face-line" />
      ) : (
        <path d={mood === "happy" || mood === "wink" ? "M-3.2 3.6 Q0 7.4 3.2 3.6" : "M-2.4 4.2 Q0 6 2.4 4.2"} className="face-line" />
      )}
      {(mood === "happy" || mood === "wink") && (
        <g className="face-blush">
          <ellipse cx={-8} cy={3} rx={2.2} ry={1.2} />
          <ellipse cx={8} cy={3} rx={2.2} ry={1.2} />
        </g>
      )}
    </g>
  );
}

export function DealerSprite({ mood, spin = 0 }: { mood: Mood; spin?: number }) {
  return (
    <svg className={`dealer-sprite mood-${mood}`} viewBox="-50 -50 100 100" aria-hidden>
      <defs>
        <radialGradient id="dealer-hub" cx="40%" cy="35%" r="70%">
          <stop offset="0%" stopColor="#ec9a7b" />
          <stop offset="100%" stopColor="#c8603d" />
        </radialGradient>
        <linearGradient id="dealer-ray" gradientUnits="userSpaceOnUse" x1="14" y1="0" x2="44" y2="0">
          <stop offset="0%" stopColor="#d36e4c" />
          <stop offset="100%" stopColor="#e2896a" />
        </linearGradient>
      </defs>
      <g className="rays" style={{ transform: `rotate(${spin}deg)` }}>
        {RAYS.map((len, i) => (
          <g key={i} transform={`rotate(${i * 30 + (i % 2 ? 4 : -3)})`}>
            <line className="ray" x1={14} y1={0} x2={len} y2={0} style={{ animationDelay: `${(i % 6) * -0.35}s` }} />
          </g>
        ))}
      </g>
      <circle r={15.5} className="hub" />
      <Face mood={mood} />
    </svg>
  );
}

const IDLE_LINES = ["要发牌吗？点我", "今天烧了多少 token？", "筹码够不够？", "我只发牌，不偷看"];

/**
 * 发牌员：会眨眼、上下晃，点一下推进一条街并换表情。
 * stage 由外部控制（0 翻牌前 … 4 摊牌），onAdvance 请求下一步。
 */
export function Dealer({ stage, onAdvance, lines }: { stage: number; onAdvance: () => void; lines: string[] }) {
  const [mood, setMood] = useState<Mood>("idle");
  const [bubble, setBubble] = useState<string>(IDLE_LINES[0]);
  const [hop, setHop] = useState(0);
  const [spin, setSpin] = useState(0);
  const base = useRef<Mood>("idle");
  const pokes = useRef(0);

  // 定时眨眼；长时间没人理就犯困
  useEffect(() => {
    let alive = true;
    let lastPoke = Date.now();
    const tick = () => {
      if (!alive) return;
      if (Date.now() - lastPoke > 20_000 && base.current === "idle") {
        setMood("sleepy");
        setBubble("zzz…");
      } else if (base.current === "idle" || base.current === "focus") {
        setMood("blink");
        setTimeout(() => alive && setMood(base.current), 140);
      }
      timer = setTimeout(tick, 2600 + Math.random() * 2200);
    };
    let timer = setTimeout(tick, 2000);
    const wake = () => (lastPoke = Date.now());
    addEventListener("pointerdown", wake);
    return () => {
      alive = false;
      clearTimeout(timer);
      removeEventListener("pointerdown", wake);
    };
  }, []);

  // 每推进一条街换一次表情和台词
  useEffect(() => {
    const moods: Mood[] = ["idle", "focus", "happy", "surprised", "wink"];
    base.current = moods[stage] ?? "idle";
    setMood(base.current);
    if (stage > 0) setBubble(lines[stage] ?? "");
    if (stage === 0 && pokes.current > 0) setBubble("重新洗牌～");
    if (stage === 0 || stage === 4) {
      const t = setTimeout(() => {
        base.current = "idle";
        setMood("idle");
      }, 1600);
      return () => clearTimeout(t);
    }
  }, [stage, lines]);

  const poke = () => {
    pokes.current += 1;
    setHop((h) => h + 1);
    setSpin((r) => r + 60);
    onAdvance();
  };

  return (
    <div className="dealer">
      <div className="bubble" key={bubble} role="status">{bubble}</div>
      <button
        className={`dealer-btn${hop % 2 ? " hop-a" : hop ? " hop-b" : ""}`}
        onClick={poke}
        onPointerEnter={() => base.current === "idle" && setMood("happy")}
        onPointerLeave={() => setMood(base.current)}
        aria-label="发牌员 Claude，点一下发下一条街"
      >
        <DealerSprite mood={mood} spin={spin} />
      </button>
    </div>
  );
}
