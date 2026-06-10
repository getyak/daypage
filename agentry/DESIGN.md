# Agentry — System Design

> An agent-native CLI: an orchestration runtime, a callable platform, a web-fused
> browser agent, and an interactive TUI workbench. Written in Go.

## 0. One-paragraph thesis

`agentry` is a **single Go binary** that is simultaneously (a) an **agent runtime** that
runs a reason→act→observe loop with tool use; (b) a **platform** that exposes that
runtime over stdio (JSON-RPC), HTTP, and as an MCP server, so users, third parties, and
*other agents* can drive or be driven by it; (c) a **web-fused** agent with first-class
browser automation, fetch/extract, and an embedded local Web UI; and (d) an interactive
**TUI workbench** (Bubble Tea) like Claude Code / OpenClaw. Everything is built around a
small, stable set of seams (Provider, Tool, Transport, Session) so capability is
*pluggable* and the system can be *scheduled* by anything that speaks one of its protocols.

## 1. Design tenets

1. **Seams over features.** Four interfaces carry the whole system: `Provider`
   (LLM backend), `Tool` (a capability), `Transport` (how the runtime is reached),
   `Session` (durable conversation + state). Everything else is an implementation.
2. **The runtime is headless-first.** TUI and Web UI are *clients* of the same engine
   that the HTTP/stdio/MCP transports expose. No logic lives only in the UI.
3. **Provider-agnostic.** A normalized message/tool-call schema decouples the loop from
   any vendor. Claude, OpenAI-compatible (incl. DashScope/qwen), and local backends are
   adapters. Runtime-switchable.
4. **Web is a first-class tool family, not a bolt-on.** `browser.*`, `web.fetch`,
   `web.search`, `web.extract` are ordinary tools the agent selects, with the same
   permission model as everything else.
5. **Composable & schedulable.** Any agent can call any other agent (sub-agents),
   any external program can call agentry (transports), and agentry can call external
   tools (MCP client). Three directions, one mental model.
6. **Safety by mediation.** Every side-effecting tool call passes a Policy gate
   (allow / deny / ask), inspired by openclaw's `exec-approvals`. Auditable.
7. **Resumable & observable.** Sessions persist as event logs; runs are inspectable.

## 2. Capability map (what the user asked for → where it lives)

| Requirement | Subsystem |
|---|---|
| Agent orchestration runtime (Claude-Code-like) | `core/agent` loop + `core/session` |
| Callable by 3rd parties / other agents | `transport/{stdio,http,mcpserver}` |
| Web-fused browser agent (OpenClaw-like) | `tools/web` (`browser`, `fetch`, `extract`, `search`) |
| Interactive TUI | `ui/tui` (Bubble Tea) |
| Multi-provider abstraction | `core/provider` + adapters |
| 3rd-party tools plug in | `tools/mcp` (MCP **client**) |
| Embedded Web UI | `ui/web` (embedded static + SSE over the HTTP transport) |
| Scheduling / sub-agents | `core/orchestrator` (agent-as-tool, fan-out) |
| Safety | `core/policy` |

## 3. Module layout

```
agentry/
  cmd/agentry/            main(): wires cobra commands → engine
  internal/
    core/
      provider/           Provider interface + Message/ToolCall normalization
        anthropic/        Claude adapter (Messages API, tool_use)
        openaicompat/     OpenAI-compatible adapter (DashScope/qwen/etc.)
        mock/             deterministic provider for tests
      tool/               Tool interface, Registry, JSON-schema params
      agent/              the reason→act→observe Engine (the heart)
      session/            Session, event log, persistence (JSONL store)
      policy/             allow/deny/ask gate + approvals store
      orchestrator/       sub-agent spawning, agent-as-tool, fan-out/pipeline
    tools/
      builtin/            fs.read, fs.write, shell.exec, ...
      web/                browser.*, web.fetch, web.search, web.extract
      mcp/                MCP client: discover + proxy remote tools as local tools
    transport/
      stdio/              newline-delimited JSON-RPC 2.0 over stdin/stdout
      http/               REST + SSE; also serves embedded Web UI
      mcpserver/          expose agentry's tools/agents as an MCP server
    ui/
      tui/                Bubble Tea workbench
      web/                embedded SPA assets + handlers
    config/               layered config (defaults → file → env → flags)
    obs/                  logging, tracing hooks, run inspection
  web-ui/                 source for the embedded SPA (built → internal/ui/web/dist)
  DESIGN.md  ROADMAP.md  README.md
```

## 4. Core interfaces (the seams)

### 4.1 Provider
```go
type Provider interface {
    Name() string
    // Stream runs one model turn; emits deltas + tool-call requests on the channel.
    Stream(ctx context.Context, req Request) (<-chan Event, error)
}
type Request struct {
    Model    string
    System   string
    Messages []Message       // normalized, vendor-independent
    Tools    []ToolSpec      // JSON-schema tool definitions
    Stream   bool
}
type Event struct {            // one of:
    TextDelta  string
    ToolCall   *ToolCall       // model wants to invoke a tool
    Usage      *Usage
    StopReason string
    Err        error
}
```
The loop never imports a vendor SDK; adapters translate to/from this schema.

### 4.2 Tool
```go
type Tool interface {
    Name() string
    Description() string
    Schema() json.RawMessage           // JSON Schema for arguments
    Invoke(ctx context.Context, in ToolInput) (ToolResult, error)
}
type ToolInput struct {
    Args    json.RawMessage
    Session *session.Session           // ambient context (cwd, env, approvals)
}
```
`browser.navigate`, `fs.read`, an MCP-proxied remote tool, and a *sub-agent* are all
just `Tool`s. That uniformity is the whole trick.

### 4.3 Transport
```go
type Transport interface {
    Name() string
    Serve(ctx context.Context, eng *agent.Engine) error
}
```
stdio, http, mcpserver all wrap the same `*agent.Engine`.

### 4.4 Session
Append-only event log (`user`, `assistant`, `tool_call`, `tool_result`, `meta`),
persisted as JSONL under `~/.agentry/sessions/<id>.jsonl`. Enables resume + audit +
the Web UI / TUI rendering the same stream.

## 5. The agent loop (`core/agent`)

```
loop:
  events = provider.Stream(ctx, buildRequest(session))
  for ev in events:
     TextDelta -> append to assistant turn, emit to subscribers (TUI/Web/stdio)
     ToolCall  -> policy.Check(tool, args)
                    deny  -> tool_result{error: "denied"}
                    ask   -> raise approval request to the active transport/UI
                    allow -> registry.Get(tool).Invoke(...) -> tool_result
                  append tool_result to session
     StopReason==end_turn and no pending tool calls -> break
  if any tool ran this turn -> loop again (model sees results)
```
Concurrency: a single run is one goroutine; multiple tool calls in one turn may run
in parallel (bounded). Sub-agents run as nested Engines sharing the policy + registry.

## 6. Transports (callable platform)

- **stdio JSON-RPC 2.0** — the lowest-common-denominator. Methods: `session.create`,
  `session.prompt` (streams via notifications), `tools.list`, `agents.list`,
  `approval.resolve`. This is how *other agents/programs* drive agentry in a pipe.
- **HTTP** — `POST /v1/sessions`, `POST /v1/sessions/{id}/messages` (SSE stream),
  `GET /v1/tools`, `GET /healthz`; also mounts the embedded Web UI at `/`.
- **MCP server** — agentry advertises its tools (and named agents) over MCP so any
  MCP-capable client (incl. Claude Code itself) can call into agentry.

## 7. Web fusion (`tools/web`)

- `web.fetch` — HTTP GET with redirect/size/host policy; returns headers + body.
- `web.extract` — HTML → readable Markdown (main-content extraction).
- `web.search` — pluggable search backend (provider-configurable).
- `browser.*` — drive a real browser over **CDP** (Chrome DevTools Protocol) via the
  `chromedp` library: `navigate`, `click`, `type`, `read`(accessibility/text snapshot),
  `screenshot`, `eval`. Headless by default; the embedded Web UI can surface screenshots.
  Browser is optional at runtime (degrade gracefully if no Chrome present).

## 8. MCP client (`tools/mcp`)

Connect to configured MCP servers (stdio or http), list their tools, and register each
as a local `Tool` whose `Invoke` proxies the call. This is how third-party capability
plugs in without recompiling agentry.

## 9. Orchestrator (scheduling / sub-agents)

- **agent-as-tool**: a named agent profile (own system prompt, tool allow-list, model)
  is exposed as a `Tool` named `agent.<name>`; calling it spins a nested Engine and
  returns its final output. This is how an agent *schedules* another agent.
- **fan-out / pipeline** helpers for deterministic multi-agent control flow.

## 10. Policy (`core/policy`)

`Decision = allow | deny | ask`, matched by rules on (tool name, arg predicates).
Defaults: read-only tools allow; `shell.exec`, `fs.write`, `browser.eval` → ask.
Approvals persisted (remember-this-choice), mirroring openclaw's `exec-approvals.json`.

## 11. TUI (`ui/tui`)

Bubble Tea: streaming transcript pane, input box, tool-call cards (with approve/deny
prompts), session switcher, /-commands. It is a *client* of the Engine via in-process
subscription (same event types the transports emit).

## 12. Config & secrets

Layered: built-in defaults → `~/.agentry/config.{toml,json}` → env (`AGENTRY_*`,
`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `DASHSCOPE_API_KEY`) → CLI flags. Secrets only
from env/keychain, never persisted to session logs.

## 13. CLI surface (cobra)

```
agentry run "<prompt>"        one-shot; prints final answer (pipeable)
agentry chat                  interactive TUI
agentry serve [--http|--stdio|--mcp]   run as a platform
agentry tools list            inspect registered tools
agentry session ls|show <id>  inspect/resume sessions
agentry mcp add <url>         register an MCP server
agentry config ...            manage config
```

## 14. Non-goals (v1)

Distributed multi-node scheduling; auth/multi-tenant cloud; a bespoke model server.
These are deliberately out of scope to keep the seams clean.

## 15. Build/test discipline

- `go build ./...` and `go vet ./...` must pass at every milestone.
- Unit tests use the `mock` provider — deterministic, no network.
- The verification agent iterates ≥10 rounds against this real codebase (see ROADMAP.md).
