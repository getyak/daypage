import { NextRequest, NextResponse } from "next/server";
import { authenticateApiKey, hasScope } from "@/lib/api-auth";
import { checkRateLimit } from "@/lib/ratelimit";
import {
  handleMcpMessage,
  MCP_ERROR_CODES,
  type JsonRpcRequest,
  type JsonRpcResponse,
} from "@/lib/mcp/server";

// rag.ts / drizzle-postgres need the Node.js runtime (not Edge).
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// ─── DayPage MCP endpoint (Streamable HTTP transport) ─────────────────────────
// POST /api/mcp — JSON-RPC 2.0 over HTTP. Authenticated with a DayPage API key
// (Authorization: Bearer <key>) that carries the "read" scope. Exposes the
// read-only wiki tools defined in src/lib/mcp/server.ts so external agents
// (Claude Desktop, Cursor, …) can use the user's knowledge as context.
//
// Claude Desktop config example (~/Library/Application Support/Claude/claude_desktop_config.json):
//   {
//     "mcpServers": {
//       "daypage": {
//         "command": "npx",
//         "args": ["-y", "mcp-remote", "https://<your-host>/api/mcp",
//                  "--header", "Authorization: Bearer <DAYPAGE_API_KEY>"]
//       }
//     }
//   }

function rpcError(
  id: string | number | null,
  code: number,
  message: string
): JsonRpcResponse {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

export async function POST(req: NextRequest) {
  // Auth: require a valid API key with the "read" scope. Invalid / missing keys
  // are rejected (401); valid keys lacking the scope are forbidden (403).
  const apiAuth = await authenticateApiKey(req);
  if (!apiAuth) {
    return NextResponse.json(
      { error: "Unauthorized: a valid DayPage API key is required" },
      { status: 401, headers: { "WWW-Authenticate": "Bearer" } }
    );
  }
  if (!hasScope(apiAuth, "read")) {
    return NextResponse.json(
      { error: "Forbidden: API key lacks 'read' scope" },
      { status: 403 }
    );
  }

  // Rate limit per authenticated key owner — each JSON-RPC call can trigger a
  // RAG query; cap it so an external agent can't exhaust DB / embedding cost.
  const rl = checkRateLimit(`mcp:${apiAuth.userId}`, 60, 60_000);
  if (!rl.success) {
    return NextResponse.json(
      { error: "Rate limit exceeded" },
      {
        status: 429,
        headers: {
          "Retry-After": Math.ceil((rl.reset - Date.now()) / 1000).toString(),
          "X-RateLimit-Remaining": "0",
        },
      }
    );
  }

  const body: unknown = await req.json().catch(() => null);
  if (body === null) {
    return NextResponse.json(
      rpcError(null, MCP_ERROR_CODES.PARSE_ERROR, "Invalid JSON body"),
      { status: 200 }
    );
  }

  // JSON-RPC supports batched arrays as well as single messages.
  if (Array.isArray(body)) {
    if (body.length === 0) {
      return NextResponse.json(
        rpcError(null, MCP_ERROR_CODES.INVALID_REQUEST, "Empty batch"),
        { status: 200 }
      );
    }
    const responses = await Promise.all(
      body.map((m) => handleMcpMessage(apiAuth, m as JsonRpcRequest))
    );
    const filtered = responses.filter((r): r is JsonRpcResponse => r !== null);
    // If every message was a notification there is nothing to return.
    if (filtered.length === 0) return new NextResponse(null, { status: 202 });
    return NextResponse.json(filtered, { status: 200 });
  }

  const response = await handleMcpMessage(apiAuth, body as JsonRpcRequest);
  if (response === null) return new NextResponse(null, { status: 202 });
  return NextResponse.json(response, { status: 200 });
}

// Some MCP clients probe with GET for an SSE stream. We are a stateless
// request/response server, so advertise that no streaming session is available.
export function GET() {
  return NextResponse.json(
    { error: "Method Not Allowed: POST JSON-RPC requests to this endpoint" },
    { status: 405, headers: { Allow: "POST" } }
  );
}
