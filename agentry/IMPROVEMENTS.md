# Agentry — Improvement Log

## Round 1: Session persistence to disk (JSONL store) + `session show`

**Category:** missing feature / correctness (DESIGN↔code gap)

### Rationale

`Session` is one of the four frozen seams, and DESIGN §4.4 / §7 describe it as an
append-only event log "persisted as JSONL under `~/.agentry/sessions/<id>.jsonl`"
that enables "resume + audit + the Web UI / TUI rendering the same stream." The
`session` package docstring even claims the event stream is "persisted (JSONL),
replayed on resume."

In reality **nothing wrote sessions to disk.** The supporting surface existed but
was dead:

- `agentry session ls` read `<AGENTRY_HOME>/sessions/*.jsonl`, but no code ever
  created that directory or any file — so it always reported "no sessions" even
  right after a run.
- `agentry session show <id>` is listed in DESIGN §13 but was never implemented.
- `agentry run` created every session with the literal id `"run"`, so even if
  persistence were added naively, each run would clobber the previous one.

This is the highest-leverage gap: a core documented capability (one of four seams)
that was entirely absent, with directly observable, end-to-end-verifiable behavior,
and no risk to any frozen public API.

### What changed

1. **New `internal/core/session/store.go`** — a `Store` interface plus a
   filesystem-backed `JSONLStore`:
   - `Save(*Session)` writes a session atomically (temp file + `os.Rename`,
     dir `0700`, file `0600`) as JSONL: a `header` record (id/title/model/cwd/env
     /created) followed by one `event` record per `Event`, in order. Atomic write
     mirrors the existing pattern in `core/policy`.
   - `Load(id)` reconstructs a `*Session`, restoring metadata, replaying events,
     and resuming the sequence counter so a resumed session keeps numbering
     coherently. Tolerates a torn final line (crash mid-write) instead of failing.
     Returns `ErrNotFound` for a missing session.
   - `List()` returns sorted session ids; a missing dir yields an empty slice.
   - **Path-traversal guard** (`validID`): ids containing `/`, `\`, `..`, `.`, or
     a NUL byte are rejected before any filesystem access, so a session id can
     never escape the store directory.
   - No change to the frozen `Session`/`Event` types or any seam API — `Save`
     snapshots under the existing `RWMutex`.

2. **`cmd/agentry/main.go`**:
   - `agentry run` now mints a unique, chronologically-sortable session id
     (`newSessionID`, e.g. `run-20060102-150405.000000000`), sets the session
     `Title` to the prompt, and persists the session after the run (best-effort:
     a save failure warns on stderr and never masks the run result).
   - Refactored `session ls` to use `JSONLStore.List()`.
   - **Added `agentry session show <id>`** (DESIGN §13): prints a readable
     transcript (user / assistant / tool-call / tool-result / meta / error), with
     a `--json` flag for the raw event records. Clean error + exit 1 on a missing
     or invalid id.

3. **New `internal/core/session/store_test.go`** — 7 tests: full round-trip of
   every event type, sequence resume on reload, `ErrNotFound`, `List` (incl.
   sort + ignoring stray files), path-traversal rejection, atomic overwrite (no
   leftover temp files), and tolerance of a torn final line.

### How verified (commands)

```sh
export PATH="$HOME/.local/go/bin:$PATH:$HOME/go/bin"; cd /home/smile/agentry
go build ./...            # BUILD_OK
go vet ./...              # VET_OK
go test ./...             # all packages ok (session: 7 new tests pass)
gofmt -l internal/core/session/store.go internal/core/session/store_test.go cmd/agentry/main.go   # (clean)
go build -o bin/agentry ./cmd/agentry

# End-to-end against the real binary in an isolated home:
export AGENTRY_HOME="$(mktemp -d)"
./bin/agentry session ls                    # "no sessions found in .../sessions"
./bin/agentry run "what is 2+2"             # runs via offline mock provider
./bin/agentry session ls                    # now lists run-20260609-...:  "1 session(s)"
head -c 1200 "$AGENTRY_HOME"/sessions/*.jsonl   # header line + event lines, 0600 perms
./bin/agentry session show <id>             # readable transcript
./bin/agentry session show <id> --json      # raw event JSON
./bin/agentry session show no-such-session  # Error + exit 1
./bin/agentry session show ../../etc/passwd # rejected: "session: invalid id ..." (exit 1)
```

### Result

- `agentry run` now produces a durable, resumable, auditable JSONL log per run;
  `agentry session ls` reflects real sessions; `agentry session show` (new) renders
  them. The documented Session seam capability is real instead of aspirational.
- Secrets stay out of the log (only normalized events are written); writes are
  atomic; the store is hardened against path traversal.
- Build, vet, gofmt, and the full test suite (including 7 new tests) all pass.

**Follow-up identified for a later round:** the `http` and `stdio` transports hold
sessions purely in memory and don't persist or resume them. Wiring the same
`JSONLStore` into those transports (and adding a `session.create {resume:<id>}`
path) would make resume work across process restarts for the platform surface too,
not just the one-shot `run` path. (Left out this round to keep the change focused
and the seam APIs untouched.)

## Round 2: HTTP retry/backoff for transient provider failures

**Category:** robustness / provider hardening (HTTP retry/backoff + error surfacing)

### Rationale

This was the explicit follow-up flagged at the end of Round 1 ("provider
robustness — HTTP retry/backoff, error surfacing"). Both real provider adapters
(`anthropic`, `openaicompat`) issued their POST to the model with **no retry
whatsoever**: a single transient failure aborted the entire model turn and
bubbled up to the user as a hard error / exit 1. The failure modes that were not
tolerated are exactly the ones that happen constantly in production against real
LLM backends:

- **429 Too Many Requests** (rate limiting) — the single most common provider
  error; backends routinely return it with a `Retry-After` and expect the client
  to wait and retry.
- **5xx** (500/502/503/504) — server overload (Anthropic's `overloaded_error`,
  DashScope capacity blips) and gateway hiccups.
- **Network errors before the response headers arrive** — connection reset, DNS
  flap, refused connection, EOF — transient TCP-level faults.

Because both adapters fully buffer the request body in a `*bytes.Reader` before
sending (so `http.Request.GetBody` is populated and the POST is *replayable*),
adding transparent retry is both safe and high-leverage: it turns a class of
spurious turn-aborts into automatic recovery, with zero change to the agent loop
or any frozen seam.

### What changed

1. **New `internal/core/provider/retry` package** — a reusable, dependency-free
   (`net/http` + stdlib only) `http.RoundTripper` decorator:
   - `RoundTripper.RoundTrip` retries on transient outcomes — transport errors
     that are *not* `context.Canceled`/`DeadlineExceeded`, and status codes
     **408, 425, 429, 500, 502, 503, 504**. Non-transient statuses (e.g. 400/401/
     404) and context cancellation are returned immediately, never retried.
   - **Exponential backoff with full jitter** (`BaseDelay * 2^attempt`, capped at
     `MaxDelay`, then a uniform pick in `[0, ceil]`) to avoid synchronized retry
     storms; overflow-guarded.
   - **Honors `Retry-After`** (both integer-seconds and HTTP-date forms) on the
     response, capped at `MaxDelay`.
   - **Replay-safety:** only retries when the request body is rewindable
     (`GetBody != nil`) or absent; a non-replayable body is sent exactly once.
     Each retry rebuilds a fresh body via `GetBody` and `req.Clone(ctx)`.
   - **Context-aware:** checks `ctx` before every attempt and sleeps via a
     cancellable timer, so cancellation during backoff stops promptly and
     surfaces the last real outcome.
   - **Connection hygiene:** drains+closes the body of a retried-away response so
     keep-alive connections are reused, not leaked.
   - `Policy` (with `DefaultPolicy`: 3 retries, 500ms base, 20s cap) is
     `normalize()`d so a partially-filled policy is still well-formed. Helper
     `Client(...)` wraps an `*http.Client`'s transport.

2. **`internal/core/provider/openaicompat/openaicompat.go`** — wraps the HTTP
   client's transport with `retry.New(...)` by default (after options, so it also
   protects a transport injected via `WithHTTPClient`). Added two options:
   `WithRetryPolicy(retry.Policy)` to tune it and `WithoutRetry()` to disable it.
   No change to the `Stream`/`New` signatures callers depend on.

3. **`internal/core/provider/anthropic/anthropic.go`** — wraps the existing
   `http.Transport` (which keeps its `ResponseHeaderTimeout`) in
   `retry.New(..., retry.DefaultPolicy())`. No public surface change.

4. **Tests:**
   - New `internal/core/provider/retry/retry_test.go` — 13 tests: retry-then-
     succeed across 503/429, exhaustion, no-retry on 4xx, network-error retry,
     no-retry on `context.Canceled`, cancel-during-backoff, `Retry-After`
     (seconds + cap), `parseRetryAfter` table (incl. HTTP-date + past-date clamp),
     bounded exponential jitter, zero-retries single attempt, non-replayable body
     not retried, and the `Client` helper. All pass under `-race`.
   - Extended `openaicompat_test.go` — two end-to-end adapter tests:
     `TestStreamRetriesTransient429` (server 429s once with `Retry-After`, then
     streams; `Stream` recovers and yields the parsed text, body replayed intact)
     and `TestStreamFatal4xxNoRetry` (401 is surfaced after exactly one call).

### How verified (commands)

```sh
export PATH="$HOME/.local/go/bin:$PATH:$HOME/go/bin"; cd /home/smile/agentry
go build ./...            # BUILD_OK
go vet ./...              # VET_OK
go test ./...             # all packages ok (retry: 13 new, openaicompat: +2)
go test -race -count=1 ./...                                   # clean under race
go test -race -v ./internal/core/provider/retry/              # 13/13 PASS
gofmt -l internal/core/provider/retry internal/core/provider/{openaicompat,anthropic}/*.go  # clean
go build -o bin/agentry ./cmd/agentry

# End-to-end against the REAL binary + a local mock LLM server:
#  (a) server returns 503 + "Retry-After: 1" on the FIRST /v1/chat/completions,
#      then a valid OpenAI SSE stream on the retry.
AGENTRY_PROVIDER=openai OPENAI_BASE_URL=http://127.0.0.1:18799/v1 \
  OPENAI_API_KEY=test ./bin/agentry run "what is 2+2"
#  -> prints "4", exit 0, ~1.03s wall (the honored Retry-After), and the mock
#     log shows TWO attempts with the SAME 6824-byte body (replay verified).
#  Pre-change this same first 503 aborted the run with "http 503: overloaded".
#
#  (b) server always returns 401:
AGENTRY_PROVIDER=openai OPENAI_BASE_URL=http://127.0.0.1:18800/v1 \
  OPENAI_API_KEY=bad ./bin/agentry run "hello"
#  -> "Error: ... openaicompat: http 401: ...", exit 1, mock log shows EXACTLY
#     ONE attempt (auth failures are not retried).
```

### Result

- Both production provider adapters now ride out transient rate-limits (429),
  server overload (5xx), and pre-response network faults with jittered
  exponential backoff that honors `Retry-After`, recovering automatically instead
  of failing the whole turn. Verified end-to-end against the real binary: a 503
  becomes a successful run; a 401 still fails fast and unretried.
- Retries are correct-by-construction: replay-guarded (only rewindable bodies),
  cancellation-aware, and connection-hygienic. Default policy is conservative
  (3 retries / ≤20s cap) and fully overridable/disable-able on `openaicompat`.
- No frozen seam API changed. Build, vet, gofmt, and the full suite — including 15
  new tests — pass, all clean under `-race`.

**Follow-up identified for a later round:** the `web.fetch` tool
(`internal/tools/web`) makes outbound HTTP with its own bare client and would
benefit from the same `retry` layer; and the retry policy is currently hard-wired
to defaults rather than surfaced through `config`/`AGENTRY_*` env — exposing
`max_retries` / base / cap as configuration would let operators tune it without a
recompile.

## Round 3: MCP server protocol-version negotiation in `initialize`

**Category:** MCP protocol correctness

### Rationale

The MCP server transport (`internal/transport/mcpserver`) is one of agentry's
three platform surfaces (DESIGN §6): it lets any MCP-capable client — including
Claude Code itself — discover and invoke agentry's tools. The very first message
of every MCP session is the `initialize` handshake, whose entire purpose is
**protocol-version negotiation**.

The server got that handshake wrong. `handleInitialize` took *no parameters at
all* — it never even looked at the client's `initialize` params — and
unconditionally replied with the single hard-coded constant
`mcp.ProtocolVersion` (`"2024-11-05"`):

```go
func (s *server) handleInitialize() mcp.InitializeResult {
    return mcp.InitializeResult{ProtocolVersion: mcp.ProtocolVersion, ...}
}
```

The MCP lifecycle spec is explicit: on `initialize` the server **MUST** respond
with the *same* protocol version the client requested if it supports it, and only
otherwise fall back to a version of its own. By always echoing `2024-11-05`
regardless of input, agentry violated that rule for every modern client. Current
MCP clients negotiate newer revisions (`2025-03-26`, `2025-06-18`); a client that
asks for `2025-06-18` and receives `2024-11-05` is talking to a server that — per
the spec — is declaring it does *not* support the requested version. Strict
clients disconnect on that mismatch, and clients that branch behavior on the
negotiated version can silently mis-frame later messages. This is a real,
observable interop bug on the wire, in a different subsystem and category from
Round 1 (session persistence) and Round 2 (provider HTTP retry), with zero risk
to any frozen seam.

### What changed

1. **`internal/tools/mcp/protocol.go`** — added the negotiation primitive next to
   the protocol types so both the server and (future) client share one source of
   truth:
   - `SupportedProtocolVersions` — an explicit allow-list of the MCP revisions we
     can actually speak (`2025-06-18`, `2025-03-26`, `2024-11-05`). The wire
     subset we use (`initialize` / `tools/list` / `tools/call`) is stable across
     these, so agreeing to any of them is safe. Using an allow-list (rather than
     blindly echoing whatever string arrived) means we never claim to support a
     revision we've never heard of.
   - `NegotiateProtocolVersion(requested string) string` — implements the spec
     rule: echo the requested version when it's in the supported set; otherwise
     (unknown, malformed, or empty) return the preferred `ProtocolVersion`.
   - `ProtocolVersion` is retained unchanged (callers depend on it) but its
     doc-comment is clarified to "the version we *prefer* / fall back to."

2. **`internal/transport/mcpserver/mcpserver.go`** — `handleInitialize` now takes
   the request's raw `params`, leniently decodes them into `mcp.InitializeParams`
   (a malformed/absent payload degrades to a zero value rather than failing the
   handshake — matching the transport's existing "never crash on bad input"
   posture), and sets the reply's `protocolVersion` via
   `mcp.NegotiateProtocolVersion(p.ProtocolVersion)`. `dispatch` threads
   `msg.Params` through. The tools capability and serverInfo are unchanged.

3. **Tests:**
   - New `internal/tools/mcp/protocol_test.go` — `TestNegotiateProtocolVersion`
     (table: empty→preferred, preferred→itself, each newer supported→echoed,
     unknown future→preferred, garbage→preferred), plus two invariant guards
     (`TestSupportedProtocolVersionsIncludePreferred`,
     `TestNegotiateAllSupportedEchoBack`).
   - Extended `internal/transport/mcpserver/mcpserver_test.go` —
     `TestInitializeNegotiatesVersion` drives the real `serve` loop and asserts a
     supported newer version is echoed, an unknown one falls back to preferred,
     and an `initialize` with *no params* still yields a valid handshake — each
     also re-checking the tools capability survives negotiation. The existing
     `TestInitializeHandshake` (requests the preferred version) still passes
     unchanged.

### How verified (commands)

```sh
export PATH="$HOME/.local/go/bin:$PATH:$HOME/go/bin"; cd /home/smile/agentry
go build ./...            # BUILD_OK
go vet ./...              # VET_OK
go test ./...             # all packages ok (mcp: +3 tests, mcpserver: +1 table)
go test -race -count=1 -v -run 'Negotiate|Initialize' \
  ./internal/tools/mcp/ ./internal/transport/mcpserver/   # all PASS under -race
gofmt -l internal/tools/mcp/protocol*.go \
  internal/transport/mcpserver/mcpserver*.go              # clean
go build -o bin/agentry ./cmd/agentry

# End-to-end against the REAL binary driving `serve --mcp` over stdio:
export AGENTRY_HOME="$(mktemp -d)"

#  (a) modern client requests 2025-06-18:
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  | ./bin/agentry serve --mcp 2>/dev/null
#  -> result.protocolVersion == "2025-06-18"  (pre-change it was wrongly "2024-11-05")

#  (b) unknown version 2099-01-01:
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}' \
  | ./bin/agentry serve --mcp 2>/dev/null
#  -> result.protocolVersion == "2024-11-05" (spec-correct fallback)

#  (c) no params at all -> still a clean handshake at "2024-11-05".

#  (d) full session (negotiate 2025-03-26 -> initialized -> tools/list -> tools/call fs.list):
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fs.list","arguments":{"path":"."}}}' \
  | ./bin/agentry serve --mcp 2>/dev/null
#  -> id:1 echoes protocolVersion "2025-03-26"; the notification draws no reply;
#     id:2 lists tools; id:3 returns real directory content. No regression.
```

### Result

- The MCP server now performs spec-correct version negotiation: it echoes a
  client's requested protocol version when supported (e.g. `2025-06-18`,
  `2025-03-26`) and falls back to its preferred version only for unknown/absent
  requests. Verified end-to-end against the real binary — a `2025-06-18` request
  that previously got the wrong `2024-11-05` back now gets `2025-06-18`, while an
  unknown `2099-01-01` correctly falls back. This removes a concrete interop
  failure with current MCP clients (including Claude Code), which is exactly the
  cross-direction use case DESIGN §6 calls out.
- Adding a future revision is now a one-line edit to `SupportedProtocolVersions`;
  the negotiation rule and its tests pick it up automatically.
- No frozen seam API changed (the `mcp` additions are purely additive). Build,
  vet, gofmt, and the full suite — including 4 new tests, clean under `-race` —
  all pass.

**Follow-ups still open (from prior rounds):** apply the `retry.RoundTripper` to
the `web.fetch` outbound client and surface the retry policy via
`config`/`AGENTRY_*` env (R2); persist/resume sessions in the http and stdio
transports so resume survives process restarts (R1).

## Round 4: JSON-Schema validation of tool-call arguments (engine + MCP server)

**Category:** tool argument validation (correctness / robustness)

### Rationale

Every tool advertises a JSON Schema via `Tool.Schema()`, and the engine forwards
those schemas to the model as `ToolSpec`s — but **nothing validated the model's
arguments against them before invoking the tool.** Both places that dispatch a
tool call handed the raw, model-supplied JSON straight to `Invoke`:

- `agent.Engine.dispatch` (the reason→act→observe loop) — after the policy gate,
  it called `t.Invoke(...)` with the unvalidated args.
- `mcpserver.handleToolsCall` (the MCP **server** transport, DESIGN §6 — the
  surface a third-party MCP client such as Claude Code drives directly) — it
  invoked the tool with `normalizeArgs(p.Arguments)` and no schema check at all.

Consequences of the gap:

- **Advertised constraints were silently ignored.** `web.fetch`'s
  `max_bytes` (`minimum:1, maximum:8388608`), `shell.exec`'s `timeout_sec`
  (`maximum:120`), `web.search`'s `limit` (`maximum:20`), and every
  `additionalProperties:false` were declared to the model but never enforced —
  at best clamped deep inside a tool, at worst accepted. A model that sent
  `timeout_sec:9999` got a 120s clamp with no signal that its argument was out of
  range, so it never learned to stop doing it.
- **Inconsistent, ad-hoc per-tool checks.** `required`/type handling was
  re-implemented (partially, differently) in each tool, and a wrong-typed value
  surfaced as an opaque `json.Unmarshal` message tied to no particular field.
- **No structured, model-legible feedback** to drive self-correction: the whole
  point of advertising a schema is that a capable model can fix a rejected call,
  but only if the rejection names the offending field and constraint.

Validating once, at the dispatch chokepoint, hardens **every** tool (builtin,
web, browser, MCP-proxied, and sub-agents) uniformly and turns a malformed call
into a precise, field-anchored error the model reads and corrects from. This is a
distinct subsystem/category from R1 (session persistence), R2 (provider HTTP
retry), and R3 (MCP version negotiation), with directly observable end-to-end
behavior and zero change to any frozen seam.

### What changed

1. **New `internal/core/tool/schema.go`** — a dependency-free (stdlib-only)
   `ValidateArgs(schema, args json.RawMessage) []string` plus
   `FormatValidationProblems(toolName, problems) string`:
   - Enforces the Draft-07 subset the tools actually use: object `type` /
     `properties` / `required` / `additionalProperties:false`, scalar `type`
     (incl. `integer` accepting an integral JSON number), `enum`, numeric
     `minimum`/`maximum`/`exclusiveMinimum`/`exclusiveMaximum`, string
     `minLength`/`maxLength` (rune-counted), and array `minItems`/`maxItems`/
     `items`. Validates nested objects/array elements with a dotted/indexed path
     (`opts.timeout`, `tags[1]`) in every message.
   - **Permissive by construction** — the critical property that makes it safe to
     apply to third-party (MCP-proxied) schemas: any keyword it does not model
     (`$ref`, `oneOf`/`anyOf`/`allOf`, `pattern`, `format`, `patternProperties`,
     conditionals, …) is treated as "no opinion" and never rejects. An
     absent/empty/`true`/`false`/`null`/unparsable schema imposes nothing; a
     sub-schema-form `additionalProperties` is treated as "allowed". It never
     panics and never returns a Go error — a case it can't reason about is simply
     not reported, so validation is never *stricter* than the schema author
     intended.
   - Numbers decode via `json.Number` (no float precision loss in messages);
     `enum` compares through canonical JSON so a `json.Number` matches a numeric
     literal.

2. **`internal/core/agent/engine.go`** — `dispatch` now calls
   `tool.ValidateArgs(t.Schema(), args)` **after** the policy gate and **before**
   `Invoke`; a non-empty problem set becomes an error tool_result
   (`tool.FormatValidationProblems`) and the tool is not run. (A removed local
   `formatArgProblems` was promoted into the shared `tool` helper.)

3. **`internal/transport/mcpserver/mcpserver.go`** — `handleToolsCall` applies
   the same validation before `safeInvoke`, returning an MCP `CallToolResult`
   with `isError:true` carrying the field-anchored message, so an MCP client's
   model gets the same correction signal the agent loop does. (This closes a real
   coverage gap: the MCP-server `tools/call` path bypasses `engine.dispatch`.)

4. **Tests (20 new):**
   - `internal/core/tool/schema_test.go` — 18 cases: no-schema/empty/boolean
     permissiveness, empty-args-all-optional, invalid-JSON args, required,
     type-mismatch (incl. root), integer integral-vs-fraction, min/max,
     exclusive bounds, `additionalProperties:false` (and the true/absent allow
     case), enum, string min/max length (rune-aware), array items + bounds (with
     indexed path), nested-object path, **unmodeled-keywords-are-permissive**
     ($ref/oneOf/pattern/format), `type` as a union array, and all-problems-
     reported-together.
   - `internal/core/agent/engine_test.go` —
     `TestRun_SchemaValidationRejectsBadArgs` drives the real `Run` loop: turn 1
     emits a schema-violating `web.fetch` call (over-max + unknown prop) → the
     engine rejects it without invoking, turn 2 emits a corrected call that runs
     exactly once, turn 3 finalizes; asserts the rejection text names the
     not-executed call, the maximum, and the bad property.
   - `internal/transport/mcpserver/mcpserver_test.go` —
     `TestToolsCallSchemaValidation`: a `tools/call` for `echo` missing its
     required `text` returns `isError:true` with the validation message and the
     tool's own output never appears.

### How verified (commands)

```sh
export PATH="$HOME/.local/go/bin:$PATH:$HOME/go/bin"; cd /home/smile/agentry
go build ./...            # BUILD PASS
go vet ./...              # VET PASS
go test ./...             # all packages ok (tool +18, agent +1, mcpserver +1)
go test -race -count=1 ./...                                    # clean under -race
go test -race -count=1 -v -run 'ValidateArgs|SchemaValidation|ToolsCallSchema' \
  ./internal/core/tool/ ./internal/core/agent/ ./internal/transport/mcpserver/  # 20/20 PASS
gofmt -l internal/core/tool/schema*.go internal/core/agent/engine*.go \
  internal/transport/mcpserver/mcpserver*.go                   # clean
go build -o bin/agentry ./cmd/agentry

# End-to-end against the REAL binary driving `serve --mcp` over stdio:
export AGENTRY_HOME="$(mktemp -d)"

# (1) fs.read with a wrong-typed path (number; schema wants string):
#   -> isError:true, "path: expected type string, got number"  (tool NOT run)
# (2) shell.exec timeout_sec=9999 (schema maximum 120):
#   -> isError:true, "timeout_sec: 9999 is greater than the maximum 120"
#      (pre-change this was silently clamped to 120 and the command ran)
# (3) web.fetch max_bytes=99999999 + unknown prop "junk" (additionalProperties:false):
#   -> isError:true, BOTH reported: unknown property "junk" + over the 8388608 max
# (4) CONTROL: fs.read {"path":"go.mod"} -> isError:None, returns file content
#     (valid calls are unaffected; no regression).
```

### Result

- Tool-call arguments are now validated against the advertised JSON Schema at
  both dispatch chokepoints — the agent loop (`engine.dispatch`) and the MCP
  server (`handleToolsCall`) — so a malformed call (missing/wrong-typed/out-of-
  range/disallowed-extra) becomes a clear, field-anchored, model-legible error
  *before any side effect*, uniformly for every tool. Verified end-to-end against
  the real binary: out-of-range `timeout_sec`/`max_bytes`, wrong-typed `path`,
  and unknown properties are all rejected with precise messages, while valid
  calls run unchanged.
- The validator is permissive by design (only the understood subset rejects), so
  third-party MCP-proxied tools with exotic schemas are never falsely rejected.
- No frozen seam API changed (the `tool` additions are purely additive). Build,
  vet, gofmt, and the full suite — including 20 new tests, clean under `-race` —
  all pass.

**Follow-ups still open (from prior rounds):** apply the `retry.RoundTripper` to
the `web.fetch` outbound client and surface the retry policy via
`config`/`AGENTRY_*` env (R2); persist/resume sessions in the http and stdio
transports so resume survives process restarts (R1).

## Round 5: Retry-harden the web tool family + surface retry/web tunables via config/AGENTRY_* env

**Category:** robustness / HTTP retry+backoff + timeouts + configuration surface

### Rationale

This closes the long-standing follow-up flagged at the end of R2 (and re-flagged
each round since): the `web` tool family (`web.fetch` / `web.extract` /
`web.search`) made outbound HTTP through a client with **no retry** and, worse,
**built a brand-new `http.Transport` on every single call** (`newSafeClient()`
was invoked inside `doFetch`) — so there was zero connection reuse and every
transient blip (a 429 rate-limit, a 503 overload, a connection reset before
headers) failed the tool call outright. Meanwhile both provider adapters got
jittered exponential-backoff retry in R2, leaving the web tools as the only
outbound-HTTP path in the binary with no resilience.

Separately, a whole set of operational knobs were hard-wired as Go constants and
could only be changed by recompiling: the provider/web retry policy
(`max_retries` / base / cap — pinned to `retry.DefaultPolicy`), and the
`web.fetch` request timeout (15s), redirect cap (5), and body ceiling (8 MiB).
DESIGN §12 promises layered config (defaults → file → `AGENTRY_*` env → flags),
but none of these were reachable through it.

Fixing both together is high-leverage and self-contained: the web tools become
resilient *and* connection-pooled, and operators can tune retry/timeout/redirect/
size behavior — for **both** the provider adapters and the web tools — without a
rebuild. It is a distinct subsystem/category from R1 (session persistence), R3
(MCP version negotiation), and R4 (schema validation), with directly observable
end-to-end behavior and zero change to any frozen seam.

### What changed

1. **`internal/config/config.go`** — added two config blocks and an accessor,
   wired through every layer:
   - `RetryConfig{MaxRetries, BaseMs, CapMs}` and `WebConfig{TimeoutMs,
     MaxRedirects, MaxBytes}` fields on `Config` (JSON keys `retry` / `web`),
     merged in `applyFile` (only non-zero file fields override) and overlaid in
     `applyEnv` from new env vars `AGENTRY_RETRY_MAX_RETRIES`,
     `AGENTRY_RETRY_BASE_MS`, `AGENTRY_RETRY_CAP_MS`, `AGENTRY_WEB_TIMEOUT_MS`,
     `AGENTRY_WEB_MAX_REDIRECTS`, `AGENTRY_WEB_MAX_BYTES`.
   - A new `atoiEnv` helper parses integer env values **defensively**: a
     present-but-unparseable value is *ignored* (leaves the field at its prior
     value) so a typo never crashes startup.
   - `(*Config).RetryPolicy() retry.Policy` maps the ms-based config onto a
     `retry.Policy` (durations); fields left unset stay zero, which
     `retry.Policy.normalize()` fills with retry's own defaults downstream — so
     an unconfigured deployment behaves exactly as before this knob existed.
   - `config` now imports `internal/core/provider/retry` (stdlib-only; no cycle).

2. **`internal/tools/web/web.go`** — replaced the per-call fresh transport with a
   **shared, retried, connection-pooled** client:
   - A package-level `Config{RequestTimeout, MaxRedirects, HardMaxBytes, Retry}`
     (defaulting to the historical constants + `retry.DefaultPolicy()`) plus a
     `Configure(Config)` entry point that merges overrides and rebuilds one
     shared `*http.Client`. `snapshot()` returns the `(config, client)` pair
     under an `RWMutex` so an in-flight `Invoke` never splits the timeout from
     the client even if `Configure` races.
   - `newSafeClient()` → `buildClient(c Config)`: the SSRF-screening dialer is
     unchanged, but the transport is now wrapped in `retry.New(base, c.Retry)`,
     so each individual hop (the GET and each redirect) rides out a transient
     429/5xx/network error with backoff (GET has no body ⇒ always replayable).
     The redirect cap is read from config.
   - `doFetch` / `web.extract` inline-HTML cap / `describeFetchError` now read the
     effective bounds from `snapshot()` instead of the old constants.
   - Introduced one tiny test seam: `var screenIP = isBlockedIP` (used by both
     `validateURL` and `safeDialControl`) so tests can point the tools at a
     loopback `httptest` server (normally SSRF-blocked) to exercise the
     retry/redirect machinery. Production never reassigns it; the screen is
     byte-for-byte the same.

3. **`cmd/agentry/main.go`** — `buildEngine` now threads the resolved policy
   through: `selectProvider(..., cfg.RetryPolicy())` passes it to
   `openaicompat.New(..., WithRetryPolicy(rp))`, and a new `configureWebTools(cfg)`
   pushes the web bounds + retry policy into the `web` package. Zero/unset fields
   preserve the built-in defaults.

4. **Tests (7 new):**
   - `internal/tools/web/config_test.go` — `TestFetchRetriesTransient503` (server
     503s once then succeeds → the tool transparently retries; server hit
     **exactly twice**, proving retry is wired into the web client),
     `TestFetchDoesNotRetry4xx` (404 ⇒ exactly one request), and
     `TestConfigureMaxRedirectsCap` / `TestConfigureBodyCap` (runtime config
     actually tightens the redirect chain and the body ceiling). A `withLocalScreen`
     helper relaxes the SSRF screen and restores both it and the package config
     after each test.
   - `internal/config/config_test.go` — `TestEnvOverridesRetryAndWeb` (all six
     `AGENTRY_*` ints populate the blocks; a garbage int is ignored, not fatal),
     `TestRetryPolicyMapping` (ms→Duration mapping; unset ⇒ zero durations), and
     `TestFileMergesRetryAndWeb` (JSON file round-trips and env still wins over
     file).

### How verified (commands)

```sh
export PATH="$HOME/.local/go/bin:$PATH:$HOME/go/bin"; cd /home/smile/agentry
go build ./...            # BUILD OK
go vet ./...              # VET OK
go test ./...             # all packages ok (web +4, config +3)
go test -race -count=1 ./internal/tools/web/ ./internal/config/   # clean under -race
gofmt -l internal/config/config.go internal/config/config_test.go \
  internal/tools/web/web.go internal/tools/web/config_test.go cmd/agentry/main.go  # clean
go build -o bin/agentry ./cmd/agentry

# End-to-end against the REAL binary:

# (a) web tools still register and the new AGENTRY_* env is accepted:
./bin/agentry tools list | grep -E 'web\.(fetch|extract|search)'   # all 3 present
AGENTRY_RETRY_MAX_RETRIES=5 AGENTRY_WEB_TIMEOUT_MS=2000 ./bin/agentry run "say hi"  # exit 0

# (b) web.fetch over `serve --mcp`: loopback is still SSRF-blocked (production
#     screen byte-identical; the new shared-client path is on):
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"web.fetch","arguments":{"url":"http://127.0.0.1:9/"}}}' \
  | ./bin/agentry serve --mcp
#  -> isError:true, "web.fetch: refused (SSRF guard): ... 127.0.0.1 is not allowed"

# (c) PROVIDER retry driven by AGENTRY_RETRY_* end-to-end (mock OpenAI server
#     503s once with Retry-After:1, then streams):
AGENTRY_PROVIDER=openai OPENAI_BASE_URL=http://127.0.0.1:18955/v1 OPENAI_API_KEY=test \
  AGENTRY_RETRY_MAX_RETRIES=3 AGENTRY_RETRY_BASE_MS=50 AGENTRY_RETRY_CAP_MS=2000 \
  ./bin/agentry run "what is the answer"
#  -> mock logs "attempt 1" (503) then "attempt 2" (success); prints "42"; exit 0.
#
#     The env VALUE is consumed (not the hardcoded default): against a server
#     that always 503s, AGENTRY_RETRY_MAX_RETRIES=0 -> exactly 1 provider attempt,
#     AGENTRY_RETRY_MAX_RETRIES=2 -> exactly 3 attempts (1 initial + 2 retries).
```

### Result

- The web tool family now rides out transient 429/5xx/network failures on every
  hop with jittered exponential backoff (honoring `Retry-After`) and reuses a
  single pooled HTTP client instead of building a fresh transport per call —
  proven by a unit test where a 503-then-200 server is hit exactly twice and the
  fetch still succeeds, while a 404 is hit exactly once (4xx never retried).
- Retry policy (`max_retries`/base/cap) for **both** the provider adapters and
  the web tools, plus the `web.fetch` timeout / redirect cap / body ceiling, are
  now operator-tunable via the config file and `AGENTRY_*` env — closing the R2
  follow-up. Verified end-to-end against the real binary: a provider 503 becomes
  a successful run under `AGENTRY_RETRY_*`, and the retry count tracks the env
  value (0 ⇒ 1 attempt, 2 ⇒ 3 attempts).
- An unconfigured deployment is byte-for-byte unchanged (defaults preserved), the
  SSRF guard is identical in production (loopback still blocked end-to-end), and
  no frozen seam API changed. Build, vet, gofmt, and the full suite — including 7
  new tests, clean under `-race` — all pass.

**Follow-ups still open (from prior rounds):** persist/resume sessions in the
http and stdio transports so resume survives process restarts (R1). The MCP
server's preferred protocol version (R3) and the `web.search` backend URL remain
the two remaining un-surfaced config knobs if a future round wants full coverage.

## Round 6: Persist + resume sessions in the http and stdio transports

**Category:** missing feature / durability (DESIGN↔code gap — Session seam on the platform surface)

### Rationale

This closes the very first follow-up flagged at the end of Round 1 and re-flagged
in every round since: the `http` and `stdio` transports — two of agentry's three
platform surfaces (DESIGN §6) — held sessions **purely in an in-memory map**, so
a conversation driven over the platform vanished the instant the process exited
and could never be resumed. That directly contradicts DESIGN §1 tenet 7
("Resumable & observable") and §4.4 ("Append-only event log … persisted as JSONL
… Enables resume"), which R1 made real **only for the one-shot `run` path**.

Concretely, before this round:

- `stdio` `serve` built `sessions: map[string]*session.Session{}` and never
  touched disk. `session.create` minted an id; nothing was saved; nothing could
  be loaded. A restart lost everything.
- `http` `NewHandler` did the same with a per-process monotonic id ("s1", "s2",
  …); its own doc-comment conceded "durability is out of scope for this
  transport" / "durable persistence is … layered elsewhere" — but it never was.
- A session created over either transport was **invisible to `agentry session
  ls|show`** (R1), even though those commands read the exact same
  `<AGENTRY_HOME>/sessions` directory — because the transports wrote nothing
  there. The platform surface and the CLI surface didn't share state.

The R1 `JSONLStore` (atomic write, path-traversal-guarded, torn-line-tolerant,
sequence-resuming) already existed and was production-proven; the only missing
piece was *wiring it into the two long-lived transports* plus a resume entry
point. That is high-leverage, self-contained, and observable end-to-end, and it
is a genuinely different subsystem/category from R2–R5 (provider retry, MCP
negotiation, schema validation, web-tool retry/config).

### What changed

1. **`internal/transport/stdio/stdio.go`** — durable, resumable sessions:
   - Added a narrow `SessionStore` interface (`Save` + `Load` only — no `List`,
     since the transport doesn't need it) satisfied by `*session.JSONLStore` and
     by any test double. `nil` disables persistence (in-memory mode = exact prior
     behavior).
   - `server` gained a `store` field. New public `ServeWithStore(ctx, eng, store)`;
     the existing `Serve(ctx, eng)` now delegates with a `nil` store, so no caller
     breaks and the in-memory default is byte-for-byte unchanged. The testable
     `serve` core takes the store as a new parameter.
   - `session.create` now decodes `{"resume":"<id>"}`: it rehydrates the session
     from memory or the store (replying `{"id","resumed":true}`), and **errors
     (`-32602`) on an unknown id** rather than silently fabricating an empty
     session under it. A plain create persists the new session immediately (so it
     shows up in `session ls`) and replies `{"id","resumed":false}`.
   - `resolveSession` now consults memory → store → create, so even a
     `session.prompt` naming a not-in-memory id resumes a persisted conversation.
   - Every `session.prompt` persists the (updated) session after the run,
     best-effort (a save failure only warns on stderr; it never turns a good run
     into an error). Concurrency-safe `loadFromStore` re-checks under the lock so
     two requests never register divergent copies of the same id.

2. **`internal/transport/http/http.go`** — the same capability over REST/SSE:
   - Added the matching `SessionStore` interface, a `store` field, and
     `ServeWithStore` / `NewHandlerWithStore`; `Serve` / `NewHandler` delegate
     with `nil` (unchanged default).
   - `POST /v1/sessions` now accepts an optional `{"resume":"<id>"}` body
     (size-capped, parsed leniently so a bodyless create still works): it
     rehydrates a persisted session (→ `{"id","resumed":true}`) or 404s on an
     unknown id. A plain create persists immediately and returns
     `{"id","resumed":false}` (the `id` field is preserved; `resumed` is purely
     additive, so existing clients are unaffected).
   - `POST /v1/sessions/{id}/messages` **rehydrates from the store on an
     in-memory miss** before 404ing, so a client that kept its id across a server
     restart can keep talking with no explicit resume call. The session is
     persisted after each run completes (before the terminal `done` event, so a
     client that immediately resumes finds the latest history on disk).
   - Added concurrency-safe `resume(id)` (memory → store, race-checked) and a
     best-effort `persist`.

3. **`cmd/agentry/main.go`** — `serve --http` and `serve --stdio` now pass
   `sessionStore()` (the same on-disk `JSONLStore` rooted at
   `<AGENTRY_HOME>/sessions` that `run` and `session ls|show` already use) via the
   new `ServeWithStore` entry points. The platform and CLI surfaces now share one
   durable store, so a session created over a transport is listable/showable and
   vice-versa.

4. **Tests (8 new, all clean under `-race`):**
   - `internal/transport/stdio/stdio_test.go` —
     `TestSessionPersistsAndResumesAcrossRestart` (a session created+prompted via
     one `serve` invocation is resumed by a *second, fresh* invocation sharing
     only the on-disk store; asserts `resumed:true` and that the pre-restart user
     turn survives in the reloaded history), `TestResumeUnknownSessionErrors`
     (unknown id → `-32602`), and `TestCreateWithoutStoreNoPersistError` (nil
     store: plain create still works, resume errors cleanly, never panics). The
     existing `serve` helpers were updated to pass a `nil` store.
   - `internal/transport/http/http_test.go` —
     `TestSessionPersistsAndResumesAcrossRestart` (two independent `httptest`
     servers sharing one store: create+message on #1, resume on #2, then assert
     *both* the pre-restart and post-resume user turns are persisted),
     `TestPostMessageRehydratesFromStore` (messaging a store-only id returns 200
     by rehydrating, not 404), `TestResumeUnknownSession404`, and
     `TestCreateSessionNoStoreStillWorks` (default path: 201 + `resumed:false`).

No frozen seam API changed: the `session` package is untouched; both transports
only *added* `ServeWithStore`/`NewHandlerWithStore` and a local `SessionStore`
interface, and `Serve`/`NewHandler` keep their signatures and in-memory default.

### How verified (commands)

```sh
export PATH="$HOME/.local/go/bin:$PATH:$HOME/go/bin"; cd /home/smile/agentry
go build ./...            # BUILD_PASS
go vet ./...              # VET_PASS
go test ./...             # all 17 packages ok, exit 0 (stdio +3, http +4 tests)
go test -race -count=1 -v -run 'Persist|Resume|Rehydrate|NoStore|NoPersist|CreateSession|CreateWithout' \
  ./internal/transport/stdio/ ./internal/transport/http/   # all PASS under -race
gofmt -l internal/transport/ cmd/agentry/main.go           # clean
go build -o bin/agentry ./cmd/agentry

# End-to-end against the REAL binary — STDIO resume across a real process restart:
export AGENTRY_HOME="$(mktemp -d)"
# process #1: create, then (separate process) prompt
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"session.create"}' | ./bin/agentry serve --stdio
#   -> {"result":{"id":"s1","resumed":false}}
printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"session.prompt","params":{"session_id":"s1","input":"remember the codeword is PINEAPPLE"}}' \
  | ./bin/agentry serve --stdio                      # persists s1.jsonl (0600) on disk
# process #2 (a brand-new process = restart): resume by id
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"session.create","params":{"resume":"s1"}}' | ./bin/agentry serve --stdio
#   -> {"result":{"id":"s1","resumed":true}}
./bin/agentry session show s1                        # transcript shows the PINEAPPLE user turn
#   (pre-change: s1 never existed on disk; resume + session show were impossible)

# End-to-end — HTTP resume across a real SERVER restart (same AGENTRY_HOME):
./bin/agentry serve --http --addr 127.0.0.1:18866 &  # process #1
curl -sX POST .../v1/sessions                        # {"id":"s1","resumed":false}
curl -sN -X POST .../v1/sessions/s1/messages -d '{"input":"the secret fruit is DURIAN"}'   # done
kill %1                                              # restart
./bin/agentry serve --http --addr 127.0.0.1:18866 &  # process #2, same store
curl -sX POST .../v1/sessions -d '{"resume":"s1"}'   # {"id":"s1","resumed":true}
curl -sN -X POST .../v1/sessions/s1/messages -d '{"input":"and also MANGOSTEEN"}'           # done
./bin/agentry session show s1                        # BOTH DURIAN and MANGOSTEEN present
curl -s -o/dev/null -w '%{http_code}' -X POST .../v1/sessions/s1/messages -d '{"input":"ping"}'  # 200 (rehydrate-on-miss, not 404)

# Negative / compat:
#   stdio resume unknown id  -> error -32602 "cannot resume unknown session"
#   http  resume unknown id  -> 404;  message unknown id -> 404;  bodyless create -> 201 resumed:false
#   `agentry run` + `session ls` still work AND now interoperate: `session ls`
#   lists both the run-* session and the transport's "s1" in the same store.
```

### Result

- Sessions on the `http` and `stdio` platform surfaces are now durable and
  resumable: created/updated sessions are persisted to the same
  `<AGENTRY_HOME>/sessions` JSONL store the CLI uses, and a prior conversation can
  be resumed after a full process restart — via `session.create {"resume":<id>}`
  (stdio) / `POST /v1/sessions {"resume":<id>}` (http), or implicitly by
  addressing a not-in-memory id (a stdio `session.prompt` or an http message
  rehydrates from disk). Proven end-to-end against the real binary across two
  independent processes for *both* transports, with multi-turn history intact.
- The platform and CLI surfaces finally share one source of truth: a session born
  over a transport is now visible to `agentry session ls|show`, and unknown-id
  resumes fail cleanly (-32602 / 404) instead of silently inventing empty
  sessions. This makes DESIGN §1.7 / §4.4 "resumable & observable" real on the
  platform surface, not just the one-shot `run` path — finally closing the R1
  follow-up.
- Fully backward-compatible: `Serve`/`NewHandler` keep their signatures and the
  exact in-memory default; the only wire change is an additive `resumed` field on
  the create reply (the `id` field is unchanged). No frozen seam API changed.
  Build, vet, gofmt, and the full suite — including 8 new tests, clean under
  `-race` — all pass.

**Follow-ups still open (from prior rounds):** the MCP server's preferred
protocol version (R3) and the `web.search` backend URL remain the two un-surfaced
config knobs; applying `retry.RoundTripper` to the MCP **client's** outbound HTTP
transport (if/when it makes one) would extend R2/R5's retry consistency to that
last outbound path.
