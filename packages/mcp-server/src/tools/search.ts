import type { ToolHandler, McpToolResult } from "../types.js";
import { getAuthenticatedUserId } from "../auth.js";
import { pgSql } from "../db.js";

const searchTool: ToolHandler = {
  name: "daypage_search",
  description:
    "Search DayPage memos and pages by keyword or phrase. Graph-augmented: " +
    "after matching pages, it also surfaces their one-hop neighbours from the " +
    "knowledge graph (page_links), so an agent sees the network around a hit, " +
    "not just the isolated match (OmniQuery-style retrieve-then-connect).",
  inputSchema: {
    type: "object",
    properties: {
      query: {
        type: "string",
        description: "Search query string",
      },
      limit: {
        type: "number",
        description: "Maximum number of results per category (default: 5, max: 20)",
      },
    },
    required: ["query"],
  },

  async handler(args): Promise<McpToolResult> {
    const query = typeof args.query === "string" ? args.query.trim() : "";
    if (!query) {
      return { content: [{ type: "text", text: "Error: query is required" }], isError: true };
    }

    const limitRaw = typeof args.limit === "number" ? args.limit : 5;
    const limit = Math.min(Math.max(1, limitRaw), 20);

    const userId = await getAuthenticatedUserId();
    if (!userId) {
      return { content: [{ type: "text", text: "Error: DAYPAGE_API_KEY is invalid or not set" }], isError: true };
    }

    const pattern = `%${query}%`;

    // Search memos using ILIKE on body
    const memoRows = await pgSql<Array<{
      id: string;
      body: string;
      created_at: Date;
      origin: string;
    }>>`
      SELECT id, body, created_at, origin
      FROM memos
      WHERE user_id = ${userId}
        AND body ILIKE ${pattern}
      ORDER BY created_at DESC
      LIMIT ${limit}
    `;

    // Search pages using ILIKE on title + body_md
    const pageRows = await pgSql<Array<{
      id: string;
      slug: string;
      title: string;
      type: string;
      status: string;
      body_md: string | null;
      last_compiled_at: Date | null;
    }>>`
      SELECT id, slug, title, type, status, body_md, last_compiled_at
      FROM pages
      WHERE user_id = ${userId}
        AND (title ILIKE ${pattern} OR body_md ILIKE ${pattern})
      ORDER BY updated_at DESC
      LIMIT ${limit}
    `;

    // Graph augmentation: expand one hop out from the matched pages along
    // page_links, so the agent sees the knowledge network around each hit
    // rather than isolated matches. Skip pages already in the direct results.
    const matchedPageIds = pageRows.map((p) => p.id);
    const matchedPageIdSet = new Set(matchedPageIds);
    let neighborRows: Array<{
      page_id: string;
      slug: string;
      title: string;
      type: string;
      weight: number;
      rationale: string | null;
      direction: string;
    }> = [];

    if (matchedPageIds.length > 0) {
      neighborRows = await pgSql<Array<{
        page_id: string;
        slug: string;
        title: string;
        type: string;
        weight: number;
        rationale: string | null;
        direction: string;
      }>>`
        SELECT p.id AS page_id, p.slug, p.title, p.type, pl.weight, pl.rationale,
               'outbound' AS direction
        FROM page_links pl
        JOIN pages p ON p.id = pl.to_page_id
        WHERE pl.user_id = ${userId}
          AND pl.from_page_id = ANY(${matchedPageIds})
        UNION
        SELECT p.id AS page_id, p.slug, p.title, p.type, pl.weight, pl.rationale,
               'inbound' AS direction
        FROM page_links pl
        JOIN pages p ON p.id = pl.from_page_id
        WHERE pl.user_id = ${userId}
          AND pl.to_page_id = ANY(${matchedPageIds})
        ORDER BY weight DESC
        LIMIT 10
      `;
      // Drop neighbours that are already direct hits to avoid duplication.
      neighborRows = neighborRows.filter((n) => !matchedPageIdSet.has(n.page_id));
    }

    const lines: string[] = [`Search results for: "${query}"`, ""];

    // Pages section
    lines.push("=== Pages ===");
    if (pageRows.length === 0) {
      lines.push("  (no pages found)");
    } else {
      for (const p of pageRows) {
        const compiled = p.last_compiled_at
          ? p.last_compiled_at.toISOString().slice(0, 10)
          : "never";
        lines.push(`[${p.type}] ${p.title}`);
        lines.push(`  slug: ${p.slug} | status: ${p.status} | compiled: ${compiled}`);
        if (p.body_md) {
          const preview = p.body_md.slice(0, 200).replace(/\n/g, " ");
          lines.push(`  ${preview}${p.body_md.length > 200 ? "…" : ""}`);
        }
        lines.push("");
      }
    }

    // Related pages from the knowledge graph (one-hop neighbours of the hits).
    // Only shown when direct page matches exist and have neighbours.
    if (neighborRows.length > 0) {
      lines.push(`=== Related (knowledge graph, ${neighborRows.length}) ===`);
      for (const n of neighborRows) {
        const arrow = n.direction === "outbound" ? "→" : "←";
        lines.push(`  ${arrow} [${n.type}] ${n.title} (weight: ${n.weight})`);
        lines.push(`    slug: ${n.slug}`);
        if (n.rationale) lines.push(`    rationale: ${n.rationale}`);
      }
      lines.push("");
    }

    // Memos section
    lines.push("=== Memos ===");
    if (memoRows.length === 0) {
      lines.push("  (no memos found)");
    } else {
      for (const m of memoRows) {
        const ts = m.created_at.toISOString().slice(0, 19).replace("T", " ");
        const preview = m.body.slice(0, 300).replace(/\n/g, " ");
        lines.push(`[${ts}] (${m.origin}) ${preview}${m.body.length > 300 ? "…" : ""}`);
        lines.push(`  id: ${m.id}`);
        lines.push("");
      }
    }

    return { content: [{ type: "text", text: lines.join("\n") }] };
  },
};

export default searchTool;
