import type { JsonRpcRequest, JsonRpcResponse, McpToolDefinition, McpToolResult } from "./types.js";
import { ALL_TOOLS, callTool } from "./tools/index.js";

function ok(id: string | number | null, result: unknown): JsonRpcResponse {
  return { jsonrpc: "2.0", id, result };
}

function err(id: string | number | null, code: number, message: string): JsonRpcResponse {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

function isJsonRpcRequest(val: unknown): val is JsonRpcRequest {
  return (
    typeof val === "object" &&
    val !== null &&
    (val as Record<string, unknown>)["jsonrpc"] === "2.0" &&
    typeof (val as Record<string, unknown>)["method"] === "string"
  );
}

export async function handleRequest(raw: unknown): Promise<JsonRpcResponse | null> {
  if (!isJsonRpcRequest(raw)) {
    return err(null, -32600, "Invalid Request");
  }

  const { id, method, params } = raw;

  switch (method) {
    case "initialize": {
      return ok(id, {
        protocolVersion: "2024-11-05",
        serverInfo: { name: "daypage-mcp-server", version: "0.1.0" },
        capabilities: { tools: {} },
      });
    }

    case "notifications/initialized": {
      // Client acknowledgement — no response needed for notifications
      return null;
    }

    case "tools/list": {
      const tools: McpToolDefinition[] = ALL_TOOLS.map((t) => ({
        name: t.name,
        description: t.description,
        inputSchema: t.inputSchema,
      }));
      return ok(id, { tools });
    }

    case "tools/call": {
      const p = params as Record<string, unknown> | undefined;
      const toolName = typeof p?.name === "string" ? p.name : null;
      const toolArgs = (p?.arguments ?? {}) as Record<string, unknown>;

      if (!toolName) {
        return err(id, -32602, "Missing tool name");
      }

      const tool = ALL_TOOLS.find((t) => t.name === toolName);
      if (!tool) {
        return err(id, -32602, `Unknown tool: ${toolName}`);
      }

      try {
        const result: McpToolResult = await callTool(toolName, toolArgs);
        return ok(id, result);
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        const errorResult: McpToolResult = {
          content: [{ type: "text", text: `Error: ${msg}` }],
          isError: true,
        };
        return ok(id, errorResult);
      }
    }

    default:
      return err(id, -32601, `Method not found: ${method}`);
  }
}
