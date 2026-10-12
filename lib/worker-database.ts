import 'server-only';
import { createRequire } from 'node:module';

type QueryResult<T> = { rows: T[] };
type PgClient = {
  query<T = Record<string, unknown>>(sql: string, values?: unknown[]): Promise<QueryResult<T>>;
  end(): Promise<void>;
};

/**
 * Server-side database access only. Never expose NEON_DATABASE_URL in client code.
 * The connection is short lived so serverless invocations release their sockets.
 */
export async function withWorkerDatabase<T>(
  action: (db: PgClient) => Promise<T>,
): Promise<T> {
  const connectionString = process.env.NEON_DATABASE_URL;
  if (!connectionString) throw new Error('NEON_DATABASE_URL is missing');
  const require = createRequire(import.meta.url);
  const { Client } = require('pg') as {
    Client: new (options: Record<string, unknown>) => PgClient & { connect(): Promise<void> };
  };
  const db = new Client({
    connectionString,
    connectionTimeoutMillis: 5000,
    query_timeout: 12000,
    application_name: 'whatsapp-reminder-pro-worker',
  });
  await db.connect();
  try {
    return await action(db);
  } finally {
    await db.end();
  }
}
