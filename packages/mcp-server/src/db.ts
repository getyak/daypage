/**
 * DB client for MCP server — reuses web's schema, reads DATABASE_URL from env.
 * The MCP server is run as a separate process, so it gets its own connection pool.
 *
 * KNOWN ISSUE (tracked from PR #443 review, ARCH-11):
 * The MCP server SHOULD authenticate with a Personal Access Token and call the
 * DayPage REST API instead of opening a direct Postgres connection here. Direct
 * DB access widens the attack surface: any compromise of the MCP server process
 * exposes the entire database, including api_keys.key_hash and ingest_sources
 * secrets. Migrating to HTTP+PAT requires:
 *   1. Adding REST endpoints for the read paths used by tools/{search,crud}.ts
 *      (pages by slug, recent memos, page_links neighbours, annotations).
 *   2. Reusing POST /api/ingest (PAT, scope `write`) for add_memo.
 *   3. Removing db.ts and auth.ts's direct query.
 * Deferred to a separate PR because it touches every tool's data layer.
 */

import postgres from "postgres";
import { drizzle } from "drizzle-orm/postgres-js";

// We import schema types inline to avoid circular deps — the schema file lives
// in the sibling web package and is referenced by relative path from build output.
// At runtime, schema types are re-declared here to keep mcp-server self-contained.

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) {
  throw new Error("DATABASE_URL is not set");
}

const sql = postgres(DATABASE_URL, { max: 3 });
export const db = drizzle(sql);
export { sql as pgSql };
