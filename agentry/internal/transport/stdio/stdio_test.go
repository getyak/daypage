package stdio

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/kubbot/agentry/internal/core/agent"
	"github.com/kubbot/agentry/internal/core/provider/mock"
	"github.com/kubbot/agentry/internal/core/session"
	"github.com/kubbot/agentry/internal/core/tool"
)

// runLinesStore feeds input lines through serve backed by the given store and
// returns the decoded output objects. It models one process lifetime; calling it
// again with the same store models a restart that shares durable state but not
// the in-memory session map.
func runLinesStore(t *testing.T, eng *agent.Engine, store SessionStore, lines ...string) []map[string]any {
	t.Helper()
	in := strings.NewReader(strings.Join(lines, "\n") + "\n")
	var out strings.Builder
	if err := serve(context.Background(), eng, in, &out, store); err != nil {
		t.Fatalf("serve returned error: %v", err)
	}
	return decodeAll(t, out.String())
}

// echoTool is a trivial tool used to verify tools.list reporting.
type echoTool struct{}

func (echoTool) Name() string            { return "echo" }
func (echoTool) Description() string     { return "echoes its input" }
func (echoTool) Schema() json.RawMessage { return json.RawMessage(`{"type":"object"}`) }
func (echoTool) Invoke(_ context.Context, in tool.Input) (tool.Result, error) {
	return tool.Result{Content: string(in.Args)}, nil
}

// newTestEngine builds an Engine backed by the deterministic mock provider and a
// registry containing the echo tool, so tests never touch the network.
func newTestEngine(script ...mock.Step) *agent.Engine {
	reg := tool.NewRegistry()
	reg.MustRegister(echoTool{})
	return agent.New(mock.New(script...), reg, nil, "test-model")
}

// runLines feeds the given input lines through serve and returns the decoded
// response/notification objects written to stdout, in order.
func runLines(t *testing.T, eng *agent.Engine, lines ...string) []map[string]any {
	t.Helper()
	in := strings.NewReader(strings.Join(lines, "\n") + "\n")
	var out strings.Builder
	if err := serve(context.Background(), eng, in, &out, nil); err != nil {
		t.Fatalf("serve returned error: %v", err)
	}
	return decodeAll(t, out.String())
}

// decodeAll parses every newline-delimited JSON object emitted by the server.
func decodeAll(t *testing.T, s string) []map[string]any {
	t.Helper()
	var msgs []map[string]any
	dec := json.NewDecoder(strings.NewReader(s))
	for dec.More() {
		var m map[string]any
		if err := dec.Decode(&m); err != nil {
			t.Fatalf("decoding server output %q: %v", s, err)
		}
		msgs = append(msgs, m)
	}
	return msgs
}

// TestToolsList is the required smoke test: feed a tools.list request and verify
// the response lists the registered tool with name+description.
func TestToolsList(t *testing.T) {
	eng := newTestEngine()
	msgs := runLines(t, eng, `{"jsonrpc":"2.0","id":1,"method":"tools.list"}`)

	if len(msgs) != 1 {
		t.Fatalf("expected exactly 1 response, got %d: %+v", len(msgs), msgs)
	}
	resp := msgs[0]
	if resp["jsonrpc"] != "2.0" {
		t.Errorf("jsonrpc = %v, want 2.0", resp["jsonrpc"])
	}
	if resp["id"] != float64(1) {
		t.Errorf("id = %v, want 1", resp["id"])
	}
	if _, hasErr := resp["error"]; hasErr {
		t.Fatalf("unexpected error in response: %+v", resp)
	}
	result, ok := resp["result"].([]any)
	if !ok {
		t.Fatalf("result is not an array: %T %+v", resp["result"], resp["result"])
	}
	if len(result) != 1 {
		t.Fatalf("expected 1 tool, got %d: %+v", len(result), result)
	}
	tool0 := result[0].(map[string]any)
	if tool0["name"] != "echo" {
		t.Errorf("tool name = %v, want echo", tool0["name"])
	}
	if tool0["description"] != "echoes its input" {
		t.Errorf("tool description = %v, want %q", tool0["description"], "echoes its input")
	}
}

// TestSessionCreate verifies session.create returns a non-empty id.
func TestSessionCreate(t *testing.T) {
	eng := newTestEngine()
	msgs := runLines(t, eng, `{"jsonrpc":"2.0","id":7,"method":"session.create","params":{}}`)
	if len(msgs) != 1 {
		t.Fatalf("expected 1 response, got %d", len(msgs))
	}
	result, ok := msgs[0]["result"].(map[string]any)
	if !ok {
		t.Fatalf("result not an object: %+v", msgs[0])
	}
	if id, _ := result["id"].(string); id == "" {
		t.Errorf("session id is empty: %+v", result)
	}
}

// TestSessionPromptStreams drives a full prompt: the mock provider replies with
// plain text, and we assert that (a) a session.event notification is streamed for
// the assistant text and (b) the final response carries that text.
func TestSessionPromptStreams(t *testing.T) {
	eng := newTestEngine(mock.Text("hello world"))
	msgs := runLines(t, eng, `{"jsonrpc":"2.0","id":2,"method":"session.prompt","params":{"input":"hi"}}`)

	var (
		sawUserEvent      bool
		sawAssistantEvent bool
		final             map[string]any
	)
	for _, m := range msgs {
		switch m["method"] {
		case "session.event":
			params, _ := m["params"].(map[string]any)
			switch params["type"] {
			case "user":
				sawUserEvent = true
			case "assistant":
				sawAssistantEvent = true
				if params["text"] != "hello world" {
					t.Errorf("assistant event text = %v, want %q", params["text"], "hello world")
				}
			}
			if _, hasID := m["id"]; hasID {
				t.Errorf("notification must not carry an id: %+v", m)
			}
		default:
			if m["id"] == float64(2) {
				final = m
			}
		}
	}

	if !sawUserEvent {
		t.Error("expected a streamed user session.event")
	}
	if !sawAssistantEvent {
		t.Error("expected a streamed assistant session.event")
	}
	if final == nil {
		t.Fatalf("no final response for id=2; got %+v", msgs)
	}
	result, ok := final["result"].(map[string]any)
	if !ok {
		t.Fatalf("final result not an object: %+v", final)
	}
	if result["text"] != "hello world" {
		t.Errorf("final text = %v, want %q", result["text"], "hello world")
	}
	if sid, _ := result["session_id"].(string); sid == "" {
		t.Error("final result missing session_id")
	}
}

// TestPromptReusesSession verifies that session.create followed by a
// session.prompt referencing that id drives the same session (history persists).
func TestPromptReusesSession(t *testing.T) {
	// Two scripted text turns: one per prompt.
	eng := newTestEngine(mock.Text("first"), mock.Text("second"))

	// Create a session, capture its id, then prompt it twice.
	createMsgs := runLines(t, eng, `{"jsonrpc":"2.0","id":1,"method":"session.create"}`)
	id := createMsgs[0]["result"].(map[string]any)["id"].(string)

	// Run both prompts through one serve invocation so the session map persists.
	in := strings.NewReader(
		`{"jsonrpc":"2.0","id":1,"method":"session.create"}` + "\n" +
			`{"jsonrpc":"2.0","id":2,"method":"session.prompt","params":{"session_id":"` + id + `","input":"a"}}` + "\n" +
			`{"jsonrpc":"2.0","id":3,"method":"session.prompt","params":{"session_id":"` + id + `","input":"b"}}` + "\n")
	var out strings.Builder
	if err := serve(context.Background(), eng, in, &out, nil); err != nil {
		t.Fatalf("serve: %v", err)
	}
	msgs := decodeAll(t, out.String())

	// Collect the two final responses and check they used the same session id.
	finals := map[float64]map[string]any{}
	for _, m := range msgs {
		if _, isNote := m["method"]; isNote {
			continue
		}
		if idv, ok := m["id"].(float64); ok {
			finals[idv] = m
		}
	}
	r2, ok2 := finals[2]
	r3, ok3 := finals[3]
	if !ok2 || !ok3 {
		t.Fatalf("missing prompt responses: %+v", finals)
	}
	sid2 := r2["result"].(map[string]any)["session_id"]
	sid3 := r3["result"].(map[string]any)["session_id"]
	if sid2 != id || sid3 != id {
		t.Errorf("prompts used session ids %v / %v, want %v", sid2, sid3, id)
	}
}

// TestMalformedAndUnknown checks robustness: a non-JSON line yields a parse
// error, an unknown method yields method-not-found, and a blank line is skipped.
// Crucially, the server keeps serving subsequent valid requests.
func TestMalformedAndUnknown(t *testing.T) {
	eng := newTestEngine()
	msgs := runLines(t, eng,
		`this is not json`,
		``, // blank: skipped
		`{"jsonrpc":"2.0","id":5,"method":"no.such.method"}`,
		`{"jsonrpc":"2.0","id":6,"method":"tools.list"}`,
	)

	// Expect: parse error (id null), method-not-found (id 5), success (id 6).
	if len(msgs) != 3 {
		t.Fatalf("expected 3 responses, got %d: %+v", len(msgs), msgs)
	}

	// Parse error: id is null, error code -32700.
	if msgs[0]["id"] != nil {
		t.Errorf("parse-error id = %v, want null", msgs[0]["id"])
	}
	if e := msgs[0]["error"].(map[string]any); e["code"].(float64) != codeParseError {
		t.Errorf("parse-error code = %v, want %d", e["code"], codeParseError)
	}

	// Method not found: id 5, code -32601.
	if msgs[1]["id"] != float64(5) {
		t.Errorf("method-not-found id = %v, want 5", msgs[1]["id"])
	}
	if e := msgs[1]["error"].(map[string]any); e["code"].(float64) != codeMethodNotFound {
		t.Errorf("method-not-found code = %v, want %d", e["code"], codeMethodNotFound)
	}

	// The valid request after the bad ones still succeeds.
	if msgs[2]["id"] != float64(6) {
		t.Errorf("final id = %v, want 6", msgs[2]["id"])
	}
	if _, hasErr := msgs[2]["error"]; hasErr {
		t.Errorf("final request should succeed, got error: %+v", msgs[2])
	}
}

// TestPromptMissingInput verifies invalid-params handling when input is absent.
func TestPromptMissingInput(t *testing.T) {
	eng := newTestEngine()
	msgs := runLines(t, eng, `{"jsonrpc":"2.0","id":9,"method":"session.prompt","params":{}}`)
	if len(msgs) != 1 {
		t.Fatalf("expected 1 response, got %d", len(msgs))
	}
	e, ok := msgs[0]["error"].(map[string]any)
	if !ok {
		t.Fatalf("expected an error response, got %+v", msgs[0])
	}
	if e["code"].(float64) != codeInvalidParams {
		t.Errorf("code = %v, want %d", e["code"], codeInvalidParams)
	}
}

// TestNotificationNoReply verifies that a request without an id (a JSON-RPC
// notification) produces no response line.
func TestNotificationNoReply(t *testing.T) {
	eng := newTestEngine()
	// tools.list as a notification (no id) — must yield nothing on stdout.
	msgs := runLines(t, eng, `{"jsonrpc":"2.0","method":"tools.list"}`)
	if len(msgs) != 0 {
		t.Fatalf("expected no responses for a notification, got %+v", msgs)
	}
}

// TestSessionPersistsAndResumesAcrossRestart is the headline persistence test:
// a prompt run through one serve invocation (process #1) is reloadable by a
// second, fresh serve invocation (process #2) that shares only the on-disk store
// — proving resume survives a process restart, not just an in-memory map.
func TestSessionPersistsAndResumesAcrossRestart(t *testing.T) {
	store := session.NewJSONLStore(t.TempDir())

	// --- process #1: create a session, prompt it, then it exits. ---
	eng1 := newTestEngine(mock.Text("the-first-answer"))
	msgs1 := runLinesStore(t, eng1, store,
		`{"jsonrpc":"2.0","id":1,"method":"session.create"}`,
	)
	id := msgs1[0]["result"].(map[string]any)["id"].(string)
	if id == "" {
		t.Fatal("empty session id from create")
	}
	// Prompt it (separate invocation is fine; resolveSession will load from store).
	runLinesStore(t, eng1, store,
		`{"jsonrpc":"2.0","id":2,"method":"session.prompt","params":{"session_id":"`+id+`","input":"remember pineapple"}}`,
	)

	// The store must now hold the session with its history on disk.
	persisted, err := store.Load(id)
	if err != nil {
		t.Fatalf("store.Load(%q) after run: %v", id, err)
	}
	if len(persisted.Events()) == 0 {
		t.Fatalf("persisted session %q has no events", id)
	}

	// --- process #2: a brand-new server (empty session map) resumes by id. ---
	eng2 := newTestEngine(mock.Text("the-second-answer"))
	msgs2 := runLinesStore(t, eng2, store,
		`{"jsonrpc":"2.0","id":1,"method":"session.create","params":{"resume":"`+id+`"}}`,
	)
	res := msgs2[0]["result"].(map[string]any)
	if res["id"] != id {
		t.Errorf("resume returned id %v, want %v", res["id"], id)
	}
	if res["resumed"] != true {
		t.Errorf("resume flag = %v, want true", res["resumed"])
	}

	// And the resumed session's prior history is visible to the next prompt:
	// the user's first turn ("remember pineapple") is present in History(), so
	// the conversation truly continued rather than starting blank.
	resumed, err := store.Load(id)
	if err != nil {
		t.Fatalf("reload resumed session: %v", err)
	}
	var sawPineapple bool
	for _, ev := range resumed.Events() {
		if ev.Type == session.EvUser && strings.Contains(ev.Text, "pineapple") {
			sawPineapple = true
		}
	}
	if !sawPineapple {
		t.Errorf("resumed session lost its prior user turn; events=%+v", resumed.Events())
	}
}

// TestResumeUnknownSessionErrors verifies that asking to resume an id that does
// not exist in memory or the store is rejected (invalid params) rather than
// silently creating an empty session under that id.
func TestResumeUnknownSessionErrors(t *testing.T) {
	store := session.NewJSONLStore(t.TempDir())
	eng := newTestEngine()
	msgs := runLinesStore(t, eng, store,
		`{"jsonrpc":"2.0","id":1,"method":"session.create","params":{"resume":"does-not-exist"}}`,
	)
	if len(msgs) != 1 {
		t.Fatalf("expected 1 response, got %d", len(msgs))
	}
	e, ok := msgs[0]["error"].(map[string]any)
	if !ok {
		t.Fatalf("expected an error response, got %+v", msgs[0])
	}
	if e["code"].(float64) != codeInvalidParams {
		t.Errorf("code = %v, want %d", e["code"], codeInvalidParams)
	}
}

// TestCreateWithoutStoreNoPersistError verifies the in-memory path is unchanged:
// with a nil store, session.create still succeeds (no persistence attempted) and
// resume of any id fails cleanly.
func TestCreateWithoutStoreNoPersistError(t *testing.T) {
	eng := newTestEngine()
	// nil store: plain create works.
	msgs := runLinesStore(t, eng, nil,
		`{"jsonrpc":"2.0","id":1,"method":"session.create"}`,
	)
	if _, hasErr := msgs[0]["error"]; hasErr {
		t.Fatalf("plain create failed with nil store: %+v", msgs[0])
	}
	// nil store: resume cannot find anything, so it errors (never panics).
	msgs2 := runLinesStore(t, eng, nil,
		`{"jsonrpc":"2.0","id":1,"method":"session.create","params":{"resume":"whatever"}}`,
	)
	if _, ok := msgs2[0]["error"].(map[string]any); !ok {
		t.Fatalf("resume with nil store should error, got %+v", msgs2[0])
	}
}

// TestSessionListEmpty verifies session.list returns an empty JSON array (not
// null) when no sessions exist yet, with a store wired.
func TestSessionListEmpty(t *testing.T) {
	store := session.NewJSONLStore(t.TempDir())
	eng := newTestEngine()
	msgs := runLinesStore(t, eng, store,
		`{"jsonrpc":"2.0","id":1,"method":"session.list"}`,
	)
	if len(msgs) != 1 {
		t.Fatalf("expected 1 response, got %d", len(msgs))
	}
	result, ok := msgs[0]["result"].([]any)
	if !ok {
		t.Fatalf("result not an array: %T %+v", msgs[0]["result"], msgs[0])
	}
	if len(result) != 0 {
		t.Errorf("session.list = %+v, want empty", result)
	}
}

// TestSessionListDiscoversPersisted is the headline test: a session created and
// prompted in one process is DISCOVERABLE via session.list in a second, fresh
// process that shares only the on-disk store — proving a client can find a
// resumable session it did not already know the id of. The summary carries the
// model and a non-zero event count.
func TestSessionListDiscoversPersisted(t *testing.T) {
	store := session.NewJSONLStore(t.TempDir())

	// --- process #1: create + prompt a session, then it exits. ---
	eng1 := newTestEngine(mock.Text("hello there"))
	createMsgs := runLinesStore(t, eng1, store,
		`{"jsonrpc":"2.0","id":1,"method":"session.create"}`,
	)
	id := createMsgs[0]["result"].(map[string]any)["id"].(string)
	runLinesStore(t, eng1, store,
		`{"jsonrpc":"2.0","id":2,"method":"session.prompt","params":{"session_id":"`+id+`","input":"hi"}}`,
	)

	// --- process #2: a brand-new server lists what is on disk. ---
	eng2 := newTestEngine()
	msgs := runLinesStore(t, eng2, store,
		`{"jsonrpc":"2.0","id":1,"method":"session.list"}`,
	)
	result, ok := msgs[0]["result"].([]any)
	if !ok {
		t.Fatalf("result not an array: %+v", msgs[0])
	}
	if len(result) != 1 {
		t.Fatalf("session.list returned %d entries, want 1: %+v", len(result), result)
	}
	entry := result[0].(map[string]any)
	if entry["id"] != id {
		t.Errorf("listed id = %v, want %v", entry["id"], id)
	}
	// The prompt recorded at least a user + assistant event, so events > 0 and the
	// summary should reflect the persisted model.
	if ev, _ := entry["events"].(float64); ev < 2 {
		t.Errorf("listed events = %v, want >= 2", entry["events"])
	}
	if entry["model"] != "test-model" {
		t.Errorf("listed model = %v, want test-model", entry["model"])
	}
}

// TestSessionListNoStoreUsesMemory verifies that without a store, session.list
// reports the in-memory sessions of the current process (so discovery still works
// in the ephemeral mode), and never panics.
func TestSessionListNoStoreUsesMemory(t *testing.T) {
	eng := newTestEngine()
	// Create two sessions, then list them — all in one serve invocation so the
	// in-memory map persists across the three requests.
	in := strings.NewReader(
		`{"jsonrpc":"2.0","id":1,"method":"session.create"}` + "\n" +
			`{"jsonrpc":"2.0","id":2,"method":"session.create"}` + "\n" +
			`{"jsonrpc":"2.0","id":3,"method":"session.list"}` + "\n")
	var out strings.Builder
	if err := serve(context.Background(), eng, in, &out, nil); err != nil {
		t.Fatalf("serve: %v", err)
	}
	msgs := decodeAll(t, out.String())

	var listResult []any
	for _, m := range msgs {
		if m["id"] == float64(3) {
			listResult, _ = m["result"].([]any)
		}
	}
	if len(listResult) != 2 {
		t.Fatalf("session.list (no store) = %d entries, want 2: %+v", len(listResult), listResult)
	}
}

// TestAgentsList verifies agents.list returns an empty array (v1 has no named
// agent profiles).
func TestAgentsList(t *testing.T) {
	eng := newTestEngine()
	msgs := runLines(t, eng, `{"jsonrpc":"2.0","id":4,"method":"agents.list"}`)
	if len(msgs) != 1 {
		t.Fatalf("expected 1 response, got %d", len(msgs))
	}
	result, ok := msgs[0]["result"].([]any)
	if !ok {
		t.Fatalf("result not an array: %+v", msgs[0])
	}
	if len(result) != 0 {
		t.Errorf("agents.list = %+v, want empty", result)
	}
}
