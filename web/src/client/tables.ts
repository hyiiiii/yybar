// 牌桌配置。德州逻辑上线前先由前端展示；之后改由服务端下发实时人数。
export interface TableInfo {
  id: string;
  name: string;
  blurb: string;
  blinds: [number, number];
  minBuyIn: number;
  seats: number;
  seated: number;
  bots?: boolean;
}

export const TABLES: TableInfo[] = [
  { id: "practice", name: "机器人练习桌", blurb: "和机器人打，随时开局，适合熟悉规则。", blinds: [5, 10], minBuyIn: 200, seats: 6, seated: 5, bots: true },
  { id: "rookie", name: "新手桌", blurb: "盲注小，输了也不心疼。", blinds: [10, 20], minBuyIn: 400, seats: 6, seated: 4 },
  { id: "regulars", name: "常客桌", blurb: "每天都来的那几位。", blinds: [50, 100], minBuyIn: 2_000, seats: 6, seated: 5 },
  { id: "highroller", name: "高额桌", blurb: "Opus 用户的地盘。", blinds: [200, 400], minBuyIn: 8_000, seats: 6, seated: 2 },
];
