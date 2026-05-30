import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";
import * as schema from "./schema";

const connectionString = process.env.DATABASE_URL;
if (!connectionString) {
  throw new Error("DATABASE_URL is not set");
}

// In dev, Next.js re-executes this module on every HMR hot-reload. A bare
// `postgres(connectionString)` would open a NEW connection pool each time
// without closing the old one, leaking idle connections until Postgres hits
// max_connections and rejects new ones with FATAL 53300 ("too many clients").
// Cache the underlying client on globalThis so hot-reloads reuse one pool.
//
// `max` is bounded so a single server instance can never monopolize the
// database's connection budget (the local Supabase Postgres also hosts
// PostgREST / pg_cron / pg_net, which need headroom).
const globalForDb = globalThis as unknown as {
  __dpQueryClient?: ReturnType<typeof postgres>;
};

const queryClient =
  globalForDb.__dpQueryClient ??
  postgres(connectionString, {
    max: process.env.NODE_ENV === "production" ? 10 : 5,
    idle_timeout: 20, // close idle connections after 20s instead of holding them
    max_lifetime: 60 * 30, // recycle connections every 30 min
  });

if (process.env.NODE_ENV !== "production") {
  globalForDb.__dpQueryClient = queryClient;
}

export const db = drizzle(queryClient, { schema });
