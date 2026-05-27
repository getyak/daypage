import { NextRequest, NextResponse } from "next/server";
import { createHash, randomBytes } from "crypto";
import { eq } from "drizzle-orm";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { api_keys, users } from "@/lib/db/schema";
import { z } from "zod";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

// GET /api/keys — list keys (never return key_hash)
export async function GET() {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const rows = await db
    .select({
      id: api_keys.id,
      name: api_keys.name,
      key_prefix: api_keys.key_prefix,
      scopes: api_keys.scopes,
      last_used_at: api_keys.last_used_at,
      created_at: api_keys.created_at,
      expires_at: api_keys.expires_at,
    })
    .from(api_keys)
    .where(eq(api_keys.user_id, userId))
    .orderBy(api_keys.created_at);

  return NextResponse.json(rows);
}

const CreateKeySchema = z.object({
  name: z.string().min(1).max(100),
  scopes: z.array(z.string()).optional().default(["read"]),
  expires_at: z.string().datetime().optional(),
});

// POST /api/keys — create key, return raw key once
export async function POST(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const body: unknown = await req.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "Invalid JSON" }, { status: 400 });

  const parsed = CreateKeySchema.safeParse(body);
  if (!parsed.success) {
    return NextResponse.json(
      { error: parsed.error.issues[0]?.message ?? "Validation error" },
      { status: 400 }
    );
  }

  const { name, scopes, expires_at } = parsed.data;

  const rawKey = randomBytes(32).toString("hex"); // 64-char hex string
  const keyPrefix = rawKey.slice(0, 8);
  const keyHash = createHash("sha256").update(rawKey).digest("hex");

  const [record] = await db
    .insert(api_keys)
    .values({
      user_id: userId,
      name,
      key_hash: keyHash,
      key_prefix: keyPrefix,
      scopes,
      expires_at: expires_at ? new Date(expires_at) : null,
    })
    .returning({
      id: api_keys.id,
      name: api_keys.name,
      key_prefix: api_keys.key_prefix,
      scopes: api_keys.scopes,
      created_at: api_keys.created_at,
      expires_at: api_keys.expires_at,
    });

  return NextResponse.json({ key: rawKey, ...record }, { status: 201 });
}
