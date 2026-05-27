import { createHash } from "crypto";
import { eq, and, or, isNull, gt } from "drizzle-orm";
import { db } from "@/lib/db/client";
import { api_keys } from "@/lib/db/schema";

export interface ApiAuthResult {
  userId: string;
  scopes: string[];
}

export async function authenticateApiKey(
  request: Request
): Promise<ApiAuthResult | null> {
  const authHeader = request.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) return null;

  const rawKey = authHeader.slice(7).trim();
  if (!rawKey) return null;

  const keyHash = createHash("sha256").update(rawKey).digest("hex");

  const now = new Date();
  const rows = await db
    .select()
    .from(api_keys)
    .where(
      and(
        eq(api_keys.key_hash, keyHash),
        or(isNull(api_keys.expires_at), gt(api_keys.expires_at, now))
      )
    )
    .limit(1);

  const key = rows[0];
  if (!key) return null;

  // Update last_used_at without awaiting — fire and forget
  db.update(api_keys)
    .set({ last_used_at: now })
    .where(eq(api_keys.id, key.id))
    .catch(() => undefined);

  const scopes = Array.isArray(key.scopes) ? (key.scopes as string[]) : ["read"];

  return { userId: key.user_id, scopes };
}
