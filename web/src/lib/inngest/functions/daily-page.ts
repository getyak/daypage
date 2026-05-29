import { inngest } from "@/lib/inngest/client";
import { db } from "@/lib/db/client";
import { users, memos, pages, page_sources } from "@/lib/db/schema";
import { eq, and, gte, lt, sql } from "drizzle-orm";
import { llm, ProviderError } from "@/lib/ai";
import fs from "fs";
import path from "path";

const DAILY_PAGE_PROMPT = fs.readFileSync(
  path.join(process.cwd(), "src/lib/ai/prompts/daily-page.md"),
  "utf-8"
);

type DailyPageResult = {
  title: string;
  body_md: string;
};

function buildDailyPrompt(
  date: string,
  memoTexts: { body: string; created_at: Date }[],
  perspectivePrompt?: string | null
): string {
  const memosSection = memoTexts
    .map((m, i) => {
      const time = m.created_at.toISOString().slice(11, 16); // HH:MM UTC
      return `[${i + 1}] (${time} UTC)\n${m.body}`;
    })
    .join("\n\n---\n\n");

  const base = DAILY_PAGE_PROMPT.replace("{{DATE}}", date)
    .replace("{{MEMO_COUNT}}", String(memoTexts.length))
    .replace("{{MEMOS}}", memosSection);

  // US-030: a custom perspective re-frames the same memos through the user's lens.
  // Appended after the base instructions so it takes precedence on tone/angle.
  return injectPerspective(base, perspectivePrompt);
}

// US-030: append an optional custom-perspective instruction to a compile prompt.
// Kept here (rather than inlined) so both daily-page and weave-graph share one
// observable shape; trimmed/length-capped to keep token cost predictable.
export function injectPerspective(
  prompt: string,
  perspectivePrompt?: string | null
): string {
  const p = perspectivePrompt?.trim();
  if (!p) return prompt;
  return `${prompt}\n\n## Custom perspective (highest priority)\nRe-compile the SAME source material through this perspective. Let it shape the framing, emphasis, section ordering, and voice — while still obeying the rules above and never inventing facts:\n\n"${p.slice(0, 800)}"`;
}

function parseDailyResult(raw: string): DailyPageResult {
  const stripped = raw
    .replace(/^```json\s*/i, "")
    .replace(/^```\s*/i, "")
    .replace(/```\s*$/i, "")
    .trim();

  const parsed = JSON.parse(stripped) as Record<string, unknown>;

  if (typeof parsed.title !== "string" || typeof parsed.body_md !== "string") {
    throw new Error("Invalid daily page result shape from LLM");
  }

  return { title: parsed.title, body_md: parsed.body_md };
}

// Returns the UTC date string YYYY-MM-DD for "yesterday" relative to 00:30 UTC run time
function getTargetDateString(): string {
  const now = new Date();
  // The cron runs at 00:30 UTC — process the previous calendar day
  const target = new Date(now);
  target.setUTCDate(target.getUTCDate() - 1);
  return target.toISOString().slice(0, 10); // YYYY-MM-DD
}

// ─── Inngest scheduled function ───────────────────────────────────────────────

export const dailyPage = inngest.createFunction(
  { id: "daily-page", name: "Daily Page Generator" },
  { cron: "30 0 * * *" }, // 00:30 UTC daily
  async ({ step }) => {
    const dateStr = getTargetDateString();

    // Fetch all users
    const allUsers = await step.run("fetch-users", async () => {
      return db.select({ id: users.id }).from(users);
    });

    const results: { user_id: string; status: string; slug?: string }[] = [];

    for (const user of allUsers) {
      const result = await step.run(`process-user-${user.id}`, async () => {
        return processUserDailyPage(user.id, dateStr);
      });
      results.push(result);
    }

    return { date: dateStr, processed: results.length, results };
  }
);

async function processUserDailyPage(
  userId: string,
  dateStr: string,
  perspectivePrompt?: string | null
): Promise<{ user_id: string; status: string; slug?: string }> {
  // Window: midnight to midnight UTC for the target date
  const dayStart = new Date(`${dateStr}T00:00:00.000Z`);
  const dayEnd = new Date(`${dateStr}T23:59:59.999Z`);

  const dayMemos = await db
    .select({ id: memos.id, body: memos.body, created_at: memos.created_at })
    .from(memos)
    .where(
      and(
        eq(memos.user_id, userId),
        gte(memos.created_at, dayStart),
        lt(memos.created_at, dayEnd)
      )
    )
    .orderBy(memos.created_at);

  if (dayMemos.length === 0) {
    console.log(`[daily-page] user ${userId} — no memos on ${dateStr}, skipping`);
    return { user_id: userId, status: "skipped" };
  }

  const slug = `daily/${dateStr}`;
  const promptContent = buildDailyPrompt(dateStr, dayMemos, perspectivePrompt);

  const systemPrompt =
    "You are a personal knowledge assistant. Return only valid JSON as instructed.";

  let dailyResult: DailyPageResult;

  try {
    const res = await llm.chat(
      [
        { role: "system", content: systemPrompt },
        { role: "user", content: promptContent },
      ],
      { jsonMode: true, temperature: 0.4, maxTokens: 1024 }
    );
    dailyResult = parseDailyResult(res.content);
  } catch (err: unknown) {
    // Retry once with stricter prompt
    if (err instanceof SyntaxError || err instanceof Error && err.message.startsWith("Invalid")) {
      const stricterPrompt = `${promptContent}\n\nIMPORTANT: Return ONLY the JSON object. No explanation. No markdown fences.`;
      const res2 = await llm.chat(
        [
          { role: "system", content: systemPrompt },
          { role: "user", content: stricterPrompt },
        ],
        { jsonMode: true, temperature: 0.1, maxTokens: 1024 }
      );
      dailyResult = parseDailyResult(res2.content);
    } else {
      const message =
        err instanceof ProviderError ? `${err.code}: ${err.message}` : String(err);
      console.error(`[daily-page] LLM error for user ${userId}: ${message}`);
      throw err;
    }
  }

  // Upsert the daily page (idempotent: same day overwrites existing)
  const [page] = await db
    .insert(pages)
    .values({
      user_id: userId,
      slug,
      type: "daily",
      title: dailyResult.title,
      status: "live",
      body_md: dailyResult.body_md,
      source_count: dayMemos.length,
      last_compiled_at: new Date(),
    })
    .onConflictDoUpdate({
      target: [pages.user_id, pages.slug],
      set: {
        title: dailyResult.title,
        body_md: dailyResult.body_md,
        source_count: dayMemos.length,
        last_compiled_at: new Date(),
        updated_at: new Date(),
      },
    })
    .returning({ id: pages.id });

  if (!page) {
    throw new Error(`[daily-page] Failed to upsert daily page for user ${userId}`);
  }

  // Link all memos of the day via page_sources (idempotent)
  for (const memo of dayMemos) {
    await db
      .insert(page_sources)
      .values({ page_id: page.id, memo_id: memo.id, weight: 1 })
      .onConflictDoNothing();
  }

  // Update source_count to exact count (already set above, but update in case page existed)
  await db
    .update(pages)
    .set({ source_count: sql`${pages.source_count}` })
    .where(and(eq(pages.id, page.id)));

  console.log(
    `[daily-page] user ${userId} — created/updated daily page ${slug} with ${dayMemos.length} memos`
  );

  return { user_id: userId, status: "ok", slug };
}

// US-030: re-compile a single day's daily page with a custom perspective prompt.
// Exposed for the on-demand "重新编译（自定义视角）" entry point on daily wiki pages.
export async function recompileDailyPage(
  userId: string,
  dateStr: string,
  perspectivePrompt?: string | null
): Promise<{ user_id: string; status: string; slug?: string }> {
  return processUserDailyPage(userId, dateStr, perspectivePrompt);
}
