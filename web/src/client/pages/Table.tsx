import { useState } from "react";
import { Link, useParams } from "react-router";
import { fmtInt } from "../api";
import { FeltTable, LoginButton, type Seat } from "../components";
import { TABLES } from "../tables";
import { useMe } from "../useMe";

/** 牌桌页。德州逻辑还没接上，先摆一手示例牌，按钮只给出提示。 */
export function TablePage() {
  const { id } = useParams();
  const table = TABLES.find((t) => t.id === id) ?? TABLES[0];
  const { me } = useMe();
  const [note, setNote] = useState<string | null>(null);
  const [raise, setRaise] = useState(table.blinds[1] * 3);
  const bb = table.blinds[1];

  const seats: Seat[] = [
    { login: me?.user?.login ?? "guest", you: true, stack: Math.min(me?.points?.balance ?? table.minBuyIn, table.minBuyIn * 5), cards: [{ rank: "A", suit: "claude" }, { rank: "Q", suit: "claude" }] },
    { login: table.bots ? "bot-赌神" : "nightowl", stack: table.minBuyIn * 3, bet: bb, state: "跟注" },
    { login: table.bots ? "bot-紧凶" : "token-burner", stack: table.minBuyIn * 2, state: "弃牌" },
    table.seated > 3 ? { login: table.bots ? "bot-松鱼" : "vibe-coder", stack: table.minBuyIn * 4, bet: bb * 3, state: "加注", dealer: true, cards: ["back", "back"] } : {},
    table.seated > 4 ? { login: table.bots ? "bot-跟注站" : "mia", stack: table.minBuyIn * 2.4, state: "思考中…", cards: ["back", "back"] } : {},
    {},
  ];

  const act = (what: string) => setNote(`预览版还不能真的${what}，牌桌逻辑正在开发。`);

  return (
    <div className="table-page">
      <div className="table-top">
        <Link to="/" className="muted">← 回大厅</Link>
        <h1>{table.name}</h1>
        <span className="muted">盲注 {fmtInt(table.blinds[0])} / {fmtInt(table.blinds[1])} · 最低带入 {fmtInt(table.minBuyIn)}</span>
      </div>

      <FeltTable
        seats={seats}
        pot={bb * 6.5}
        board={[{ rank: "K", suit: "claude" }, { rank: "7", suit: "gemini" }, { rank: "J", suit: "claude" }, "back", "back"]}
        onEmptySeat={() => act("换座")}
      />

      {me?.user ? (
        <div className="actions" role="group" aria-label="出牌">
          <button className="btn btn-ghost" onClick={() => act("弃牌")}>弃牌</button>
          <button className="btn btn-ghost" onClick={() => act("跟注")}>跟注 {fmtInt(bb * 3)}</button>
          <label className="raise">
            <input
              id="raise-amount"
              type="range"
              min={bb * 6}
              max={bb * 60}
              step={bb}
              value={raise}
              onChange={(e) => setRaise(Number(e.target.value))}
            />
            <button className="btn" onClick={() => act("加注")}>加注到 {fmtInt(Math.max(raise, bb * 6))}</button>
          </label>
        </div>
      ) : (
        <div className="actions">
          <LoginButton label="登录后入座" />
        </div>
      )}
      {note && <p className="note" role="status">{note}</p>}
      <p className="muted small center-text">你手里是 Claude 同花色的 A、Q，公共牌已经有两张 Claude。</p>
    </div>
  );
}
