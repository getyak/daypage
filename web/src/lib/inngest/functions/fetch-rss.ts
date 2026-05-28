import { inngest } from "@/lib/inngest/client";
import { db } from "@/lib/db/client";
import { ingest_sources, memos } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { sendEvent } from "@/lib/inngest/client";
import { decryptConfig } from "@/lib/secret-crypto";

// Lightweight RSS/Atom item parser — no external XML library required.
// Extracts <item> or <entry> blocks, then pulls title, link, and description.

interface RssItem {
  title: string;
  link: string;
  description: string;
  pubDate: string | null;
}

function extractTagContent(xml: string, tag: string): string {
  const re = new RegExp(`<${tag}[^>]*>([\\s\\S]*?)<\\/${tag}>`, "i");
  const m = re.exec(xml);
  if (!m) return "";
  // Strip CDATA wrapper if present
  return m[1].replace(/<!\[CDATA\[([\s\S]*?)]]>/i, "$1").trim();
}

function extractAttr(xml: string, tag: string, attr: string): string {
  const re = new RegExp(`<${tag}[^>]*\\s${attr}="([^"]*)"`, "i");
  const m = re.exec(xml);
  return m?.[1] ?? "";
}

function parseRssItems(xml: string): RssItem[] {
  const items: RssItem[] = [];

  // Match <item>…</item> (RSS 2.0) or <entry>…</entry> (Atom)
  const blockRe = /<(?:item|entry)([\s>][\s\S]*?)<\/(?:item|entry)>/gi;
  let match: RegExpExecArray | null;

  while ((match = blockRe.exec(xml)) !== null) {
    const block = match[0];

    const title = extractTagContent(block, "title") || "(no title)";

    // Atom uses <link href="…"/> or <link>…</link>; RSS uses <link>…</link>
    let link = extractTagContent(block, "link");
    if (!link) link = extractAttr(block, "link", "href");

    const description =
      extractTagContent(block, "description") ||
      extractTagContent(block, "summary") ||
      extractTagContent(block, "content") ||
      "";

    const pubDate =
      extractTagContent(block, "pubDate") ||
      extractTagContent(block, "published") ||
      extractTagContent(block, "updated") ||
      null;

    if (link) {
      items.push({ title, link, description, pubDate });
    }
  }

  return items;
}

// ── Inngest function ──────────────────────────────────────────────────────────

export const fetchRss = inngest.createFunction(
  {
    id: "fetch-rss",
    name: "Fetch RSS Feeds",
    // Retry only once for network failures; stale feeds are not critical
    retries: 1,
  },
  // Run every 30 minutes
  { cron: "*/30 * * * *" },
  async ({ step }) => {
    // Load all enabled RSS ingest sources
    const sources = await step.run("load-rss-sources", async () => {
      return db
        .select()
        .from(ingest_sources)
        .where(
          and(
            eq(ingest_sources.source_type, "rss"),
            eq(ingest_sources.enabled, true)
          )
        );
    });

    if (sources.length === 0) {
      return { processed: 0, created: 0 };
    }

    let totalCreated = 0;

    for (const source of sources) {
      // config may be encrypted (envelope) or legacy plaintext — decryptConfig
      // handles both transparently.
      const config = decryptConfig(source.config);
      const feedUrl = typeof config.url === "string" ? config.url : null;
      if (!feedUrl) continue;

      const result = await step.run(`fetch-feed-${source.id}`, async () => {
        let xml: string;
        try {
          const resp = await fetch(feedUrl, {
            headers: { "User-Agent": "DayPage/1.0 RSS Reader" },
            signal: AbortSignal.timeout(15_000),
          });
          if (!resp.ok) {
            console.warn(`[fetch-rss] ${feedUrl} returned ${resp.status}`);
            return { created: 0 };
          }
          xml = await resp.text();
        } catch (err) {
          console.warn(`[fetch-rss] fetch error for ${feedUrl}: ${String(err)}`);
          return { created: 0 };
        }

        const items = parseRssItems(xml);
        let created = 0;

        for (const item of items) {
          // Deduplicate by idempotency_key = source_id:link
          const idempotencyKey = `rss:${source.id}:${item.link}`;

          const body = [
            item.title,
            item.link,
            item.description ? `\n${item.description.slice(0, 500)}` : "",
          ]
            .filter(Boolean)
            .join("\n");

          try {
            // Insert only if idempotency key not already used
            const existing = await db
              .select({ id: memos.id })
              .from(memos)
              .where(
                and(
                  eq(memos.user_id, source.user_id),
                  eq(memos.idempotency_key, idempotencyKey)
                )
              )
              .limit(1);

            if (existing.length > 0) continue;

            const [memo] = await db
              .insert(memos)
              .values({
                user_id: source.user_id,
                type: "url",
                body,
                origin: "api",
                source_url: item.link,
                idempotency_key: idempotencyKey,
                source: "rss",
                device: source.name,
                created_at: item.pubDate ? new Date(item.pubDate) : undefined,
              })
              .returning({ id: memos.id });

            if (memo) {
              await sendEvent({ name: "memo/created", data: { memo_id: memo.id } });
              created++;
            }
          } catch (err) {
            console.warn(
              `[fetch-rss] failed to insert item ${item.link}: ${String(err)}`
            );
          }
        }

        return { created };
      });

      totalCreated += result.created;
    }

    return { processed: sources.length, created: totalCreated };
  }
);
