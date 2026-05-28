export interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: string | number | null;
  method: string;
  params?: unknown;
}

export interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: string | number | null;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

export interface McpToolDefinition {
  name: string;
  description: string;
  inputSchema: {
    type: "object";
    properties: Record<string, unknown>;
    required?: string[];
  };
}

export interface McpToolResult {
  content: Array<{ type: "text"; text: string }>;
  isError?: boolean;
}

// A concrete tool implementation. Lives in types.ts (not tools/index.ts) so that
// tool modules can import it from the shared types barrel without creating a
// circular dependency with tools/index.ts.
export interface ToolHandler {
  name: string;
  description: string;
  inputSchema: McpToolDefinition["inputSchema"];
  handler: (args: Record<string, unknown>) => Promise<McpToolResult>;
}
