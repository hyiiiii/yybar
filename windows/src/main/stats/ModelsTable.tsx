// 统计 · 模型明细（对应 Mac `modelsTable`）：可排序表格（模型 / 输入 / 输出 / 缓存读取 / 缓存写入 / 费用），
// 未知定价显示 —；全部 Token（含缓存）最多的模型后面有一个跳动的小火苗（只有一个模型时不显示）。
// Codex / Grok 的日志不单独记缓存写入（字段恒为 0），显示 — 而不是 0。

import { useEffect, useRef, useState } from "react";
import { HotFlame, Icon, ServiceLogo } from "../../shared/design";
import { cost, tableToken } from "../../shared/format";
import { tr } from "../../shared/l10n";
import { hasDisplayableCost } from "../../shared/pricing";
import type { StateSnapshot, UsageApp } from "../../shared/types";
import { usePersisted } from "../uiState";
import type { Bounds, StatsIndex } from "./data";
import { Placeholder } from "./Panel";

type SortKey = "model" | "input" | "output" | "cacheRead" | "cacheWrite" | "cost";

interface Row {
  id: string;
  app: UsageApp;
  model: string;
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  cost: number;
  priced: boolean;
}

export function ModelsTable({ state, index, apps, bounds }: { state: StateSnapshot; index: StatsIndex | null; apps: UsageApp[]; bounds: Bounds }) {
  const [sortKey, setSortKey] = usePersisted<SortKey>("models.sort", "cost");
  const [ascending, setAscending] = usePersisted("models.ascending", false);
  const [fade, setFade] = useState(false);
  const filterKey = `${bounds.from}|${bounds.to}|${apps.join()}`;
  const firstRun = useRef(true);
  useEffect(() => {
    if (firstRun.current) {
      firstRun.current = false;
      return;
    }
    setFade(true);
    const t = setTimeout(() => setFade(false), 30);
    return () => clearTimeout(t);
  }, [filterKey]);

  const byKey = new Map<string, Row>();
  for (const b of index?.buckets ?? []) {
    if (!apps.includes(b.app) || b.day < bounds.from || b.day >= bounds.to) continue;
    const id = `${b.app}|${b.model}`;
    let r = byKey.get(id);
    if (!r) byKey.set(id, (r = { id, app: b.app, model: b.model, input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, priced: false }));
    r.input += b.inputTokens;
    r.output += b.outputTokens;
    r.cacheRead += b.cacheReadTokens;
    r.cacheWrite += b.cacheCreationTokens;
    r.cost += b.costUSD;
  }
  const rows = [...byKey.values()].map((r) => ({ ...r, priced: hasDisplayableCost(state, r.app, r.model, r.cost) }));
  const value = (r: Row): number | string => {
    switch (sortKey) {
      case "model":
        return r.model;
      case "input":
        return r.input;
      case "output":
        return r.output;
      case "cacheRead":
        return r.cacheRead;
      case "cacheWrite":
        return r.cacheWrite;
      case "cost":
        return r.priced ? r.cost : -1;
    }
  };
  rows.sort((a, b) => {
    const va = value(a);
    const vb = value(b);
    const c = typeof va === "string" ? va.localeCompare(vb as string, undefined, { numeric: true }) : (va as number) - (vb as number);
    return ascending ? c : -c;
  });
  const total = (r: Row) => r.input + r.output + r.cacheRead + r.cacheWrite;
  const hottest = rows.length > 1 ? rows.filter((r) => total(r) > 0).reduce<Row | null>((m, r) => (!m || total(r) > total(m) ? r : m), null)?.id : null;

  const header = (title: string, key: SortKey, align: "left" | "right" = "right") => (
    <th
      style={{ textAlign: align }}
      className={sortKey === key ? "sorted" : ""}
      onClick={() => {
        if (sortKey === key) setAscending(!ascending);
        else {
          setSortKey(key);
          setAscending(key === "model");
        }
      }}
    >
      {title}
      {sortKey === key && (
        <span className="sort-arrow">
          <Icon name={ascending ? "chevronUp" : "chevronDown"} size={9} />
        </span>
      )}
    </th>
  );

  return (
    <div className="panel models-table">
      <table>
        <thead>
          <tr>
            {header(tr("Model", "模型"), "model", "left")}
            {header(tr("Input", "输入"), "input")}
            {header(tr("Output", "输出"), "output")}
            {header(tr("Cache reads", "缓存读取"), "cacheRead")}
            {header(tr("Cache writes", "缓存写入"), "cacheWrite")}
            {header(tr("Cost", "费用"), "cost")}
          </tr>
        </thead>
        <tbody className={fade ? "fading" : "faded-in"}>
          {rows.map((r) => (
            <tr key={r.id}>
              <td>
                <div className="model-cell">
                  <ServiceLogo app={r.app} size={13} />
                  <span className="ellipsis" title={r.model}>
                    {r.model}
                  </span>
                  {r.id === hottest && <HotFlame title={tr("Most tokens in this range", "这段时间用量最多")} />}
                </div>
              </td>
              <td className="num">{tableToken(r.input)}</td>
              <td className="num">{tableToken(r.output)}</td>
              <td className="num">{tableToken(r.cacheRead)}</td>
              <td className="num">
                {r.app !== "claude" && r.cacheWrite === 0 ? (
                  <span className="secondary" title={tr("Not reported in this service's logs", "该服务的日志不单独记录缓存写入")}>
                    —
                  </span>
                ) : (
                  tableToken(r.cacheWrite)
                )}
              </td>
              <td className="num" style={{ fontWeight: 500 }}>
                {r.priced ? cost(r.cost) : "—"}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      {rows.length === 0 && <Placeholder height={80} message={tr("No usage in this range", "这段时间没有用量")} />}
    </div>
  );
}
