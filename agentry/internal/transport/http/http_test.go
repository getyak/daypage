package http

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/kubbot/agentry/internal/core/agent"
	"github.com/kubbot/agentry/internal/core/policy"
	"github.com/kubbot/agentry/internal/core/provider/mock"
	"github.com/kubbot/agentry/internal/core/session"
	"github.com/kubbot/agentry/internal/core/tool"
)

// echoTool is a trivial Tool used to populate the registry so /v1/tools has
// something to list and the SSE path can exercise a real tool invocation.
type echoTool struct{}

func (echoTool) Name() string            { return "echo" }
func (echoTool) Description() string     { return "echoes its input back" }
func (echoTool) Schema() json.RawMessage { return json.RawMessage(`{"type":"object"}`) }
func (echoTool) Invoke(_ context.Context, in tool.Input) (tool.Result, error) {
	return tool.Result{Content: "echoed"}, nil
}

// newTestEngine builds an Engine backed by the deterministic mock provider so
// the transport tests never touch the network. The optional script drives the
// model turns for SSE tests; with no script the mock falls back to echo mode.
func newTestEngine(t *testing.T, script ...mock.Step) *agent.Engine {
	t.Helper()
	reg := tool.NewRegistry()
	reg.MustRegister(echoTool{})
	// Allow-everything policy so the engine never gates the test tool.
	pol := policy.New(nil, policy.Allow)
	return agent.New(mock.New(script...), reg, pol, "test-model")
}

func TestHealthz(t *testing.T) {
	srv := httptest.NewServer(NewHandler(newTestEngine(t)))
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/healthz")
	if err != nil {
		t.Fatalf("GET /healthz: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Fatalf("Content-Type = %q, want application/json", ct)
	}

	var body map[string]string
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if body["status"] != "ok" {
		t.Fatalf("body = %v, want status=ok", body)
	}
}

func TestListTools(t *testing.T) {
	srv := httptest.NewServer(NewHandler(newTestEngine(t)))
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/v1/tools")
	if err != nil {
		t.Fatalf("GET /v1/tools: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}

	var tools []toolInfo
	if err := json.NewDecoder(resp.Body).Decode(&tools); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if len(tools) != 1 {
		t.Fatalf("got %d tools, want 1: %+v", len(tools), tools)
	}
	if tools[0].Name != "echo" || tools[0].Description == "" {
		t.Fatalf("tool = %+v, want name=echo with a description", tools[0])
	}
}

// TestCreateSessionAndMessageSSE exercises the full happy path: create a session,
// then POST a message and read the SSE stream to completion. The mock provider is
// scripted to call the echo tool once and then produce a final answer, so the
// stream should contain user/tool_call/tool_result/assistant events and a final
// "done" event carrying the answer text.
func TestCreateSessionAndMessageSSE(t *testing.T) {
	eng := newTestEngine(t,
		mock.CallTool("c1", "echo", []byte(`{}`), "calling echo"),
		mock.Text("all done"),
	)
	srv := httptest.NewServer(NewHandler(eng))
	defer srv.Close()

	// 1. Create a session.
	id := createSession(t, srv.URL)

	// 2. POST a message and stream the SSE response.
	body := strings.NewReader(`{"input":"hello"}`)
	resp, err := http.Post(srv.URL+"/v1/sessions/"+id+"/messages", "application/json", body)
	if err != nil {
		t.Fatalf("POST message: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/event-stream") {
		t.Fatalf("Content-Type = %q, want text/event-stream", ct)
	}

	events := readSSE(t, resp.Body)

	// The terminal event must be "done" carrying the final assistant text.
	last := events[len(events)-1]
	if last.event != "done" {
		t.Fatalf("last event = %q, want done", last.event)
	}
	var done map[string]string
	if err := json.Unmarshal([]byte(last.data), &done); err != nil {
		t.Fatalf("decode done payload %q: %v", last.data, err)
	}
	if done["text"] != "all done" {
		t.Fatalf("done text = %q, want %q", done["text"], "all done")
	}
	if _, hasErr := done["error"]; hasErr {
		t.Fatalf("done event reported an error: %v", done)
	}

	// And the stream must have surfaced the tool activity along the way.
	if !hasEvent(events, "tool_call") || !hasEvent(events, "tool_result") {
		t.Fatalf("expected tool_call and tool_result events, got: %v", eventNames(events))
	}
	if !hasEvent(events, "user") || !hasEvent(events, "assistant") {
		t.Fatalf("expected user and assistant events, got: %v", eventNames(events))
	}
}

func TestPostMessageUnknownSession(t *testing.T) {
	srv := httptest.NewServer(NewHandler(newTestEngine(t)))
	defer srv.Close()

	resp, err := http.Post(srv.URL+"/v1/sessions/nope/messages", "application/json",
		strings.NewReader(`{"input":"hi"}`))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", resp.StatusCode)
	}
}

func TestPostMessageEmptyInput(t *testing.T) {
	srv := httptest.NewServer(NewHandler(newTestEngine(t)))
	defer srv.Close()

	id := createSession(t, srv.URL)
	resp, err := http.Post(srv.URL+"/v1/sessions/"+id+"/messages", "application/json",
		strings.NewReader(`{"input":""}`))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", resp.StatusCode)
	}
}

func TestRootServesWebUI(t *testing.T) {
	srv := httptest.NewServer(NewHandler(newTestEngine(t)))
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatalf("GET /: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
		t.Fatalf("Content-Type = %q, want text/html", ct)
	}
	// Root now serves the embedded SPA (internal/ui/web), titled "Agentry".
	// Match case-insensitively so either the SPA or the status-page fallback
	// (both of which name the product) satisfies the assertion.
	b, _ := io.ReadAll(resp.Body)
	if !strings.Contains(strings.ToLower(string(b)), "agentry") {
		t.Fatalf("root page did not mention agentry")
	}

	// An unknown path routed to the catch-all should 404 rather than serve the
	// SPA, so the JSON API is never shadowed by the static file server.
	resp2, err := http.Get(srv.URL + "/does-not-exist")
	if err != nil {
		t.Fatalf("GET /does-not-exist: %v", err)
	}
	defer resp2.Body.Close()
	if resp2.StatusCode != http.StatusNotFound {
		t.Fatalf("unknown path status = %d, want 404", resp2.StatusCode)
	}
}

// TestSessionPersistsAndResumesAcrossRestart is the headline persistence test
// for the HTTP transport: a session created and messaged through one server
// (process #1, backed by an on-disk store) is resumable by a SECOND, fresh
// server (process #2) that shares only that store — proving resume survives a
// restart rather than relying on the in-memory map.
func TestSessionPersistsAndResumesAcrossRestart(t *testing.T) {
	store := session.NewJSONLStore(t.TempDir())

	// --- process #1: create + message a session, then it goes away. ---
	eng1 := newTestEngine(t, mock.Text("answer-one"))
	srv1 := httptest.NewServer(NewHandlerWithStore(eng1, store))

	id := createSession(t, srv1.URL)

	resp, err := http.Post(srv1.URL+"/v1/sessions/"+id+"/messages", "application/json",
		strings.NewReader(`{"input":"remember mango"}`))
	if err != nil {
		t.Fatalf("POST message: %v", err)
	}
	// Drain the SSE stream to completion so the run (and its post-run persist)
	// finishes before we inspect the store.
	_ = readSSE(t, resp.Body)
	resp.Body.Close()
	srv1.Close() // process #1 exits

	// The store must now hold the session with its history.
	persisted, err := store.Load(id)
	if err != nil {
		t.Fatalf("store.Load(%q) after run: %v", id, err)
	}
	if len(persisted.Events()) == 0 {
		t.Fatalf("persisted session %q has no events", id)
	}

	// --- process #2: a brand-new handler (empty session map) resumes by id. ---
	eng2 := newTestEngine(t, mock.Text("answer-two"))
	srv2 := httptest.NewServer(NewHandlerWithStore(eng2, store))
	defer srv2.Close()

	// Resume via POST /v1/sessions {"resume":"<id>"}.
	rresp, err := http.Post(srv2.URL+"/v1/sessions", "application/json",
		strings.NewReader(`{"resume":"`+id+`"}`))
	if err != nil {
		t.Fatalf("POST resume: %v", err)
	}
	defer rresp.Body.Close()
	if rresp.StatusCode != http.StatusCreated {
		t.Fatalf("resume status = %d, want 201", rresp.StatusCode)
	}
	var rout map[string]any
	if err := json.NewDecoder(rresp.Body).Decode(&rout); err != nil {
		t.Fatalf("decode resume: %v", err)
	}
	if rout["id"] != id {
		t.Errorf("resume id = %v, want %v", rout["id"], id)
	}
	if rout["resumed"] != true {
		t.Errorf("resumed = %v, want true", rout["resumed"])
	}

	// Message the resumed session, then confirm BOTH turns are on disk: the
	// pre-restart "remember mango" and the post-resume "and kiwi".
	mresp, err := http.Post(srv2.URL+"/v1/sessions/"+id+"/messages", "application/json",
		strings.NewReader(`{"input":"and kiwi"}`))
	if err != nil {
		t.Fatalf("POST resumed message: %v", err)
	}
	_ = readSSE(t, mresp.Body)
	mresp.Body.Close()

	final, err := store.Load(id)
	if err != nil {
		t.Fatalf("reload after resumed message: %v", err)
	}
	var sawMango, sawKiwi bool
	for _, ev := range final.Events() {
		if ev.Type == session.EvUser && strings.Contains(ev.Text, "mango") {
			sawMango = true
		}
		if ev.Type == session.EvUser && strings.Contains(ev.Text, "kiwi") {
			sawKiwi = true
		}
	}
	if !sawMango || !sawKiwi {
		t.Errorf("resumed conversation lost a turn (mango=%v kiwi=%v); events=%+v", sawMango, sawKiwi, final.Events())
	}
}

// TestPostMessageRehydratesFromStore verifies a message to a session not held in
// memory is served by loading it from the store (rather than 404ing), so a
// client that kept the id across a restart can keep talking without an explicit
// resume call.
func TestPostMessageRehydratesFromStore(t *testing.T) {
	store := session.NewJSONLStore(t.TempDir())

	// Persist a session directly (as if a previous process had created it).
	seed := session.New("kept-id")
	seed.Append(session.Event{Type: session.EvUser, Text: "earlier turn"})
	if err := store.Save(seed); err != nil {
		t.Fatalf("seed save: %v", err)
	}

	eng := newTestEngine(t, mock.Text("fresh-answer"))
	srv := httptest.NewServer(NewHandlerWithStore(eng, store))
	defer srv.Close()

	// POST a message straight to the id, no create/resume first.
	resp, err := http.Post(srv.URL+"/v1/sessions/kept-id/messages", "application/json",
		strings.NewReader(`{"input":"continue"}`))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200 (should rehydrate, not 404)", resp.StatusCode)
	}
	events := readSSE(t, resp.Body)
	last := events[len(events)-1]
	if last.event != "done" {
		t.Fatalf("last event = %q, want done", last.event)
	}
}

// TestResumeUnknownSession404 verifies resuming an id with no persisted session
// (and no in-memory copy) is a clean 404, not a silent empty session.
func TestResumeUnknownSession404(t *testing.T) {
	store := session.NewJSONLStore(t.TempDir())
	eng := newTestEngine(t)
	srv := httptest.NewServer(NewHandlerWithStore(eng, store))
	defer srv.Close()

	resp, err := http.Post(srv.URL+"/v1/sessions", "application/json",
		strings.NewReader(`{"resume":"nope"}`))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", resp.StatusCode)
	}
}

// TestCreateSessionNoStoreStillWorks verifies the default (no store) create path
// is unchanged: it returns a 201 with an id and resumed:false, with no
// persistence attempted.
func TestCreateSessionNoStoreStillWorks(t *testing.T) {
	srv := httptest.NewServer(NewHandler(newTestEngine(t)))
	defer srv.Close()

	resp, err := http.Post(srv.URL+"/v1/sessions", "application/json", nil)
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("status = %d, want 201", resp.StatusCode)
	}
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if id, _ := out["id"].(string); id == "" {
		t.Errorf("empty id: %+v", out)
	}
	if out["resumed"] != false {
		t.Errorf("resumed = %v, want false", out["resumed"])
	}
}

// TestListSessionsEmpty verifies GET /v1/sessions returns an empty JSON array
// (never null) when there are no sessions, with a store wired.
func TestListSessionsEmpty(t *testing.T) {
	store := session.NewJSONLStore(t.TempDir())
	srv := httptest.NewServer(NewHandlerWithStore(newTestEngine(t), store))
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/v1/sessions")
	if err != nil {
		t.Fatalf("GET /v1/sessions: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	var out []sessionSummary
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(out) != 0 {
		t.Errorf("listing = %+v, want empty", out)
	}
}

// TestListSessionsDiscoversPersisted is the headline discovery test: a session
// created + messaged on one server (process #1) is DISCOVERABLE via
// GET /v1/sessions on a second, fresh server (process #2) sharing only the
// on-disk store — so a client can find a resumable session whose id it never
// knew. The summary carries the model and a non-zero event count.
func TestListSessionsDiscoversPersisted(t *testing.T) {
	store := session.NewJSONLStore(t.TempDir())

	// --- process #1: create + message a session, then it exits. ---
	eng1 := newTestEngine(t, mock.Text("answer-one"))
	srv1 := httptest.NewServer(NewHandlerWithStore(eng1, store))
	id := createSession(t, srv1.URL)
	resp, err := http.Post(srv1.URL+"/v1/sessions/"+id+"/messages", "application/json",
		strings.NewReader(`{"input":"remember mango"}`))
	if err != nil {
		t.Fatalf("POST message: %v", err)
	}
	_ = readSSE(t, resp.Body)
	resp.Body.Close()
	srv1.Close()

	// --- process #2: a brand-new handler lists what is on disk. ---
	eng2 := newTestEngine(t)
	srv2 := httptest.NewServer(NewHandlerWithStore(eng2, store))
	defer srv2.Close()

	lresp, err := http.Get(srv2.URL + "/v1/sessions")
	if err != nil {
		t.Fatalf("GET /v1/sessions: %v", err)
	}
	defer lresp.Body.Close()
	if lresp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", lresp.StatusCode)
	}
	var out []sessionSummary
	if err := json.NewDecoder(lresp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("listing has %d entries, want 1: %+v", len(out), out)
	}
	if out[0].ID != id {
		t.Errorf("listed id = %q, want %q", out[0].ID, id)
	}
	if out[0].Events < 2 {
		t.Errorf("listed events = %d, want >= 2 (user+assistant)", out[0].Events)
	}
	if out[0].Model != "test-model" {
		t.Errorf("listed model = %q, want test-model", out[0].Model)
	}
}

// TestListSessionsNoStoreUsesMemory verifies that without a store, GET
// /v1/sessions reports the in-memory sessions of the current process, so
// discovery still works in the ephemeral mode.
func TestListSessionsNoStoreUsesMemory(t *testing.T) {
	srv := httptest.NewServer(NewHandler(newTestEngine(t)))
	defer srv.Close()

	// Create two sessions on this (single) server.
	id1 := createSession(t, srv.URL)
	id2 := createSession(t, srv.URL)

	resp, err := http.Get(srv.URL + "/v1/sessions")
	if err != nil {
		t.Fatalf("GET /v1/sessions: %v", err)
	}
	defer resp.Body.Close()
	var out []sessionSummary
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(out) != 2 {
		t.Fatalf("listing (no store) = %d entries, want 2: %+v", len(out), out)
	}
	seen := map[string]bool{out[0].ID: true, out[1].ID: true}
	if !seen[id1] || !seen[id2] {
		t.Errorf("listing %+v missing one of %q/%q", out, id1, id2)
	}
}

// --- helpers ---

func createSession(t *testing.T, baseURL string) string {
	t.Helper()
	resp, err := http.Post(baseURL+"/v1/sessions", "application/json", nil)
	if err != nil {
		t.Fatalf("POST /v1/sessions: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create session status = %d, want 201", resp.StatusCode)
	}
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode session: %v", err)
	}
	id, _ := out["id"].(string)
	if id == "" {
		t.Fatalf("create session returned empty id")
	}
	return id
}

// sseEvent is one parsed Server-Sent Event (its `event:` name and `data:` body).
type sseEvent struct {
	event string
	data  string
}

// readSSE parses an SSE stream into events until EOF (the server closes the body
// after the terminal "done" event). It handles the minimal framing this
// transport emits: "event: <name>", "data: <json>", blank-line separators.
func readSSE(t *testing.T, r io.Reader) []sseEvent {
	t.Helper()
	var (
		out   []sseEvent
		cur   sseEvent
		dirty bool
	)
	sc := bufio.NewScanner(r)
	// Allow generous line sizes for larger data payloads.
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for sc.Scan() {
		line := sc.Text()
		switch {
		case line == "":
			// Blank line terminates the current event.
			if dirty {
				out = append(out, cur)
				cur = sseEvent{}
				dirty = false
			}
		case strings.HasPrefix(line, "event:"):
			cur.event = strings.TrimSpace(strings.TrimPrefix(line, "event:"))
			dirty = true
		case strings.HasPrefix(line, "data:"):
			cur.data = strings.TrimSpace(strings.TrimPrefix(line, "data:"))
			dirty = true
		}
	}
	if err := sc.Err(); err != nil {
		t.Fatalf("scan SSE stream: %v", err)
	}
	// Flush a trailing event with no final blank line (defensive).
	if dirty {
		out = append(out, cur)
	}
	if len(out) == 0 {
		t.Fatalf("SSE stream produced no events")
	}
	return out
}

func hasEvent(events []sseEvent, name string) bool {
	for _, e := range events {
		if e.event == name {
			return true
		}
	}
	return false
}

func eventNames(events []sseEvent) []string {
	names := make([]string, len(events))
	for i, e := range events {
		names[i] = e.event
	}
	return names
}
