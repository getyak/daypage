import { createHash } from "crypto";
import { pgSql } from "./db.js";

let cachedUserId: string | null | undefined = undefined;

/**
 * Reads DAYPAGE_API_KEY from env, hashes it, and looks up the user_id.
 * Result is cached for the lifetime of the process.
 */
export async function getAuthenticatedUserId(): Promise<string | null> {
  if (cachedUserId !== undefined) return cachedUserId;

  const rawKey = process.env.DAYPAGE_API_KEY?.trim();
  if (!rawKey) {
    cachedUserId = null;
    return null;
  }

  const keyHash = createHash("sha256").update(rawKey).digest("hex");
  const now = new Date();

  const rows = await pgSql<Array<{ user_id: string }>>`
    SELECT user_id
    FROM api_keys
    WHERE key_hash = ${keyHash}
      AND (expires_at IS NULL OR expires_at > ${now})
    LIMIT 1
  `;

  cachedUserId = rows[0]?.user_id ?? null;
  return cachedUserId;
}
