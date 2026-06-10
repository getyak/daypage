# Agentry

> An agent-native CLI: an **orchestration runtime**, a **callable platform**, a
> **web-fused** browser agent, and an interactive **TUI workbench** — in a single Go binary.

Agentry runs a reason→act→observe loop with tool use (like Claude Code / OpenClaw), and
exposes that same runtime over **stdio (JSON-RPC), HTTP, and MCP** so users, third-party
programs, and *other agents* can drive it — or be driven by it.

## Why

Everything is built around four small, stable seams so capability stays pluggable and the
runtime is reachable by anything that speaks one of its protocols:

| Seam | Role |
|---|---|
| `Provider` | LLM backend — Anthropic, OpenAI-compatible (incl. DashScope/qwen), mock. Runtime-switchable. |
| `Tool` | A capability. A browser action, a file read, an MCP-proxied remote tool, and a sub-agent are all `Tool`s. |
| `Transport` | How the runtime is reached: stdio / HTTP / MCP server. All wrap the *same* engine. |
| `Session` | Durable conversation as an append-only event log (JSONL); resumable + auditable. |

See [`DESIGN.md`](./DESIGN.md) for the full architecture and [`IMPROVEMENTS.md`](./IMPROVEMENTS.md)
for the iterative hardening log.

## Install

```bash
# Go 1.23+
go build -o bin/agentry ./cmd/agentry
```

## Usage

```bash
agentry run "<prompt>"                       # one-shot; prints the final answer (pipeable)
agentry chat                                 # interactive TUI workbench
agentry serve --http :8787                   # REST + SSE + embedded Web UI at /
agentry serve --stdio                        # JSON-RPC 2.0 over stdin/stdout (drive from another program/agent)
agentry serve --mcp                          # expose Agentry's tools/agents as an MCP server
agentry tools list                           # inspect registered tools
agentry session ls | show <id>               # inspect/resume persisted sessions
agentry mcp add <cmd...>                     # connect a third-party MCP server's tools
```

Configure the provider via flags or env (no key → falls back to the `mock` provider so the
binary is always runnable):

```bash
export ANTHROPIC_API_KEY=...                 # provider: claude (default model claude-sonnet-4-6)
export OPENAI_API_KEY=...   OPENAI_BASE_URL=...   # provider: openai (OpenAI-compatible)
export DASHSCOPE_API_KEY=...                 # provider: dashscope (qwen, OpenAI-compatible)
agentry run --provider claude --model claude-sonnet-4-6 "summarize the news"
```

## Capabilities

**12 built-in tools**, all mediated by an allow/deny/**ask** policy gate:

- **Filesystem / system** — `fs.read`, `fs.write`, `fs.list`, `shell.exec` (bounded, session-cwd aware)
- **Web fusion** — `web.fetch` (with SSRF guards: blocks loopback/link-local/private + cloud-metadata),
  `web.extract` (HTML → readable Markdown), `web.search` (vendor-neutral via `AGENTRY_SEARCH_URL`)
- **Browser automation** (real Chrome via CDP) — `browser.navigate`, `browser.read`, `browser.click`,
  `browser.type`, `browser.screenshot` (degrades gracefully when no browser is present)

Plus **sub-agent orchestration** (any named agent profile is exposed as an `agent.<name>` tool,
so an agent can schedule another) and an **MCP client** to plug in third-party tools without recompiling.

## Layout

```
cmd/agentry/            cobra CLI entrypoint
internal/core/
  provider/             Provider seam + anthropic / openaicompat / mock / retry adapters
  tool/  session/       Tool registry + append-only session event log
  agent/                the reason→act→observe Engine
  policy/  orchestrator/ allow/deny/ask gate + sub-agent scheduling
internal/tools/         builtin/ , web/ (+ web/browser) , mcp (client)
internal/transport/     stdio (JSON-RPC) , http (REST+SSE) , mcpserver
internal/ui/            tui (Bubble Tea) , web (embedded SPA)
internal/config/        layered config (defaults → file → env → flags)
```

## Status

~16k lines of Go across 21 packages. `go build ./...`, `go vet ./...`, and `go test ./...`
all pass. Built via an agent-teams workflow, then hardened over multiple verification rounds
(see `IMPROVEMENTS.md`).
