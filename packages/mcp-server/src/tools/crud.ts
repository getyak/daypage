import type { ToolHandler, McpToolResult } from "../types.js";
import { getAuthenticatedUserId } from "../auth.js";
import { pgSql } from "../db.js";

// ─── get_page ────────────────────────────────────────────────────────────────

export const getPageTool: ToolHandler = {
  name: "get_page",
  description: "Get a DayPage wiki page by its slug — returns title, type, status, body, and metadata",
  inputSchema: {
    type: "object",
    properties: {
      slug: {
        type: "string",
        description: "The page slug (URL-safe identifier)",
      },
    },
    required: ["slug"],
  },

  async handler(args): Promise<McpToolResult> {
    const slug = typeof args.slug === "string" ? args.slug.trim() : "";
    if (!slug) {
      return { content: [{ type: "text", text: "Error: slug is required" }], isError: true };
    }

    const userId = await getAuthenticatedUserId();
    if (!userId) {
      return { content: [{ type: "text", text: "Error: DAYPAGE_API_KEY is invalid or not set" }], isError: true };
    }

    const rows = await pgSql<Array<{
      id: string;
      slug: string;
      type: string;
      title: string;
      status: string;
      body_md: string | null;
      metadata: unknown;
      version: number;
      source_count: number;
      backlink_count: number;
      last_compiled_at: Date | null;
      created_at: Date;
      updated_at: Date;
    }>>`
      SELECT id, slug, type, title, status, body_md, metadata, version,
             source_count, backlink_count, last_compiled_at, created_at, updated_at
      FROM pages
      WHERE user_id = ${userId}
        AND slug = ${slug}
      LIMIT 1
    `;

    if (!rows[0]) {
      return { content: [{ type: "text", text: `Page not found: ${slug}` }], isError: true };
    }

    const p = rows[0];
    const lines: string[] = [
      `Title: ${p.title}`,
      `Slug: ${p.slug}`,
      `Type: ${p.type} | Status: ${p.status} | Version: ${p.version}`,
      `Sources: ${p.source_count} memos | Backlinks: ${p.backlink_count}`,
      `Last compiled: ${p.last_compiled_at?.toISOString() ?? "never"}`,
      `Created: ${p.created_at.toISOString()} | Updated: ${p.updated_at.toISOString()}`,
      "",
    ];

    if (p.metadata) {
      lines.push("--- Metadata ---");
      lines.push(JSON.stringify(p.metadata, null, 2));
      lines.push("");
    }

    if (p.body_md) {
      lines.push("--- Content ---");
      lines.push(p.body_md);
    } else {
      lines.push("(no content)");
    }

    return { content: [{ type: "text", text: lines.join("\n") }] };
  },
};

// ─── add_memo ────────────────────────────────────────────────────────────────

export const addMemoTool: ToolHandler = {
  name: "add_memo",
  description: "Create a new memo in DayPage and trigger the compilation pipeline",
  inputSchema: {
    type: "object",
    properties: {
      content: {
        type: "string",
        description: "The memo text content",
      },
      source: {
        type: "string",
        description: "Source identifier (defaults to 'mcp')",
      },
    },
    required: ["content"],
  },

  async handler(args): Promise<McpToolResult> {
    const content = typeof args.content === "string" ? args.content.trim() : "";
    if (!content) {
      return { content: [{ type: "text", text: "Error: content is required" }], isError: true };
    }

    const source = typeof args.source === "string" ? args.source : "mcp";

    const userId = await getAuthenticatedUserId();
    if (!userId) {
      return { content: [{ type: "text", text: "Error: DAYPAGE_API_KEY is invalid or not set" }], isError: true };
    }

    const rows = await pgSql<Array<{ id: string; body: string; created_at: Date }>>`
      INSERT INTO memos (user_id, type, body, origin, device, compile_status, ingest_mode)
      VALUES (${userId}, 'text', ${content}, 'api', ${source}, 'pending', 'light')
      RETURNING id, body, created_at
    `;

    const memo = rows[0];
    if (!memo) {
      return { content: [{ type: "text", text: "Error: failed to create memo" }], isError: true };
    }

    const preview = content.slice(0, 120) + (content.length > 120 ? "…" : "");
    const lines = [
      `Memo created successfully.`,
      `ID: ${memo.id}`,
      `Created: ${memo.created_at.toISOString()}`,
      `Preview: ${preview}`,
    ];

    return { content: [{ type: "text", text: lines.join("\n") }] };
  },
};

// ─── list_recent ─────────────────────────────────────────────────────────────

export const listRecentTool: ToolHandler = {
  name: "list_recent",
  description: "List recent memos from DayPage, optionally filtered by time window",
  inputSchema: {
    type: "object",
    properties: {
      limit: {
        type: "number",
        description: "Number of memos to return (default: 10, max: 50)",
      },
      days: {
        type: "number",
        description: "Only return memos from the last N days (default: 7)",
      },
    },
  },

  async handler(args): Promise<McpToolResult> {
    const userId = await getAuthenticatedUserId();
    if (!userId) {
      return { content: [{ type: "text", text: "Error: DAYPAGE_API_KEY is invalid or not set" }], isError: true };
    }

    const limitRaw = typeof args.limit === "number" ? args.limit : 10;
    const limit = Math.min(Math.max(1, limitRaw), 50);

    const daysRaw = typeof args.days === "number" ? args.days : 7;
    const days = Math.max(1, daysRaw);

    const since = new Date();
    since.setDate(since.getDate() - days);

    const rows = await pgSql<Array<{
      id: string;
      body: string;
      type: string;
      origin: string;
      compile_status: string;
      created_at: Date;
    }>>`
      SELECT id, body, type, origin, compile_status, created_at
      FROM memos
      WHERE user_id = ${userId}
        AND created_at >= ${since}
      ORDER BY created_at DESC
      LIMIT ${limit}
    `;

    const lines: string[] = [
      `Recent memos (last ${days} day${days === 1 ? "" : "s"}, up to ${limit}):`,
      `Total returned: ${rows.length}`,
      "",
    ];

    if (rows.length === 0) {
      lines.push("(no memos found in this time window)");
    } else {
      for (const m of rows) {
        const ts = m.created_at.toISOString().slice(0, 19).replace("T", " ");
        const preview = m.body.slice(0, 150).replace(/\n/g, " ");
        lines.push(`[${ts}] [${m.compile_status}] ${preview}${m.body.length > 150 ? "…" : ""}`);
        lines.push(`  id: ${m.id} | origin: ${m.origin}`);
        lines.push("");
      }
    }

    return { content: [{ type: "text", text: lines.join("\n") }] };
  },
};

// ─── graph_neighbors ─────────────────────────────────────────────────────────

export const graphNeighborsTool: ToolHandler = {
  name: "graph_neighbors",
  description: "Get pages linked to a given entity (page) from the knowledge graph, including direct links and annotations",
  inputSchema: {
    type: "object",
    properties: {
      entity_id: {
        type: "string",
        description: "The page ID (UUID) to find neighbors for",
      },
      depth: {
        type: "number",
        description: "Link traversal depth — currently only depth=1 is supported (default: 1)",
      },
    },
    required: ["entity_id"],
  },

  async handler(args): Promise<McpToolResult> {
    const entityId = typeof args.entity_id === "string" ? args.entity_id.trim() : "";
    if (!entityId) {
      return { content: [{ type: "text", text: "Error: entity_id is required" }], isError: true };
    }

    const userId = await getAuthenticatedUserId();
    if (!userId) {
      return { content: [{ type: "text", text: "Error: DAYPAGE_API_KEY is invalid or not set" }], isError: true };
    }

    // Verify ownership of the source page
    const srcRows = await pgSql<Array<{ id: string; title: string; type: string; slug: string }>>`
      SELECT id, title, type, slug
      FROM pages
      WHERE id = ${entityId}
        AND user_id = ${userId}
      LIMIT 1
    `;

    if (!srcRows[0]) {
      return { content: [{ type: "text", text: `Page not found: ${entityId}` }], isError: true };
    }

    const src = srcRows[0];

    // Outbound links (from this page to others)
    const outLinks = await pgSql<Array<{
      link_id: string;
      to_page_id: string;
      to_title: string;
      to_type: string;
      to_slug: string;
      weight: number;
      rationale: string | null;
    }>>`
      SELECT pl.id AS link_id, pl.to_page_id, p.title AS to_title, p.type AS to_type,
             p.slug AS to_slug, pl.weight, pl.rationale
      FROM page_links pl
      JOIN pages p ON p.id = pl.to_page_id
      WHERE pl.from_page_id = ${entityId}
        AND pl.user_id = ${userId}
      ORDER BY pl.weight DESC
      LIMIT 20
    `;

    // Inbound links (other pages linking to this page)
    const inLinks = await pgSql<Array<{
      link_id: string;
      from_page_id: string;
      from_title: string;
      from_type: string;
      from_slug: string;
      weight: number;
    }>>`
      SELECT pl.id AS link_id, pl.from_page_id, p.title AS from_title, p.type AS from_type,
             p.slug AS from_slug, pl.weight
      FROM page_links pl
      JOIN pages p ON p.id = pl.from_page_id
      WHERE pl.to_page_id = ${entityId}
        AND pl.user_id = ${userId}
      ORDER BY pl.weight DESC
      LIMIT 20
    `;

    // Annotations on this page
    const annotations = await pgSql<Array<{
      id: string;
      tag: string;
      note: string | null;
      created_at: Date;
    }>>`
      SELECT id, tag, note, created_at
      FROM annotations
      WHERE page_id = ${entityId}
        AND user_id = ${userId}
      ORDER BY created_at DESC
      LIMIT 10
    `;

    const lines: string[] = [
      `Graph neighbors for: ${src.title} [${src.type}]`,
      `ID: ${src.id} | Slug: ${src.slug}`,
      "",
    ];

    lines.push(`=== Outbound Links (${outLinks.length}) ===`);
    if (outLinks.length === 0) {
      lines.push("  (none)");
    } else {
      for (const l of outLinks) {
        lines.push(`  → [${l.to_type}] ${l.to_title} (weight: ${l.weight})`);
        lines.push(`    slug: ${l.to_slug} | id: ${l.to_page_id}`);
        if (l.rationale) lines.push(`    rationale: ${l.rationale}`);
      }
    }

    lines.push("");
    lines.push(`=== Inbound Links (${inLinks.length}) ===`);
    if (inLinks.length === 0) {
      lines.push("  (none)");
    } else {
      for (const l of inLinks) {
        lines.push(`  ← [${l.from_type}] ${l.from_title} (weight: ${l.weight})`);
        lines.push(`    slug: ${l.from_slug} | id: ${l.from_page_id}`);
      }
    }

    lines.push("");
    lines.push(`=== Annotations (${annotations.length}) ===`);
    if (annotations.length === 0) {
      lines.push("  (none)");
    } else {
      for (const a of annotations) {
        const ts = a.created_at.toISOString().slice(0, 10);
        lines.push(`  [${ts}] tag: ${a.tag}`);
        if (a.note) lines.push(`    note: ${a.note}`);
      }
    }

    return { content: [{ type: "text", text: lines.join("\n") }] };
  },
};
