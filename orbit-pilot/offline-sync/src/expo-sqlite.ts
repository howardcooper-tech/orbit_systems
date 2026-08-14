import type { SqliteDb } from "./types.ts";

type ExpoDb = {
  execAsync: (sql: string) => Promise<unknown>;
  getAllAsync: <T>(sql: string, params?: unknown[]) => Promise<T[]>;
  runAsync: (sql: string, params?: unknown[]) => Promise<unknown>;
};

/** Adapter for expo-sqlite. Open the DB in the Pilot app, then pass it here. */
export function createExpoSqliteAdapter(db: ExpoDb): SqliteDb {
  return {
    async exec(sql: string, params: unknown[] = []): Promise<void> {
      if (!params.length && /^(CREATE|PRAGMA)/i.test(sql.trim())) {
        await db.execAsync(sql);
        return;
      }
      await db.runAsync(sql, params);
    },
    async all<T>(sql: string, params: unknown[] = []): Promise<T[]> {
      return db.getAllAsync<T>(sql, params);
    },
  };
}
