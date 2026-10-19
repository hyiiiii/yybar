import { useEffect, useState } from "react";
import { api, fmtInt } from "../api";
import { LoginButton, PlayingCard } from "../components";
import { notifyMeChanged, useMe } from "../useMe";
import type { Cosmetic, CosmeticKind } from "../../shared/cosmetics";

type Item = Cosmetic & { owned: boolean };
type ShopResponse = { items: Item[]; equipped: { back: string; face: string } | null };

const SECTIONS: { kind: CosmeticKind; title: string; hint: string }[] = [
  { kind: "back", title: "牌背", hint: "桌上的牌背和你手里的牌背都换成这一款，同桌的人看得到。" },
  { kind: "face", title: "牌面", hint: "只改你自己屏幕上看到的牌面，别人看不到。" },
];

/** 商品预览：牌背摆两张背面，牌面摆一张 A 一张 K */
function Preview({ item }: { item: Item }) {
  if (item.kind === "back") {
    return (
      <div className="shop-preview">
        <PlayingCard card="back" back={item.id} />
        <PlayingCard card="back" back={item.id} />
      </div>
    );
  }
  return (
    <div className={`shop-preview face-${item.id}`}>
      <PlayingCard card={{ rank: "A", suit: "claude" }} />
      <PlayingCard card={{ rank: "K", suit: "gpt" }} />
    </div>
  );
}

/** 商场：用筹码买牌背、牌面，买过的随时换。 */
export function ShopPage() {
  const { me } = useMe();
  const [shop, setShop] = useState<ShopResponse | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const signedIn = !!me?.user;
  const balance = me?.points?.balance ?? 0;

  const load = () => api<ShopResponse>("/api/shop").then(setShop, (e: Error) => setNote(e.message));
  useEffect(() => {
    load();
  }, [signedIn]);

  const run = async (item: Item, action: "buy" | "equip") => {
    setBusy(`${item.kind}:${item.id}`);
    setNote(null);
    try {
      if (action === "buy") await api("/api/shop/buy", { method: "POST", json: { kind: item.kind, id: item.id } });
      await api("/api/shop/equip", { method: "POST", json: { kind: item.kind, id: item.id } });
      setNote(action === "buy" ? `买下了「${item.name}」，已经换上` : `换上了「${item.name}」`);
      notifyMeChanged();
      await load();
    } catch (e) {
      setNote((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  return (
    <section className="section shop">
      {!signedIn && me && (
        <div className="card-box notice shop-login">
          <span>登录后用筹码买牌背和牌面。</span>
          <LoginButton small next="/shop" />
        </div>
      )}
      {note && <p className="note shop-note" role="status">{note}</p>}
      {SECTIONS.map((sec) => (
        <div key={sec.kind} className="shop-section">
          <div className="shop-head">
            <h2>{sec.title}</h2>
            <p className="muted small">{sec.hint}</p>
          </div>
          <div className="shop-grid">
            {(shop?.items ?? []).filter((x) => x.kind === sec.kind).map((item) => {
              const equipped = shop?.equipped?.[item.kind] === item.id;
              const key = `${item.kind}:${item.id}`;
              return (
                <article key={key} className={`shop-item${equipped ? " equipped" : ""}`}>
                  <Preview item={item} />
                  <div className="shop-info">
                    <h3>{item.name}</h3>
                    <p>{item.blurb}</p>
                  </div>
                  <div className="shop-buy">
                    {item.price > 0 && !item.owned ? <span className="chip-count">{fmtInt(item.price)}</span> : <span className="muted small">{item.price ? "已拥有" : "免费"}</span>}
                    {equipped ? (
                      <button className="btn btn-small btn-ghost" disabled>使用中</button>
                    ) : item.owned ? (
                      <button className="btn btn-small btn-ghost" disabled={!!busy} onClick={() => run(item, "equip")}>换上</button>
                    ) : (
                      <button className="btn btn-small" disabled={!signedIn || !!busy || balance < item.price} onClick={() => run(item, "buy")}>
                        {balance < item.price && signedIn ? "筹码不够" : "买下"}
                      </button>
                    )}
                  </div>
                </article>
              );
            })}
          </div>
        </div>
      ))}
    </section>
  );
}
