import { useEffect, useState } from "react";
import { api, fmtInt } from "../api";
import { LoginButton, PlayingCard } from "../components";
import { EmoteSprite } from "../Dealer";
import { EyeIcon, RunoutIcon, TimeIcon } from "../icons";
import { pick, tr, useLang, useT } from "../i18n";
import { notifyMeChanged, useMe } from "../useMe";
import type { Cosmetic, CosmeticKind, Item, ItemId } from "../../shared/cosmetics";

type Owned = Cosmetic & { owned: boolean };
type Stock = Item & { qty: number };
type ShopResponse = { cosmetics: Owned[]; items: Stock[]; equipped: { back: string; face: string } | null };

const ITEM_ICON: Record<ItemId, () => React.JSX.Element> = { timecard: TimeIcon, peek: EyeIcon, runout: RunoutIcon };

/** 商品预览：牌背摆两张背面，牌面摆一张 A 一张 K，表情放大一点 */
function Preview({ item }: { item: Owned }) {
  if (item.kind === "back") {
    return (
      <div className="shop-preview">
        <PlayingCard card="back" back={item.id} />
        <PlayingCard card="back" back={item.id} />
      </div>
    );
  }
  if (item.kind === "face") {
    return (
      <div className="shop-preview">
        <PlayingCard card={{ rank: "A", suit: "claude" }} face={item.id} />
        <PlayingCard card={{ rank: "K", suit: "gpt" }} face={item.id} />
      </div>
    );
  }
  return (
    <div className="shop-preview shop-preview-emote">
      <EmoteSprite id={item.id} size={64} />
    </div>
  );
}

/** 商场：用筹码买牌背、牌面、表情（永久）和道具（按个数），买过的牌背牌面随时换。 */
export function ShopPage() {
  const { me } = useMe();
  const lang = useLang();
  const t = useT();
  const [shop, setShop] = useState<ShopResponse | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const signedIn = !!me?.user;
  const balance = me?.points?.balance ?? 0;

  const sections: { kind: CosmeticKind; title: string; hint: string }[] = [
    { kind: "back", title: t("牌背", "Card backs"), hint: t("你的暗牌和桌面上的背面牌都换成这一款，同桌的人看得到。", "Your face-down cards and the board backs use this. Everyone at the table sees it.") },
    { kind: "face", title: t("牌面", "Card faces"), hint: t("你的牌翻开时用这一款，同桌的人看得到；公共牌在你屏幕上也用它。", "Your cards show this face when revealed — everyone sees it. The board uses it on your screen.") },
    { kind: "emote", title: t("表情", "Emotes"), hint: t("坐在桌上时，点手牌下面的笑脸发给全桌。", "At the table, tap the smiley under your cards to send one.") },
  ];

  const load = () => api<ShopResponse>("/api/shop").then(setShop, (e: Error) => setNote(tr(e.message, lang)));
  useEffect(() => {
    load();
  }, [signedIn]);

  const run = async (key: string, fn: () => Promise<unknown>, done: string) => {
    setBusy(key);
    setNote(null);
    try {
      await fn();
      setNote(done);
      notifyMeChanged();
      await load();
    } catch (e) {
      setNote(tr((e as Error).message, lang));
    } finally {
      setBusy(null);
    }
  };

  const buyCosmetic = (item: Owned, alsoEquip: boolean) =>
    run(
      `${item.kind}:${item.id}`,
      async () => {
        if (!item.owned) await api("/api/shop/buy", { method: "POST", json: { kind: item.kind, id: item.id } });
        if (alsoEquip) await api("/api/shop/equip", { method: "POST", json: { kind: item.kind, id: item.id } });
      },
      !item.owned
        ? alsoEquip
          ? t(`买下了「${item.name.zh}」，已经换上`, `Bought ${item.name.en} and put it on`)
          : t(`买下了「${item.name.zh}」`, `Bought ${item.name.en}`)
        : t(`换上了「${item.name.zh}」`, `Now using ${item.name.en}`),
    );

  const buyItem = (item: Stock) =>
    run(
      `item:${item.id}`,
      () => api("/api/shop/buy", { method: "POST", json: { kind: "item", id: item.id } }),
      t(`买了一张「${item.name.zh}」`, `Bought one ${item.name.en}`),
    );

  const price = (n: number) => <span className="chip-count">{fmtInt(n)}</span>;

  return (
    <section className="section shop">
      {!signedIn && me && (
        <div className="card-box notice shop-login">
          <span>{t("登录后用筹码买东西。", "Sign in to spend your chips here.")}</span>
          <LoginButton small next="/shop" label={t("用 GitHub 登录", "Sign in with GitHub")} />
        </div>
      )}
      {note && <p className="note shop-note" role="status">{note}</p>}

      {sections.map((sec) => (
        <div key={sec.kind} className="shop-section">
          <div className="shop-head">
            <h2>{sec.title}</h2>
            <p className="muted small">{sec.hint}</p>
          </div>
          <div className={`shop-grid${sec.kind === "emote" ? " shop-grid-small" : ""}`}>
            {(shop?.cosmetics ?? []).filter((x) => x.kind === sec.kind).map((item) => {
              const equipped = item.kind !== "emote" && shop?.equipped?.[item.kind] === item.id;
              const key = `${item.kind}:${item.id}`;
              return (
                <article key={key} className={`shop-item${equipped ? " equipped" : ""}`}>
                  <Preview item={item} />
                  <div className="shop-info">
                    <h3>{pick(item.name, lang)}</h3>
                    <p>{pick(item.blurb, lang)}</p>
                  </div>
                  <div className="shop-buy">
                    {item.price > 0 && !item.owned ? price(item.price) : <span className="muted small">{item.price ? t("已拥有", "Owned") : t("免费", "Free")}</span>}
                    {item.kind === "emote" ? (
                      !item.owned && (
                        <button className="btn btn-small" disabled={!signedIn || !!busy || balance < item.price} onClick={() => buyCosmetic(item, false)}>
                          {balance < item.price && signedIn ? t("筹码不够", "Can't afford") : t("买下", "Buy")}
                        </button>
                      )
                    ) : equipped ? (
                      <button className="btn btn-small btn-ghost" disabled>{t("使用中", "In use")}</button>
                    ) : item.owned ? (
                      <button className="btn btn-small btn-ghost" disabled={!!busy} onClick={() => buyCosmetic(item, true)}>{t("换上", "Use")}</button>
                    ) : (
                      <button className="btn btn-small" disabled={!signedIn || !!busy || balance < item.price} onClick={() => buyCosmetic(item, true)}>
                        {balance < item.price && signedIn ? t("筹码不够", "Can't afford") : t("买下", "Buy")}
                      </button>
                    )}
                  </div>
                </article>
              );
            })}
          </div>
        </div>
      ))}

      <div className="shop-section">
        <div className="shop-head">
          <h2>{t("道具", "Items")}</h2>
          <p className="muted small">{t("按个数买，坐在桌上时在手牌下面用。", "Bought one at a time; use them from under your cards at the table.")}</p>
        </div>
        <div className="shop-grid">
          {(shop?.items ?? []).map((item) => {
            const Icon = ITEM_ICON[item.id];
            return (
              <article key={item.id} className="shop-item">
                <div className="shop-preview shop-preview-item">
                  <Icon />
                </div>
                <div className="shop-info">
                  <h3>{pick(item.name, lang)}</h3>
                  <p>{pick(item.blurb, lang)}</p>
                </div>
                <div className="shop-buy">
                  <span className="shop-price">
                    {price(item.price)}
                    {signedIn && <span className="muted small">{t(`有 ${item.qty} 张`, `Have ${item.qty}`)}</span>}
                  </span>
                  <button className="btn btn-small" disabled={!signedIn || !!busy || balance < item.price} onClick={() => buyItem(item)}>
                    {balance < item.price && signedIn ? t("筹码不够", "Can't afford") : t("买一张", "Buy one")}
                  </button>
                </div>
              </article>
            );
          })}
        </div>
      </div>
    </section>
  );
}
