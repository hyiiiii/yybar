import { useEffect, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
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

  /** 刚买到的那件，卡片闪一下 */
  const [flash, setFlash] = useState<string | null>(null);
  /** 购买确认弹窗；done 是买成功后停留的那一下 */
  const [confirm, setConfirm] = useState<{ key: string; name: string; price: number; preview: ReactNode; buy: () => Promise<boolean>; done?: boolean } | null>(null);

  const run = async (key: string, fn: () => Promise<unknown>, done: string) => {
    setBusy(key);
    setNote(null);
    try {
      await fn();
      setNote(done);
      setFlash(key);
      notifyMeChanged();
      await load();
      return true;
    } catch (e) {
      setNote(tr((e as Error).message, lang));
      return false;
    } finally {
      setBusy(null);
    }
  };

  /** 点「买下」先弹确认；确认后买，成功了弹窗里打个勾，过一会儿自己关掉 */
  const ask = (key: string, name: string, price: number, preview: ReactNode, buy: () => Promise<boolean>) =>
    setConfirm({ key, name, price, preview, buy });
  const confirmBuy = async () => {
    if (!confirm) return;
    const ok = await confirm.buy();
    if (!ok) return setConfirm(null);
    setConfirm((c) => c && { ...c, done: true });
    setTimeout(() => setConfirm(null), 900);
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
            {(shop?.cosmetics ?? []).filter((x) => x.kind === sec.kind).map((item, idx) => {
              const equipped = item.kind !== "emote" && shop?.equipped?.[item.kind] === item.id;
              const key = `${item.kind}:${item.id}`;
              return (
                <article
                  key={flash === key ? `${key}-flash` : key}
                  className={`shop-item${equipped ? " equipped" : ""}${flash === key ? " just-bought" : ""}`}
                  style={{ "--i": idx } as React.CSSProperties}
                >
                  <Preview item={item} />
                  <div className="shop-info">
                    <h3>{pick(item.name, lang)}</h3>
                    <p>{pick(item.blurb, lang)}</p>
                  </div>
                  <div className="shop-buy">
                    {item.price > 0 && !item.owned ? price(item.price) : <span className="muted small">{item.price ? t("已拥有", "Owned") : t("免费", "Free")}</span>}
                    {item.kind === "emote" ? (
                      !item.owned && (
                        <button className="btn btn-small" disabled={!signedIn || !!busy || balance < item.price} onClick={() => ask(key, pick(item.name, lang), item.price, <Preview item={item} />, () => buyCosmetic(item, false))}>
                          {balance < item.price && signedIn ? t("筹码不够", "Can't afford") : t("买下", "Buy")}
                        </button>
                      )
                    ) : equipped ? (
                      <button className="btn btn-small btn-ghost" disabled>{t("使用中", "In use")}</button>
                    ) : item.owned ? (
                      <button className="btn btn-small btn-ghost" disabled={!!busy} onClick={() => buyCosmetic(item, true)}>{t("换上", "Use")}</button>
                    ) : (
                      <button
                        className="btn btn-small"
                        disabled={!signedIn || !!busy || balance < item.price}
                        onClick={() => ask(key, pick(item.name, lang), item.price, <Preview item={item} />, () => buyCosmetic(item, true))}
                      >
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
              <article
                key={flash === `item:${item.id}` ? `${item.id}-flash-${item.qty}` : item.id}
                className={`shop-item${flash === `item:${item.id}` ? " just-bought" : ""}`}
              >
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
                  <button className="btn btn-small" disabled={!signedIn || !!busy || balance < item.price} onClick={() =>
                      ask(`item:${item.id}`, pick(item.name, lang), item.price, <div className="shop-preview shop-preview-item"><Icon /></div>, () => buyItem(item))
                    }>
                    {balance < item.price && signedIn ? t("筹码不够", "Can't afford") : t("买一张", "Buy one")}
                  </button>
                </div>
              </article>
            );
          })}
        </div>
      </div>
      {/* 弹窗挂到 body 上：页面切换动画的 translate 会让 fixed 定位相对页面，而不是相对整个窗口 */}
      {confirm && createPortal(
        <div className="modal-back" onClick={() => !busy && !confirm.done && setConfirm(null)}>
          <div className="modal buy-confirm" role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()}>
            {confirm.done ? (
              <div className="buy-done">
                <svg viewBox="0 0 24 24" aria-hidden><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>
                <b>{t("买到了", "Got it")}</b>
              </div>
            ) : (
              <>
                {confirm.preview}
                <h3>{t(`买下「${confirm.name}」？`, `Buy ${confirm.name}?`)}</h3>
                <p className="buy-math">
                  <span>{t("价格", "Price")}</span>
                  <b className="chip-count">{fmtInt(confirm.price)}</b>
                  <span>{t("余额", "Balance")}</span>
                  <b>
                    {fmtInt(balance)} → {fmtInt(balance - confirm.price)}
                  </b>
                </p>
                <div className="panel-row">
                  <button className="btn btn-text" disabled={!!busy} onClick={() => setConfirm(null)}>{t("再想想", "Not now")}</button>
                  <button className="btn" disabled={!!busy} onClick={confirmBuy}>{busy ? t("购买中…", "Buying…") : t("确认购买", "Buy")}</button>
                </div>
              </>
            )}
          </div>
        </div>,
        document.body,
      )}
    </section>
  );
}
