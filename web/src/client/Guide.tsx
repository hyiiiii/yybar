// 德州扑克入门：左上角的小书打开。Clawd（像素 Claude）一页一页讲，配图用我们默认的牌。
import { useEffect, useState, type ReactNode } from "react";
import { PlayingCard, type CardSpec } from "./components";
import { DealerSprite } from "./Dealer";
import { useT } from "./i18n";
import type { Suit } from "./suits";

const c = (rank: string, suit: Suit): CardSpec => ({ rank, suit });

/** 一排小牌 */
function Row({ cards, dim = [] }: { cards: CardSpec[]; dim?: number[] }) {
  return (
    <div className="guide-cards">
      {cards.map((x, i) => (
        <PlayingCard key={i} card={x} extra={dim.includes(i) ? "guide-dim" : ""} />
      ))}
    </div>
  );
}

/** 牌型从大到小，每种配一手例子；dim 是不算进牌型的踢脚 */
const RANKINGS: { zh: string; en: string; cards: CardSpec[]; dim?: number[] }[] = [
  { zh: "皇家同花顺", en: "Royal flush", cards: [c("A", "claude"), c("K", "claude"), c("Q", "claude"), c("J", "claude"), c("10", "claude")] },
  { zh: "同花顺", en: "Straight flush", cards: [c("9", "gemini"), c("8", "gemini"), c("7", "gemini"), c("6", "gemini"), c("5", "gemini")] },
  { zh: "四条", en: "Four of a kind", cards: [c("K", "gpt"), c("K", "claude"), c("K", "gemini"), c("K", "grok"), c("3", "claude")], dim: [4] },
  { zh: "葫芦", en: "Full house", cards: [c("Q", "gpt"), c("Q", "claude"), c("Q", "grok"), c("7", "gemini"), c("7", "gpt")] },
  { zh: "同花", en: "Flush", cards: [c("A", "grok"), c("J", "grok"), c("8", "grok"), c("5", "grok"), c("2", "grok")] },
  { zh: "顺子", en: "Straight", cards: [c("10", "gpt"), c("9", "claude"), c("8", "grok"), c("7", "gemini"), c("6", "claude")] },
  { zh: "三条", en: "Three of a kind", cards: [c("8", "claude"), c("8", "gemini"), c("8", "grok"), c("K", "gpt"), c("2", "claude")], dim: [3, 4] },
  { zh: "两对", en: "Two pair", cards: [c("J", "gpt"), c("J", "gemini"), c("4", "claude"), c("4", "grok"), c("A", "gemini")], dim: [4] },
  { zh: "一对", en: "One pair", cards: [c("10", "claude"), c("10", "grok"), c("K", "gemini"), c("6", "gpt"), c("3", "claude")], dim: [2, 3, 4] },
  { zh: "高牌", en: "High card", cards: [c("A", "gemini"), c("Q", "gpt"), c("9", "grok"), c("6", "claude"), c("3", "gemini")], dim: [1, 2, 3, 4] },
];

export function Guide({ onClose }: { onClose: () => void }) {
  const t = useT();
  const [page, setPage] = useState(0);

  const pages: { say: string; body: ReactNode }[] = [
    {
      say: t("我是 Clawd，这桌的发牌员。德州很简单：两张自己的牌，加五张大家共用的牌，挑最好的五张比大小。", "I'm Clawd, your dealer. Hold'em is simple: two cards of your own plus five shared ones — make the best five."),
      body: (
        <>
          <p className="guide-label">{t("你的两张底牌", "Your two hole cards")}</p>
          <Row cards={[c("A", "claude"), c("K", "claude")]} />
          <p className="guide-label">{t("五张公共牌（大家都能用）", "Five community cards (everyone shares)")}</p>
          <Row cards={[c("Q", "claude"), c("J", "claude"), c("10", "claude"), c("4", "grok"), c("2", "gpt")]} />
          <p className="guide-note">{t("这一手凑出了皇家同花顺，最大的牌型。", "That's a royal flush — the best hand there is.")}</p>
        </>
      ),
    },
    {
      say: t("我们的牌用四个 AI 当花色：GPT 是黑桃，Claude 是红心，Gemini 是方块，Grok 是梅花。", "Our suits are four AIs: GPT is spades, Claude hearts, Gemini diamonds, Grok clubs."),
      body: (
        <>
          <Row cards={[c("A", "gpt"), c("A", "claude"), c("A", "gemini"), c("A", "grok")]} />
          <p className="guide-note">{t("花色本身不分大小，只在凑同花时有用。", "Suits have no rank — they only matter for flushes.")}</p>
        </>
      ),
    },
    {
      say: t("每手开始前，庄家（D）左边两位先放盲注：小盲一份、大盲两份。庄家每手顺时针轮一位。", "Before each hand, the two seats left of the dealer (D) post blinds: small blind and big blind. The button moves clockwise every hand."),
      body: (
        <div className="guide-blinds">
          {["BTN", "SB", "BB", "UTG"].map((p, i) => (
            <div key={p} className="guide-seat">
              <span className="seat-disc guide-disc">{p}</span>
              {i === 0 && <span className="guide-d">D</span>}
              <small>{i === 1 ? t("小盲 $5", "SB $5") : i === 2 ? t("大盲 $10", "BB $10") : i === 3 ? t("先说话", "Acts first") : t("庄家", "Dealer")}</small>
            </div>
          ))}
        </div>
      ),
    },
    {
      say: t("一手牌有四轮下注：先发两张底牌，然后翻牌三张、转牌一张、河牌一张，每发一次大家说一轮话。", "There are four betting rounds: hole cards, then the flop (3), the turn (1) and the river (1)."),
      body: (
        <div className="guide-streets">
          {[
            [t("翻牌前", "Preflop"), 0],
            [t("翻牌", "Flop"), 3],
            [t("转牌", "Turn"), 4],
            [t("河牌", "River"), 5],
          ].map(([name, n]) => (
            <div key={name as string} className="guide-street">
              <small>{name}</small>
              <Row cards={[c("8", "gemini"), c("6", "claude"), c("Q", "grok"), c("8", "gpt"), c("A", "gpt")].map((x, i) => (i < (n as number) ? x : "back"))} />
            </div>
          ))}
        </div>
      ),
    },
    {
      say: t("轮到你时有 15 秒，能做这几件事：", "On your turn you have 15 seconds to:"),
      body: (
        <ul className="guide-actions">
          <li><b>{t("弃牌", "Fold")}</b>{t("：不玩这手了，已经下的筹码留在底池。", " — give up the hand; chips already in stay in the pot.")}</li>
          <li><b>{t("过牌", "Check")}</b>{t("：没人下注时，什么都不放，轮给下一个人。", " — when nobody has bet, pass without putting chips in.")}</li>
          <li><b>{t("跟注", "Call")}</b>{t("：补到和最大的下注一样多。", " — match the biggest bet so far.")}</li>
          <li><b>{t("加注", "Raise")}</b>{t("：下得更多，别人要跟就得补齐。", " — bet more; others must match it to stay in.")}</li>
          <li><b>{t("全下", "All-in")}</b>{t("：把剩下的筹码全推进去。", " — push every chip you have.")}</li>
        </ul>
      ),
    },
    {
      say: t("牌型从大到小是这样排的。灰掉的牌是踢脚：牌型一样大时，再一张张比它们。", "Hands rank like this, best first. Faded cards are kickers — they break ties between equal hands."),
      body: (
        <ol className="guide-ranks">
          {RANKINGS.map((r) => (
            <li key={r.en}>
              <span className="guide-rank-name">{t(r.zh, r.en)}</span>
              <Row cards={r.cards} dim={r.dim} />
            </li>
          ))}
        </ol>
      ),
    },
    {
      say: t("最后没弃牌的人亮牌比大小，一样大就平分。全下的人只能赢他跟得起的那一份，多出来的叫边池，留给其他人比。", "At showdown the remaining players compare hands; ties split. An all-in player can only win what they matched — the rest becomes a side pot for the others."),
      body: (
        <>
          <p className="guide-label">{t("公共牌", "Board")}</p>
          <Row cards={[c("8", "claude"), c("6", "gemini"), c("Q", "grok"), c("8", "grok"), c("A", "gpt")]} />
          <div className="guide-showdown">
            <div>
              <Row cards={[c("9", "gemini"), c("8", "gpt")]} />
              <small>{t("三条 8：赢下它跟得起的主池", "Trip 8s: wins the main pot it covered")}</small>
            </div>
            <div>
              <Row cards={[c("J", "claude"), c("K", "claude")]} />
              <Row cards={[c("9", "claude"), c("K", "gpt")]} />
              <small>{t("都是一对 8 带 A K Q：一样大，平分边池", "Both pair of 8s with A K Q: equal, split the side pot")}</small>
            </div>
          </div>
        </>
      ),
    },
  ];

  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
      if (e.key === "ArrowRight") setPage((p) => Math.min(pages.length - 1, p + 1));
      if (e.key === "ArrowLeft") setPage((p) => Math.max(0, p - 1));
    };
    addEventListener("keydown", key);
    return () => removeEventListener("keydown", key);
  }, []);

  const cur = pages[page];
  return (
    <div className="modal-back" onClick={onClose}>
      <div className="modal guide" role="dialog" aria-modal="true" aria-label={t("德州扑克入门", "Hold'em basics")} onClick={(e) => e.stopPropagation()}>
        <button className="modal-close" onClick={onClose} aria-label={t("关闭", "Close")}>×</button>
        <h2>{t("德州扑克入门", "Hold'em basics")}</h2>
        <div className="guide-host">
          <DealerSprite mood={page === pages.length - 1 ? "happy" : page % 2 ? "wink" : "idle"} />
          <p className="guide-say" key={page}>{cur.say}</p>
        </div>
        <div className="guide-body" key={`b${page}`}>{cur.body}</div>
        <div className="guide-nav">
          <button className="btn btn-ghost btn-small" disabled={page === 0} onClick={() => setPage(page - 1)}>{t("上一页", "Back")}</button>
          <span className="guide-dots">
            {pages.map((_, i) => (
              <i key={i} className={i === page ? "on" : ""} onClick={() => setPage(i)} />
            ))}
          </span>
          {page < pages.length - 1 ? (
            <button className="btn btn-small" onClick={() => setPage(page + 1)}>{t("下一页", "Next")}</button>
          ) : (
            <button className="btn btn-small" onClick={onClose}>{t("去打一手", "Let's play")}</button>
          )}
        </div>
      </div>
    </div>
  );
}
