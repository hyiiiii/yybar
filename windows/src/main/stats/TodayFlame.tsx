// 概览「今天」旁的小火苗（对应 Mac `TodayFlame`）：今天全部 Token 落在热力图哪一档（1~4），
// 档位越高颜色越深、烧得越旺，3 档起冒火星；今天还没用时只有一个灰色小炭点。动画全用 CSS，减弱动态效果时静止。

import { compactToken } from "../../shared/format";
import { tr } from "../../shared/l10n";

export function TodayFlame({ level, tokens }: { level: number; tokens: number }) {
  const amount = compactToken(tokens);
  const help =
    level === 0
      ? tr("No tokens yet today", "今天还没有用量")
      : level === 4
        ? tr(`Today: ${amount} tokens · level 4 (above 75% of days)`, `今天全部 Token ${amount} · 第 4 档（超过 75% 的日子）`)
        : tr(`Today: ${amount} tokens · level ${level} of 4`, `今天全部 Token ${amount} · 第 ${level} 档（共 4 档）`);
  if (level === 0) {
    return (
      <span className="today-flame ember" title={help}>
        <span className="ember-dot" />
      </span>
    );
  }
  return (
    <span className={`today-flame level-${level}`} title={help}>
      <span className="flame-glyph">🔥</span>
      {level >= 3 && (
        <>
          <span className="spark s1" />
          <span className="spark s2" />
          {level === 4 && <span className="spark s3" />}
        </>
      )}
    </span>
  );
}
