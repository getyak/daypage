// Placeholder — implemented in US-022
import type { ToolHandler } from "../types.js";

export const getPageTool: ToolHandler = {
  name: "get_page",
  description: "Get a DayPage wiki page by slug",
  inputSchema: {
    type: "object",
    properties: { slug: { type: "string" } },
    required: ["slug"],
  },
  async handler() {
    return { content: [{ type: "text", text: "Not yet implemented" }], isError: true };
  },
};

export const addMemoTool: ToolHandler = {
  name: "add_memo",
  description: "Add a new memo to DayPage",
  inputSchema: {
    type: "object",
    properties: {
      content: { type: "string" },
      source: { type: "string" },
    },
    required: ["content"],
  },
  async handler() {
    return { content: [{ type: "text", text: "Not yet implemented" }], isError: true };
  },
};

export const listRecentTool: ToolHandler = {
  name: "list_recent",
  description: "List recent memos from DayPage",
  inputSchema: {
    type: "object",
    properties: {
      limit: { type: "number" },
      days: { type: "number" },
    },
  },
  async handler() {
    return { content: [{ type: "text", text: "Not yet implemented" }], isError: true };
  },
};

export const graphNeighborsTool: ToolHandler = {
  name: "graph_neighbors",
  description: "Get linked entities for a page from the knowledge graph",
  inputSchema: {
    type: "object",
    properties: {
      entity_id: { type: "string" },
      depth: { type: "number" },
    },
    required: ["entity_id"],
  },
  async handler() {
    return { content: [{ type: "text", text: "Not yet implemented" }], isError: true };
  },
};
