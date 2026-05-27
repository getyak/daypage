import type { McpToolDefinition, McpToolResult } from "../types.js";

export interface ToolHandler {
  name: string;
  description: string;
  inputSchema: McpToolDefinition["inputSchema"];
  handler: (args: Record<string, unknown>) => Promise<McpToolResult>;
}

// Tools are registered here — populated by US-021 and US-022
export const ALL_TOOLS: ToolHandler[] = [];

export async function callTool(name: string, args: Record<string, unknown>): Promise<McpToolResult> {
  const tool = ALL_TOOLS.find((t) => t.name === name);
  if (!tool) {
    throw new Error(`Tool not found: ${name}`);
  }
  return tool.handler(args);
}
