// 商场里卖的牌背和牌面。牌背跟着人走，同桌的人都看得到；牌面只改自己屏幕上的样子。
// 样式在 src/client/styles.css 里按 id 写（.back-<id>、.face-<id>）。

export type CosmeticKind = "back" | "face";

export interface Cosmetic {
  id: string;
  kind: CosmeticKind;
  name: string;
  blurb: string;
  /** 价格（筹码）；0 是默认款，人人都有 */
  price: number;
}

export const DEFAULT_BACK = "classic";
export const DEFAULT_FACE = "classic";

export const COSMETICS: Cosmetic[] = [
  { id: "classic", kind: "back", name: "经典红", blurb: "单车牌的红色细格纹，默认款。", price: 0 },
  { id: "navy", kind: "back", name: "海军蓝", blurb: "同样的花纹，换成深蓝。", price: 3_000 },
  { id: "jade", kind: "back", name: "翡翠", blurb: "绿色斜纹，像赌场的台呢。", price: 5_000 },
  { id: "terracotta", kind: "back", name: "陶土星芒", blurb: "Claude 的陶土色，正中一颗星芒。", price: 8_000 },
  { id: "midnight", kind: "back", name: "午夜金", blurb: "黑底金线，摊牌前先唬住人。", price: 12_000 },
  { id: "neon", kind: "back", name: "霓虹", blurb: "紫粉渐变加网格，酒吧灯光下最显眼。", price: 20_000 },
  { id: "classic", kind: "face", name: "亮面四色", blurb: "白色亮面，四种花色四种颜色，默认款。", price: 0 },
  { id: "ink", kind: "face", name: "水墨", blurb: "只用黑色，干干净净。", price: 3_000 },
  { id: "vintage", kind: "face", name: "复古", blurb: "米黄旧纸，颜色压暗一点。", price: 6_000 },
  { id: "night", kind: "face", name: "夜间", blurb: "深色牌面，夜里打不刺眼。", price: 8_000 },
  { id: "gold", kind: "face", name: "鎏金", blurb: "金边金字，赢了更好看。", price: 15_000 },
];

export function findCosmetic(kind: CosmeticKind, id: string): Cosmetic | undefined {
  return COSMETICS.find((c) => c.kind === kind && c.id === id);
}
