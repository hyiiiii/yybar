// 「总花费」旁边的小问号：点开看服务端的模型价格表。上传的花费按这张表和 token 数算，不用 App 报的。
import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { api } from "./api";
import { useT } from "./i18n";
import type { ModelPrice } from "../shared/pricing";

const VENDORS: { id: ModelPrice["vendor"]; label: string }[] = [
  { id: "anthropic", label: "Claude" },
  { id: "openai", label: "OpenAI · Codex" },
  { id: "google", label: "Gemini · Antigravity" },
  { id: "xai", label: "Grok" },
];

/** 美元 / 百万 token，去掉多余的 0；没有这一项写横线 */
const fmtPrice = (n: number) => (n ? `$${+n.toFixed(4)}` : "—");

export function PriceHelp() {
  const t = useT();
  const [open, setOpen] = useState(false);
  return (
    <>
      <button className="stat-help" onClick={() => setOpen(true)} aria-label={t("花费怎么算", "How spend is priced")} title={t("花费怎么算", "How spend is priced")}>
        ?
      </button>
      {/* 挂到 body 上：页面切换的滑动动画会让里面的 position: fixed 跟着页面走，不在窗口正中 */}
      {open && createPortal(<PriceTable onClose={() => setOpen(false)} />, document.body)}
    </>
  );
}

function PriceTable({ onClose }: { onClose: () => void }) {
  const t = useT();
  const [prices, setPrices] = useState<ModelPrice[] | null>(null);
  const [error, setError] = useState(false);
  useEffect(() => {
    api<{ prices: ModelPrice[] }>("/api/prices").then((r) => setPrices(r.prices), () => setError(true));
    const esc = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    addEventListener("keydown", esc);
    return () => removeEventListener("keydown", esc);
  }, []);
  return (
    <div className="modal-back" onClick={onClose}>
      <div className="modal price-modal" role="dialog" aria-modal="true" aria-label={t("模型价格", "Model prices")} onClick={(e) => e.stopPropagation()}>
        <button className="modal-close" onClick={onClose} aria-label={t("关闭", "Close")}>×</button>
        <h2>{t("模型价格", "Model prices")}</h2>
        <ul className="price-notes">
          <li>{t("花费由服务器按下表的单价和上传的 token 数计算，App 里改的价格不算数。$1 = 1 筹码。", "Spend is priced by the server from these rates and the uploaded token counts — prices edited in the app don't count. $1 = 1 chip.")}</li>
          <li>{t("Grok 按 xAI 账单里的实际花费，但不超过下表的价格。", "Grok uses the actual xAI bill, capped at the rates below.")}</li>
          <li>{t("表里没有的模型、Grok Bot（只有合计 token）和 Gemini（只有回答次数）不计花费。", "Models not listed, Grok Bot (total tokens only) and Gemini (answer counts only) cost nothing.")}</li>
        </ul>
        {error && <p className="error">{t("价格表没加载出来，稍后再试。", "Couldn't load the price table — try again later.")}</p>}
        {!prices && !error && <p className="muted">{t("加载中…", "Loading…")}</p>}
        {prices && (
          <div className="table-scroll">
            <table className="table price-table">
              <thead>
                <tr>
                  <th>{t("模型", "Model")}</th>
                  <th className="num">{t("输入", "Input")}</th>
                  <th className="num">{t("输出", "Output")}</th>
                  <th className="num">{t("缓存读取", "Cache read")}</th>
                  <th className="num">{t("缓存写入", "Cache write")}</th>
                </tr>
              </thead>
              {VENDORS.map((v) => {
                const rows = prices.filter((p) => p.vendor === v.id).sort((a, b) => b.model.localeCompare(a.model, "en", { numeric: true }));
                if (!rows.length) return null;
                return (
                  <tbody key={v.id}>
                    <tr className="price-group">
                      <th colSpan={5}>{v.label}</th>
                    </tr>
                    {rows.map((p) => (
                      <tr key={p.model}>
                        <td>
                          {p.model.endsWith("*") ? t(`所有 ${v.label} 模型`, `All ${v.label} models`) : p.model}
                          {!!p.billed && <small className="price-cap">{t("上限", "cap")}</small>}
                        </td>
                        <td className="num">{fmtPrice(p.input)}</td>
                        <td className="num">{fmtPrice(p.output)}</td>
                        <td className="num">{fmtPrice(p.cache_read)}</td>
                        <td className="num">{fmtPrice(p.cache_write)}</td>
                      </tr>
                    ))}
                  </tbody>
                );
              })}
            </table>
          </div>
        )}
        <p className="price-unit muted">{t("单位：美元 / 百万 token", "USD per million tokens")}</p>
      </div>
    </div>
  );
}
