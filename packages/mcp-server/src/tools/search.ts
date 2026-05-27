import type { ToolHandler, McpToolResult } from "../types.js";
import { getAuthenticatedUserId } from "../auth.js";
import { pgSql } from "../db.js";

const searchTool: ToolHandler = {
  name: "daypage_search",
  description: "Search DayPage memos and pages by keyword or phrase",
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
