import { useEffect, useRef, useState } from "react";

export type Mood = "idle" | "blink" | "happy" | "surprised" | "wink" | "sleepy" | "focus";

/** 眼睛：16×13 像素网格里的左右眼，按表情换形状。 */
function Eyes({ mood }: { mood: Mood }) {
  const eye = (x: number, kind: Mood) => {
    switch (kind) {
      case "blink":
      case "sleepy":
        return <rect x={x - 0.3} y={4.4} width={1.6} height={0.45} rx={0.2} />;
      case "happy":
        return <path d={`M${x - 0.4} 4.9 L${x + 0.5} 3.9 L${x + 1.4} 4.9`} fill="none" stroke="currentColor" strokeWidth={0.55} strokeLinecap="round" strokeLinejoin="round" />;
      case "surprised":
        return <rect x={x - 0.25} y={3.2} width={1.5} height={1.9} rx={0.2} />;
      case "focus":
        return <rect x={x} y={3.6} width={1} height={1.4} />;
      default:
        return <rect x={x} y={3} width={1} height={2} />;
    }
  };
  const left = mood === "wink" ? "idle" : mood;
  const right = mood === "wink" ? "happy" : mood;
  return (
    <g className="dealer-eyes">
      {eye(4.6, left)}
      {eye(10.4, right)}
    </g>
  );
}

/** Claude 风格的像素小家伙，系着领结当发牌员。 */
export function DealerSprite({ mood }: { mood: Mood }) {
  return (
    <svg className="dealer-sprite" viewBox="0 0 16 13" shapeRendering="crispEdges" aria-hidden>
      <g className="dealer-body">
        <rect x={2} y={1} width={12} height={8} />
        <rect x={0} y={4} width={2} height={2} className="dealer-arm dealer-arm-l" />
        <rect x={14} y={4} width={2} height={2} className="dealer-arm dealer-arm-r" />
      </g>
      <g className="dealer-legs">
        <rect x={3} y={9} width={1} height={3} />
        <rect x={5} y={9} width={1} height={3} />
        <rect x={10} y={9} width={1} height={3} />
        <rect x={12} y={9} width={1} height={3} />
      </g>
      <Eyes mood={mood} />
      {(mood === "happy" || mood === "wink") && (
        <g className="dealer-blush">
          <rect x={3} y={5.6} width={1.4} height={0.7} rx={0.3} />
          <rect x={11.6} y={5.6} width={1.4} height={0.7} rx={0.3} />
        </g>
      )}
      {mood === "surprised" && <rect className="dealer-mouth" x={7.4} y={6} width={1.2} height={1.2} rx={0.5} />}
      <path className="dealer-tie" d="M6.4 7.1 L8 7.8 L9.6 7.1 L9.6 8.7 L8 8 L6.4 8.7 Z" shapeRendering="geometricPrecision" />
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
        aria-label="发牌员 Claude，点一下发下一张牌"
      >
        <DealerSprite mood={mood} />
      </button>
    </div>
  );
}
