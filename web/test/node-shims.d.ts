// 测试里用到的两个 Node 自带模块的最小类型（项目没装 @types/node）。
declare module "node:fs" {
  export function readFileSync(path: string, encoding: "utf8"): string;
  export function readdirSync(path: string): string[];
}
declare module "node:sqlite" {
  export class DatabaseSync {
    constructor(path: string);
    exec(sql: string): void;
    prepare(sql: string): { all(...args: unknown[]): unknown[]; get(...args: unknown[]): unknown; run(...args: unknown[]): unknown };
  }
}
