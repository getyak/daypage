import type { McpToolResult, ToolHandler } from "../types.js";
import searchTool from "./search.js";
import { getPageTool, addMemoTool, listRecentTool, graphNeighborsTool } from "./crud.js";

// Re-export so existing callers using `from "./tools/index.js"` keep working.
export type { ToolHandler } from "../types.js";

export const ALL_TOOLS: ToolHandler[] = [
  searchTool,
  getPageTool,
  addMemoTool,
  listRecentTool,
  graphNeighborsTool,
];

export async function callTool(name: string, args: Record<string, unknown>): Promise<McpToolResult> {
  const tool = ALL_TOOLS.find((t) => t.name === name);
  if (!tool) {
    throw new Error(`Tool not found: ${name}`);
  }
  return tool.handler(args);
}
