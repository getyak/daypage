import type { McpToolDefinition, McpToolResult } from "../types.js";
import searchTool from "./search.js";
import { getPageTool, addMemoTool, listRecentTool, graphNeighborsTool } from "./crud.js";

export interface ToolHandler {
  name: string;
  description: string;
  inputSchema: McpToolDefinition["inputSchema"];
  handler: (args: Record<string, unknown>) => Promise<McpToolResult>;
}

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
