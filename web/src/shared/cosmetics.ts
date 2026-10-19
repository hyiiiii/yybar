// 商场里卖的东西：牌背、牌面、表情（买一次永久拥有）和道具（按个数买、用掉就少一个）。
// 牌背和牌面跟着人上桌，同桌的人都看得到；样式在 src/client/styles.css 里按 id 写（.back-<id>、.face-<id>）。
// 名字都是一眼看得出在玩哪副牌的梗，不是正版。

export type CosmeticKind = "back" | "face" | "emote";
export type ItemId = "timecard" | "peek" | "runout";

/** 中英两种写法 */
export interface Text {
  zh: string;
  en: string;
}

export interface Cosmetic {
  id: string;
  kind: CosmeticKind;
  name: Text;
  blurb: Text;
  /** 价格（筹码）；0 是默认款，人人都有 */
  price: number;
}

export interface Item {
  id: ItemId;
  name: Text;
  blurb: Text;
  price: number;
}

export const DEFAULT_BACK = "bicyle-red";
export const DEFAULT_FACE = "classic";

export const COSMETICS: Cosmetic[] = [
  // 牌背
  { id: "bicyle-red", kind: "back", name: { zh: "丹车·红", en: "Bicyle Red" }, blurb: { zh: "骑丹车的那副红色细格纹，默认款。", en: "The red lattice everyone rides. Default." }, price: 0 },
  { id: "bicyle-blue", kind: "back", name: { zh: "丹车·蓝", en: "Bicyle Blue" }, blurb: { zh: "同一副丹车，换成深蓝。", en: "Same Bicyle, in navy." }, price: 3_000 },
  { id: "terracotta", kind: "back", name: { zh: "陶土星芒", en: "Clawd Spark" }, blurb: { zh: "Claude 的陶土色，正中一颗星芒。", en: "Claude's terracotta with a spark in the middle." }, price: 6_000 },
  { id: "tallyhoo-red", kind: "back", name: { zh: "塔里猴·红", en: "Tally-Hoo Red" }, blurb: { zh: "一圈放射花纹，四角带小花，红色。", en: "The circle fan back, in red." }, price: 8_000 },
  { id: "tallyhoo-blue", kind: "back", name: { zh: "塔里猴·蓝", en: "Tally-Hoo Blue" }, blurb: { zh: "一圈放射花纹，四角带小花，蓝色。", en: "The circle fan back, in blue." }, price: 8_000 },
  { id: "purr", kind: "back", name: { zh: "醇黑", en: "Purr" }, blurb: { zh: "全黑加一道白框，什么花纹都不要。", en: "Solid black, one white frame, nothing else." }, price: 12_000 },
  { id: "daybrake", kind: "back", name: { zh: "潮曦", en: "Daybrake" }, blurb: { zh: "粉蓝渐变，一个大大的叉，像早上的天。", en: "Pink-to-blue with a big X, like dawn." }, price: 15_000 },
  // 牌面
  { id: "classic", kind: "face", name: { zh: "亮面四色", en: "Glossy Four-Color" }, blurb: { zh: "白色亮面，四种花色四种颜色，默认款。", en: "Glossy white, four suits in four colors. Default." }, price: 0 },
  { id: "ink", kind: "face", name: { zh: "水墨", en: "Ink" }, blurb: { zh: "只用黑色，干干净净。", en: "Black only, nothing extra." }, price: 3_000 },
  { id: "vintage", kind: "face", name: { zh: "复古", en: "Vintage" }, blurb: { zh: "米黄旧纸，颜色压暗一点。", en: "Old cream paper, muted ink." }, price: 6_000 },
  { id: "night", kind: "face", name: { zh: "夜间", en: "Night" }, blurb: { zh: "深色牌面，夜里打不刺眼。", en: "Dark faces, easy on the eyes at night." }, price: 8_000 },
  { id: "gold", kind: "face", name: { zh: "鎏金", en: "Gilded" }, blurb: { zh: "金边金字，赢了更好看。", en: "Gold edges. Looks better when you win." }, price: 15_000 },
  // 表情（Claude 像素小人）；前四个默认就有
  { id: "happy", kind: "emote", name: { zh: "开心", en: "Happy" }, blurb: { zh: "眯眼笑。", en: "All smiles." }, price: 0 },
  { id: "wow", kind: "emote", name: { zh: "惊了", en: "Wow" }, blurb: { zh: "张大嘴。", en: "Jaw drop." }, price: 0 },
  { id: "wink", kind: "emote", name: { zh: "眨眼", en: "Wink" }, blurb: { zh: "懂的都懂。", en: "You know." }, price: 0 },
  { id: "sleepy", kind: "emote", name: { zh: "困了", en: "Sleepy" }, blurb: { zh: "快点出牌。", en: "Hurry up." }, price: 0 },
  { id: "angry", kind: "emote", name: { zh: "气鼓鼓", en: "Grumpy" }, blurb: { zh: "头顶冒火。", en: "Steam coming out." }, price: 1_500 },
  { id: "cry", kind: "emote", name: { zh: "哭哭", en: "Sob" }, blurb: { zh: "被河牌打死了。", en: "Rivered again." }, price: 1_500 },
  { id: "love", kind: "emote", name: { zh: "比心", en: "Love" }, blurb: { zh: "谢谢老板。", en: "Thanks, boss." }, price: 2_000 },
  { id: "cool", kind: "emote", name: { zh: "墨镜", en: "Shades" }, blurb: { zh: "全下之后戴上。", en: "Put on after shoving." }, price: 3_000 },
  { id: "think", kind: "emote", name: { zh: "想想", en: "Hmm" }, blurb: { zh: "你是不是在偷鸡？", en: "Are you bluffing?" }, price: 2_000 },
];

/** 道具：按个数买，在牌桌上用掉就少一个 */
export const ITEMS: Item[] = [
  { id: "timecard", name: { zh: "加时卡", en: "Time Bank" }, blurb: { zh: "轮到你时用，多给 10 秒；每次行动只能用一张。", en: "+10 seconds on your turn. One per action." }, price: 500 },
  { id: "peek", name: { zh: "偷偷看", en: "Sneak Peek" }, blurb: { zh: "一手结束后，看别人没亮出来的牌。只有你看得到，但桌上会知道你用了。", en: "After a hand, see cards others never showed. Only you see them, but the table is told." }, price: 2_000 },
  { id: "runout", name: { zh: "发发看", en: "Run It Out" }, blurb: { zh: "一手提前结束时，看看还没翻出来的公共牌。只有你看得到，但桌上会知道你用了。", en: "When a hand ends early, see the board cards that never came. Only you see them, but the table is told." }, price: 1_000 },
];

export const DEFAULT_EMOTES = COSMETICS.filter((c) => c.kind === "emote" && c.price === 0).map((c) => c.id);

/** 加时卡多给的时间 */
export const TIME_CARD_MS = 10_000;

export function findCosmetic(kind: CosmeticKind, id: string): Cosmetic | undefined {
  return COSMETICS.find((c) => c.kind === kind && c.id === id);
}

export function findItem(id: string): Item | undefined {
  return ITEMS.find((x) => x.id === id);
}
