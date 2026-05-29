import "server-only";
import { db } from "@/lib/db/client";
import { user_settings } from "@/lib/db/schema";
import { eq } from "drizzle-orm";

// US-032: the "knowledge assistant persona" — a single free-form prompt the
// user sets in Settings that defines *who* their assistant is (tone, voice,
// perspective). It is stored in user_settings.settings under this key and
// injected into both the default /chat system prompt and the compile prompt so
// the same personality carries across every AI surface.
export const ASSISTANT_PERSONA_KEY = "assistant_persona";

const MAX_PERSONA_LEN = 2_000;

/**
 * Reads the user's configured knowledge-assistant persona from user_settings.
 * Returns a trimmed, length-capped string, or null when unset/blank.
 */
export async function getAssistantPersona(
  userId: string,
): Promise<string | null> {
  try {
    const rows = await db
      .select({ settings: user_settings.settings })
      .from(user_settings)
      .where(eq(user_settings.user_id, userId))
      .limit(1);

    const settings = (rows[0]?.settings ?? {}) as Record<string, unknown>;
    return sanitizePersona(settings[ASSISTANT_PERSONA_KEY]);
  } catch {
    // Persona is an enhancement — never let a settings read failure break chat
    // or compilation.
    return null;
  }
}

/** Coerces an arbitrary settings value into a usable persona string or null. */
export function sanitizePersona(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  return trimmed.slice(0, MAX_PERSONA_LEN);
}

/**
 * Wraps a persona into a system-prompt preamble. Returns "" when there is no
 * persona so callers can concatenate unconditionally.
 */
export function personaPreamble(persona: string | null): string {
  if (!persona) return "";
  return `Your persona — who you are as the user's knowledge assistant — is:\n${persona}\n\nStay in this persona's voice and perspective throughout.\n\n`;
}
