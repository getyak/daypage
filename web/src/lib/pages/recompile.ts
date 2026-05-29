import "server-only";
import { db } from "@/lib/db/client";
import {
  pages,
  page_links,
  page_sources,
  memos,
  change_log,
} from "@/lib/db/schema";
import { eq, and, sql } from "drizzle-orm";
import { llm, ProviderError } from "@/lib/ai";

// US-030 — 自定义编译视角（MVP）
// Re-compile a single EXISTING page through a custom perspective prompt, on
// demand from the domain/wiki UI. We re-synthesize the page body from the same
// source material (linked source pages + linked memos) but re-framed by the
// user's perspective, so the result is observably different from the default.

const MAX_SOURCES = 24;
const BODY_SLICE = 600;

type RecompileResult = {
  ok: true;
  slug: string;
  title: string;
  body_md: string;
};

// Gather the source material that backs this page: source/concept pages that
// link INTO it (weave-graph creates source → concept links) plus any memos
// attached via page_sources (daily pages, compiled pages). Falls back to the
// page's own current body so a page with no recorded provenance can still be
// re-framed.
async function gatherSources(
  userId: string,
  pageId: string,
  currentBody: string | null,
  currentTitle: string
): Promise<{ title: string; body_md: string | null }[]> {
  const out: { title: string; body_md: string | null }[] = [];

  try {
    const linked = await db
      .select({ title: pages.title, body_md: pages.body_md })
      .from(page_links)
      .innerJoin(pages, eq(page_links.from_page_id, pages.id))
      .where(
        and(
          eq(page_links.to_page_id, pageId),
          eq(page_links.user_id, userId)
        )
      )
      .limit(MAX_SOURCES);
    for (const r of linked) out.push({ title: r.title, body_md: r.body_md });
  } catch {
    // non-fatal
  }

  try {
    const memoRows = await db
      .select({ body: memos.body, created_at: memos.created_at })
      .from(page_sources)
      .innerJoin(memos, eq(page_sources.memo_id, memos.id))
      .where(
        and(eq(page_sources.page_id, pageId), eq(memos.user_id, userId))
      )
      .limit(MAX_SOURCES);
    for (const r of memoRows) {
      const time = r.created_at.toISOString().slice(0, 16).replace("T", " ");
      out.push({ title: `Memo · ${time}`, body_md: r.body });
    }
  } catch {
    // non-fatal
  }

  // Fallback: re-frame the page's own body if no provenance is recorded.
  if (out.length === 0 && currentBody?.trim()) {
    out.push({ title: currentTitle, body_md: currentBody });
  }

  return out.slice(0, MAX_SOURCES);
}

function buildPerspectivePrompt(
  title: string,
  sources: { title: string; body_md: string | null }[],
  perspectivePrompt: string
): string {
  const list = sources
    .map(
      (s, i) =>
        `[${i + 1}] ${s.title}\n${(s.body_md ?? "").trim().slice(0, BODY_SLICE)}`
    )
    .join("\n\n");

  return `You are a knowledge weaver re-compiling an existing page from a personal notes app. Re-write the page body using ONLY the source material below, but framed through the user's custom perspective.

Existing page title: "${title}"

Source material:
${list}

## Custom perspective (highest priority)
Re-frame the SAME material through this perspective — let it shape the framing, emphasis, section ordering, and voice — while never inventing facts not present in the sources:

"${perspectivePrompt.slice(0, 800)}"

Respond with JSON only, no markdown fences:
{"title":"...","body_md":"## ...\\n..."}`;
}

function parseResult(raw: string): { title: string; body_md: string } {
  const stripped = raw
    .replace(/^```json\s*/i, "")
    .replace(/^```\s*/i, "")
    .replace(/```\s*$/i, "")
    .trim();
  const parsed = JSON.parse(stripped) as Record<string, unknown>;
  if (typeof parsed.body_md !== "string") {
    throw new Error("Invalid recompile result shape from LLM");
  }
  const title = typeof parsed.title === "string" ? parsed.title : "";
  return { title, body_md: parsed.body_md };
}

export async function recompilePageWithPerspective(
  userId: string,
  slug: string,
  perspectivePrompt: string
): Promise<RecompileResult | { ok: false; reason: "not_found" }> {
  const [page] = await db
    .select({
      id: pages.id,
      slug: pages.slug,
      title: pages.title,
      body_md: pages.body_md,
    })
    .from(pages)
    .where(and(eq(pages.slug, slug), eq(pages.user_id, userId)))
    .limit(1);

  if (!page) return { ok: false, reason: "not_found" };

  const sources = await gatherSources(
    userId,
    page.id,
    page.body_md,
    page.title
  );

  const promptContent = buildPerspectivePrompt(
    page.title,
    sources,
    perspectivePrompt
  );

  // A higher temperature than the default compile (0.3/0.4) so the perspective
  // produces an observable shift from the default-view output.
  const res = await llm.chat(
    [
      {
        role: "system",
        content:
          "You are a knowledge weaver. Respond with valid JSON only — no prose, no markdown fences.",
      },
      { role: "user", content: promptContent },
    ],
    { jsonMode: true, temperature: 0.6, maxTokens: 1024 }
  );

  let result: { title: string; body_md: string };
  try {
    result = parseResult(res.content);
  } catch (err) {
    const message =
      err instanceof ProviderError ? `${err.code}: ${err.message}` : String(err);
    throw new Error(`recompile parse failed: ${message}`);
  }

  const nextTitle = result.title.trim() || page.title;

  const [updated] = await db
    .update(pages)
    .set({
      title: nextTitle,
      body_md: result.body_md,
      last_compiled_at: new Date(),
      updated_at: new Date(),
      version: sql`${pages.version} + 1`,
    })
    .where(and(eq(pages.id, page.id), eq(pages.user_id, userId)))
    .returning({ id: pages.id });

  if (!updated) return { ok: false, reason: "not_found" };

  // Provenance: record the custom-perspective recompile in change_log.
  try {
    await db.insert(change_log).values({
      user_id: userId,
      action_kind: "update_page",
      target_type: "page",
      target_id: page.id,
      before: { title: page.title },
      after: { title: nextTitle },
      reason: `Recompiled with custom perspective: "${perspectivePrompt.slice(0, 160)}"`,
      performed_by: "user",
      agent_action_id: "recompile-perspective",
    });
  } catch (err) {
    console.warn(`[recompile] change_log insert non-fatal — ${String(err)}`);
  }

  return {
    ok: true,
    slug: page.slug,
    title: nextTitle,
    body_md: result.body_md,
  };
}
