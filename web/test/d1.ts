// 测试用：Node 自带的 SQLite 跑真实的建表迁移，配一个最小的 D1 外壳（prepare / bind / all / first / run / batch）。
import { readFileSync, readdirSync } from "node:fs";
import type { DatabaseSync } from "node:sqlite";

/** 按顺序跑 migrations/ 里的迁移；upTo 给了就只跑到这个文件名为止（含） */
export function migrate(db: DatabaseSync, upTo?: string): DatabaseSync {
  for (const f of readdirSync("migrations").sort()) {
    if (upTo && f > upTo) break;
    db.exec(readFileSync(`migrations/${f}`, "utf8"));
  }
  return db;
}

/** 跑一条写语句，按 D1 的样子回 meta.changes */
const write = (db: DatabaseSync, sql: string, args: unknown[]) => ({ meta: { changes: Number((db.prepare(sql).run(...(args as never[])) as { changes: number | bigint }).changes) } });

export function fakeD1(db: DatabaseSync): D1Database {
  const statement = (sql: string, args: unknown[] = []) => ({
    sql,
    args,
    bind: (...next: unknown[]) => statement(sql, next),
    all: async () => ({ results: db.prepare(sql).all(...(args as never[])) }),
    first: async () => db.prepare(sql).get(...(args as never[])) ?? null,
    run: async () => write(db, sql, args),
  });
  return {
    prepare: (sql: string) => statement(sql),
    batch: async (stmts: { sql: string; args: unknown[] }[]) => {
      db.exec("BEGIN");
      try {
        const out = stmts.map((s) => write(db, s.sql, s.args));
        db.exec("COMMIT");
        return out;
      } catch (e) {
        db.exec("ROLLBACK");
        throw e;
      }
    },
  } as unknown as D1Database;
}
