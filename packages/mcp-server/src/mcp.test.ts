import assert from "node:assert/strict";
import test from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { EmptyResultSchema, ErrorCode, McpError } from "@modelcontextprotocol/sdk/types.js";
import type { DayPageAuthContext } from "./auth.js";
import type { DayPageMcpConfig } from "./config.js";
import { createDayPageMcpServer } from "./mcp.js";
import type { DayPageRepository, McpClientGrant } from "./repository.js";

// Recover the old protocol-test intent against the current SDK server. The
// in-memory transport opens no socket; any repository access fails the test.
const config: DayPageMcpConfig = {
  host: "127.0.0.1", port: 0,
  supabaseUrl: "https://example.supabase.co", supabaseAnonKey: "synthetic-anon",
  issuer: "https://example.supabase.co/auth/v1",
  authorizationServer: "https://example.supabase.co/auth/v1",
  resource: "https://daypage.example/mcp", appBaseUrl: "https://daypage.example",
  requestBodyLimitBytes: 1024, requestsPerMinute: 60,
};
const auth: DayPageAuthContext = {
  token: "synthetic-token", subject: "11111111-1111-4111-8111-111111111111",
  clientId: "protocol-test", expiresAt: 2_000_000_000, grantedScopes: [],
  claims: {
    iss: config.issuer, sub: "11111111-1111-4111-8111-111111111111",
    aud: ["authenticated", config.resource], exp: 2_000_000_000, iat: 1_900_000_000,
    role: "authenticated", aal: "aal1", session_id: "22222222-2222-4222-8222-222222222222",
    client_id: "protocol-test",
  },
  authType: "oauth",
};
const readGrant: McpClientGrant = {
  canRead: true, canWrite: false, canReadActions: false, canProposeActions: false,
};

async function withClient(grant: McpClientGrant, run: (client: Client) => Promise<void>) {
  let repositoryAccesses = 0;
  const repository = new Proxy({} as DayPageRepository, {
    get(_target, property) {
      repositoryAccesses += 1;
      throw new Error(`Unexpected repository access: ${String(property)}`);
    },
  });
  const server = createDayPageMcpServer(config, auth, grant, repository);
  const client = new Client({ name: "protocol-test", version: "1.0.0" }, { capabilities: {} });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  try {
    await server.connect(serverTransport);
    await client.connect(clientTransport);
    await run(client);
    assert.equal(repositoryAccesses, 0, "protocol and rejected calls must not access private data");
  } finally {
    await client.close();
    await server.close();
  }
}

test("initialization advertises the current server and read capabilities without data access", async () => {
  await withClient(readGrant, async (client) => {
    assert.equal(client.getServerVersion()?.name, "daypage-cloud");
    assert.ok(client.getServerCapabilities()?.tools);
    assert.ok(client.getServerCapabilities()?.resources);
    assert.match(client.getInstructions() ?? "", /proposals only/);
  });
});

test("each combination of the four grants exposes only its permitted tool set", async (t) => {
  for (let bits = 0; bits < 16; bits += 1) {
    await t.test(`grant mask ${bits}`, async () => {
      const grant: McpClientGrant = {
        canRead: Boolean(bits & 1), canWrite: Boolean(bits & 2),
        canReadActions: Boolean(bits & 4), canProposeActions: Boolean(bits & 8),
      };
      await withClient(grant, async (client) => {
        const expected = [
          ...(grant.canRead ? ["daypage_list_recent", "daypage_search", "daypage_get_memo", "daypage_get_page"] : []),
          ...(grant.canWrite ? ["daypage_add_memo"] : []),
          ...(grant.canReadActions ? ["daypage_list_action_proposals", "daypage_list_action_receipts"] : []),
          ...(grant.canProposeActions ? ["daypage_propose_action"] : []),
        ];
        if (expected.length === 0) {
          assert.equal(client.getServerCapabilities()?.tools, undefined);
        } else {
          assert.deepEqual((await client.listTools()).tools.map(({ name }) => name).sort(), expected.sort());
        }
        assert.equal(Boolean(client.getServerCapabilities()?.resources), grant.canRead);
      });
    });
  }
});

test("unknown protocol methods return method-not-found without data access", async () => {
  await withClient(readGrant, async (client) => {
    await assert.rejects(client.request({ method: "does/not/exist" }, EmptyResultSchema),
      (error: unknown) => error instanceof McpError && error.code === ErrorCode.MethodNotFound);
  });
});

test("unknown tool calls return an error without data access", async () => {
  await withClient(readGrant, async (client) => {
    const result = await client.callTool({ name: "no_such_tool", arguments: {} });
    assert.equal(result.isError, true);
    assert.match(JSON.stringify(result.content), /not found/);
  });
});

test("read-only clients cannot invoke unadvertised write or action tools", async () => {
  await withClient(readGrant, async (client) => {
    for (const name of ["daypage_add_memo", "daypage_propose_action", "daypage_list_action_proposals", "daypage_list_action_receipts"]) {
      const result = await client.callTool({ name, arguments: { text: "synthetic memo" } });
      assert.equal(result.isError, true, name);
      assert.match(JSON.stringify(result.content), /not found/);
    }
  });
});

test("write permission does not grant memo reads or private resources", async () => {
  await withClient({ ...readGrant, canRead: false, canWrite: true }, async (client) => {
    const result = await client.callTool({ name: "daypage_get_memo", arguments: { id: auth.subject } });
    assert.equal(result.isError, true);
    await assert.rejects(client.readResource({ uri: `daypage://memos/${auth.subject}` }));
  });
});

test("invalid read arguments fail before any repository access", async () => {
  await withClient(readGrant, async (client) => {
    for (const [name, args] of [
      ["daypage_list_recent", { limit: 51 }],
      ["daypage_search", { query: "  " }],
      ["daypage_get_memo", { id: "not-a-uuid" }],
      ["daypage_get_page", { slug: "" }],
    ] as const) {
      const result = await client.callTool({ name, arguments: args });
      assert.equal(result.isError, true, name);
      assert.match(JSON.stringify(result.content), /Invalid arguments/);
    }
  });
});
