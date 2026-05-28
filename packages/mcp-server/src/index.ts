#!/usr/bin/env node
/**
 * DayPage MCP Server — stdio transport
 * Compatible with Claude Desktop and Claude Code
 *
 * JSON-RPC 2.0 over stdin/stdout.
 * Implements: initialize, listTools, callTool
 */

import { createInterface } from "readline";
import { handleRequest } from "./server.js";

const rl = createInterface({ input: process.stdin, terminal: false });

rl.on("line", (line) => {
  const trimmed = line.trim();
  if (trimmed === "") return;

  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    const errorResponse = {
      jsonrpc: "2.0",
      id: null,
      error: { code: -32700, message: "Parse error: invalid JSON" },
    };
    process.stdout.write(JSON.stringify(errorResponse) + "\n");
    return;
  }

  handleRequest(parsed)
    .then((response) => {
      if (response !== null) {
        process.stdout.write(JSON.stringify(response) + "\n");
      }
    })
    .catch((err: unknown) => {
      const msg = err instanceof Error ? err.message : String(err);
      const errorResponse = {
        jsonrpc: "2.0",
        id: null,
        error: { code: -32603, message: `Internal error: ${msg}` },
      };
      process.stdout.write(JSON.stringify(errorResponse) + "\n");
    });
});

rl.on("close", () => {
  process.exit(0);
});

// Keep alive — MCP servers run as persistent processes
process.on("SIGTERM", () => process.exit(0));
process.on("SIGINT", () => process.exit(0));
