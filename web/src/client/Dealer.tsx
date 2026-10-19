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

/** Claude 风格的像素小家伙，当发牌员。 */
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
    </svg>
  );
}

/** 闲着时随机做的小动作，对应 styles.css 里的 .act-* 动画 */
const ACTS = ["look-l", "look-r", "wave", "shuffle", "jump", "sway", "peek", "stretch"] as const;

/** 说一句话停留多久 */
const SAY_MS = 4500;

/**
 * 发牌员：平时不说话，会眨眼、上下晃，隔一会儿做个小动作（东张西望、招手、洗牌、蹦一下…）。
 * say 换了就冒个气泡说一句（例如登录后的问候），过一会儿自己消失。
 * stage 由外部控制（0 翻牌前 … 4 摊牌），每推进一条街换个表情；点一下会蹦一下。
 */
export function Dealer({ stage, say, onPoke }: { stage: number; say?: { text: string; key: number } | null; onPoke?: () => void }) {
  const [mood, setMood] = useState<Mood>("idle");
  const [bubble, setBubble] = useState<{ text: string; leaving: boolean } | null>(null);
  const [act, setAct] = useState<(typeof ACTS)[number] | "">("");
  const [hop, setHop] = useState(0);
  const base = useRef<Mood>("idle");

  // 定时眨眼、做小动作；长时间没人理就犯困
  useEffect(() => {
    let alive = true;
    let lastPoke = Date.now();
    const timers: ReturnType<typeof setTimeout>[] = [];
    const later = (fn: () => void, ms: number) => timers.push(setTimeout(() => alive && fn(), ms));
    const tick = () => {
      if (Date.now() - lastPoke > 40_000 && base.current === "idle") setMood("sleepy");
      else if (Math.random() < 0.55) {
        const next = ACTS[Math.floor(Math.random() * ACTS.length)];
        setAct(next);
        if (next === "peek") setMood("surprised");
        if (next === "wave") setMood("happy");
        later(() => {
          setAct("");
          setMood(base.current);
        }, 1400);
      } else if (base.current === "idle" || base.current === "focus") {
        setMood("blink");
        later(() => setMood(base.current), 140);
      }
      later(tick, 2400 + Math.random() * 2600);
    };
    later(tick, 1800);
    const wake = () => (lastPoke = Date.now());
    addEventListener("pointerdown", wake);
    return () => {
      alive = false;
      timers.forEach(clearTimeout);
      removeEventListener("pointerdown", wake);
    };
  }, []);

  // 每推进一条街换一次表情
  useEffect(() => {
    const moods: Mood[] = ["idle", "focus", "happy", "surprised", "wink"];
    base.current = moods[stage] ?? "idle";
    setMood(base.current);
    if (stage === 0 || stage === 4) {
      const t = setTimeout(() => {
        base.current = "idle";
        setMood("idle");
      }, 1600);
      return () => clearTimeout(t);
    }
  }, [stage]);

  useEffect(() => {
    if (!say) return;
    setBubble({ text: say.text, leaving: false });
    setMood("happy");
    setAct("wave");
    const t1 = setTimeout(() => {
      setAct("");
      setMood(base.current);
    }, 1400);
    const t2 = setTimeout(() => setBubble((b) => b && { ...b, leaving: true }), SAY_MS);
    const t3 = setTimeout(() => setBubble(null), SAY_MS + 600);
    return () => [t1, t2, t3].forEach(clearTimeout);
  }, [say?.key]);

  const poke = () => {
    setHop((h) => h + 1);
    setMood("happy");
    setTimeout(() => setMood(base.current), 900);
    onPoke?.();
  };

  return (
    <div className={`dealer${act ? ` act-${act}` : ""}`}>
      {bubble && (
        <div className={`bubble${bubble.leaving ? " bubble-bye" : ""}`} role="status">
          {bubble.text}
        </div>
      )}
      <button
        className={`dealer-btn${hop % 2 ? " hop-a" : hop ? " hop-b" : ""}`}
        onClick={poke}
        onPointerEnter={() => base.current === "idle" && setMood("happy")}
        onPointerLeave={() => setMood(base.current)}
        aria-label="发牌员 Claude"
      >
        <DealerSprite mood={mood} />
      </button>
    </div>
  );
}

/** 表情里眼睛以外的小装饰：眼泪、爱心、冒火、墨镜、问号、z */
const EMOTE_MOOD: Record<string, Mood> = {
  happy: "happy", wow: "surprised", wink: "wink", sleepy: "sleepy",
  angry: "focus", cry: "blink", love: "happy", cool: "idle", think: "focus",
};

/** 表情：Claude 像素小人换个表情，头顶或脸上加点小装饰。 */
export function EmoteSprite({ id, size = 40 }: { id: string; size?: number }) {
  const mood = EMOTE_MOOD[id] ?? "idle";
  return (
    <svg className={`emote-sprite emote-${id}`} viewBox="-1 -5 18 18" width={size} height={size} shapeRendering="crispEdges" aria-hidden>
      <g className="dealer-body">
        <rect x={2} y={1} width={12} height={8} />
        <rect x={0} y={4} width={2} height={2} />
        <rect x={14} y={4} width={2} height={2} />
      </g>
      <g className="dealer-legs">
        <rect x={3} y={9} width={1} height={3} />
        <rect x={5} y={9} width={1} height={3} />
        <rect x={10} y={9} width={1} height={3} />
        <rect x={12} y={9} width={1} height={3} />
      </g>
      {id === "cool" ? (
        <g className="emote-shades">
          <rect x={3.4} y={3.2} width={3.6} height={1.8} rx={0.3} />
          <rect x={9} y={3.2} width={3.6} height={1.8} rx={0.3} />
          <rect x={6.8} y={3.6} width={2.4} height={0.5} />
        </g>
      ) : id === "angry" ? (
        <g className="dealer-eyes">
          <path d="M4.2 3.4 L6 4.3 M11.8 3.4 L10 4.3" stroke="currentColor" strokeWidth={0.6} strokeLinecap="round" />
          <rect x={4.6} y={4.3} width={1} height={1} />
          <rect x={10.4} y={4.3} width={1} height={1} />
        </g>
      ) : (
        <Eyes mood={mood} />
      )}
      {(mood === "happy" || mood === "wink") && (
        <g className="dealer-blush">
          <rect x={3} y={5.6} width={1.4} height={0.7} rx={0.3} />
          <rect x={11.6} y={5.6} width={1.4} height={0.7} rx={0.3} />
        </g>
      )}
      {id === "wow" && <rect className="dealer-mouth" x={7.4} y={6} width={1.2} height={1.2} rx={0.5} />}
      {id === "cry" && (
        <g className="emote-tears">
          <rect x={4.8} y={5} width={0.7} height={2.6} rx={0.3} />
          <rect x={10.6} y={5} width={0.7} height={2.6} rx={0.3} />
        </g>
      )}
      {id === "love" && <path className="emote-heart" d="M8 -0.6 C8 -2.4 5.6 -2.6 5.6 -0.9 C5.6 0.4 7.2 1.2 8 2 C8.8 1.2 10.4 0.4 10.4 -0.9 C10.4 -2.6 8 -2.4 8 -0.6Z" />}
      {id === "angry" && (
        <g className="emote-steam">
          <rect x={3} y={-2.6} width={1.2} height={1.2} />
          <rect x={4.2} y={-3.8} width={1.2} height={1.2} />
          <rect x={11.8} y={-2.6} width={1.2} height={1.2} />
          <rect x={10.6} y={-3.8} width={1.2} height={1.2} />
        </g>
      )}
      {id === "think" && <text className="emote-mark" x={12.5} y={-0.5} fontSize={4.5}>?</text>}
      {id === "sleepy" && <text className="emote-mark" x={12} y={-0.5} fontSize={3.6}>z</text>}
    </svg>
  );
}
