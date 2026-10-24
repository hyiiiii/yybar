// 设置 · 通用 ·「模型价格」（对应 Mac `ModelPriceRows`）：列出本地用量里出现过的 Codex / Claude Code / Antigravity 模型，
// 每格美元 / 百万 Token，预填当前生效价格（自定义 > 内置）；回车或离开输入框即保存，和内置价格相同视为恢复默认。
// 保存后历史费用按新价格重算。Grok 的费用取自日志，改价格不影响它，不列。

import { useEffect, useState } from "react";
import { api } from "../../shared/api";
import { Icon, ServiceLogo } from "../../shared/design";
import { tr } from "../../shared/l10n";
import { normalizeModel, pricedApps } from "../../shared/pricing";
import { ALL_APPS, type ModelPrice, type StateSnapshot, type UsageApp, type UsageBucket } from "../../shared/types";

interface Model {
  key: string;
  app: UsageApp;
  name: string;
  builtIn: ModelPrice | undefined;
}

export function ModelPrices({ state, buckets }: { state: StateSnapshot; buckets: UsageBucket[] }) {
  const byKey = new Map<string, Model>();
  for (const b of buckets) {
    if (!pricedApps.includes(b.app) || !b.model || b.model.startsWith("<") || b.model === "unknown") continue;
    const key = normalizeModel(b.model);
    if (!byKey.has(key)) byKey.set(key, { key, app: b.app, name: b.model, builtIn: state.prices.builtin[key] });
  }
  const models = [...byKey.values()].sort((a, b) =>
    a.app !== b.app ? ALL_APPS.indexOf(a.app) - ALL_APPS.indexOf(b.app) : a.name.localeCompare(b.name, undefined, { numeric: true }),
  );
  return (
    <div>
      <div className="price-row price-head">
        <span className="price-name">{tr("Model", "模型")}</span>
        <span className="price-field">{tr("Input", "输入")}</span>
        <span className="price-field">{tr("Output", "输出")}</span>
        <span className="price-field">{tr("Cache read", "缓存读取")}</span>
        <span className="price-field">{tr("Cache write", "缓存写入")}</span>
        <span className="price-reset" />
      </div>
      {models.length === 0 && (
        <>
          <div className="divider" />
          <div className="placeholder" style={{ height: 52 }}>
            {tr("No models in the local usage yet", "本地用量里还没有模型")}
          </div>
        </>
      )}
      {models.map((m) => (
        <div key={m.key}>
          <div className="divider" />
          <PriceRow model={m} custom={state.prices.custom[m.key]} />
        </div>
      ))}
    </div>
  );
}

const fmt = (n: number) => String(Number(n.toFixed(6)));

function PriceRow({ model, custom }: { model: Model; custom: ModelPrice | undefined }) {
  const effective = custom ?? model.builtIn;
  const initial = () => (effective ? [effective.input, effective.output, effective.cacheRead, effective.cacheCreation].map(fmt) : ["", "", "", ""]);
  const [fields, setFields] = useState<string[]>(initial);
  useEffect(() => setFields(initial()), [JSON.stringify(effective)]); // eslint-disable-line react-hooks/exhaustive-deps

  /** 全空 = 清除自定义；和内置价格相同 = 恢复默认；否则保存为自定义（空格按 0）。有格子不是数字时整行恢复原值。 */
  const commit = () => {
    const parsed = fields.map((t) => {
      const v = t.trim().replace("$", "");
      if (!v) return null;
      const n = Number(v);
      return isFinite(n) && n >= 0 ? n : NaN;
    });
    if (parsed.some((n) => Number.isNaN(n))) {
      setFields(initial());
      return;
    }
    let next: ModelPrice | null;
    if (parsed.every((n) => n == null)) next = null;
    else {
      const p = { input: parsed[0] ?? 0, output: parsed[1] ?? 0, cacheRead: parsed[2] ?? 0, cacheCreation: parsed[3] ?? 0 };
      const b = model.builtIn;
      next = b && b.input === p.input && b.output === p.output && b.cacheRead === p.cacheRead && b.cacheCreation === p.cacheCreation ? null : p;
    }
    if (JSON.stringify(next) !== JSON.stringify(custom ?? null)) api.setCustomPrice(model.key, next);
  };

  return (
    <div className="price-row">
      <span className="price-name">
        <ServiceLogo app={model.app} size={13} />
        <span className="ellipsis" title={model.name}>
          {model.name}
        </span>
        {custom ? (
          <span className="pill-tag" style={{ color: "var(--accent)", background: "var(--accent-soft)" }}>
            {tr("Custom", "自定义")}
          </span>
        ) : model.builtIn ? null : (
          <span className="pill-tag" style={{ color: "var(--sys-orange)", background: "color-mix(in srgb, var(--sys-orange) 12%, transparent)" }}>
            {tr("No price", "未定价")}
          </span>
        )}
      </span>
      {fields.map((f, i) => (
        <input
          key={i}
          className="price-field price-input num"
          value={f}
          placeholder="—"
          onChange={(e) => setFields(fields.map((x, j) => (j === i ? e.target.value : x)))}
          onBlur={commit}
          onKeyDown={(e) => e.key === "Enter" && (e.currentTarget as HTMLInputElement).blur()}
        />
      ))}
      <span className="price-reset">
        {custom && (
          <button className="icon-button" title={model.builtIn ? tr("Restore built-in price", "恢复内置价格") : tr("Clear", "清除")} onClick={() => api.setCustomPrice(model.key, null)}>
            <Icon name="undo" size={13} />
          </button>
        )}
      </span>
    </div>
  );
}
