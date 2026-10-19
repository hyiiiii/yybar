// 牌桌配置。德州逻辑上线前先由前端展示；之后改由服务端下发实时人数。
export interface TableInfo {
  /** 桌号，也是路由里的 id */
  no: number;
  id: string;
  name: string;
  blurb: string;
  blinds: [number, number];
  minBuyIn: number;
  seats: number;
  seated: number;
  bots?: boolean;
  /** 玩家开的桌，没人了会收掉 */
  temporary?: boolean;
}

type Kind = Omit<TableInfo, "no" | "id" | "seated">;

const KINDS: Kind[] = [
  { name: "机器人练习桌", blurb: "和机器人打，随时开局，适合熟悉规则。", blinds: [5, 10], minBuyIn: 200, seats: 6, bots: true },
  { name: "新手桌", blurb: "盲注小，输了也不心疼。", blinds: [10, 20], minBuyIn: 400, seats: 6 },
  { name: "常客桌", blurb: "每天都来的那几位。", blinds: [50, 100], minBuyIn: 2_000, seats: 6 },
  { name: "高额桌", blurb: "Opus 用户的地盘。", blinds: [200, 400], minBuyIn: 8_000, seats: 6 },
];

// 演示用：12 张桌，桌号从 1001 起，四种盲注轮着来
const SEATED = [5, 4, 5, 2, 5, 3, 4, 1, 5, 5, 2, 3];
export const TABLES: TableInfo[] = SEATED.map((seated, i) => {
  const no = 1001 + i;
  return { ...KINDS[i % KINDS.length], no, id: String(no), seated };
});

export const DEFAULT_TABLE = TABLES[2];
