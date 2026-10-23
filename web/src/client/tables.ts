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
  /** 连着这张桌的真人（在座的和旁观的） */
  online?: number;
  bots?: boolean;
  /** 玩家开的桌，没人了会收掉 */
  temporary?: boolean;
}

const table = (t: Omit<TableInfo, "id">): TableInfo => ({ ...t, id: String(t.no) });

// 和服务端默认的四张桌一致（migrations/0006）：#1000 机器人桌，另外三张盲注从小到大。
// 线上大厅从 /api/tables 取实时的桌和人数，这里是还没取到时和预览版用的
export const TABLES: TableInfo[] = [
  table({ no: 1000, name: "机器人桌", blurb: "三个机器人一直在打，随时坐下陪练。", blinds: [1, 2], minBuyIn: 80, seats: 6, seated: 3, online: 2, bots: true }),
  table({ no: 1001, name: "新手桌", blurb: "盲注最小，输了也不心疼。", blinds: [1, 2], minBuyIn: 80, seats: 6, seated: 2, online: 3 }),
  table({ no: 1002, name: "常客桌", blurb: "每天都来的那几位。", blinds: [2, 5], minBuyIn: 200, seats: 6, seated: 4, online: 5 }),
  table({ no: 1003, name: "高额桌", blurb: "Opus 用户的地盘。", blinds: [5, 10], minBuyIn: 400, seats: 6, seated: 5, online: 0 }),
];

/** 打开牌桌页先看到机器人桌：随时都有人在打 */
export const DEFAULT_TABLE = TABLES[0];
