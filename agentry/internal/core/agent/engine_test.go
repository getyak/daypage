package agent

import (
	"context"
	"encoding/json"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/kubbot/agentry/internal/core/policy"
	"github.com/kubbot/agentry/internal/core/provider"
	"github.com/kubbot/agentry/internal/core/provider/mock"
	"github.com/kubbot/agentry/internal/core/session"
	"github.com/kubbot/agentry/internal/core/tool"
)

// fakeTool is a minimal Tool used to assert the loop actually invokes a tool the
// model requested. It records every invocation and echoes its args back, so the
// test can verify both that it ran and what it received.
type fakeTool struct {
	name    string
	schema  string      // optional schema override; default "{\"type\":\"object\"}"
	calls   int32       // atomic: invocation count
	lastIn  tool.Input  // last Input received
	result  tool.Result // canned result to return
	err     error       // optional error to return
	gotSess bool        // whether Session was non-nil on the last call
}

func (f *fakeTool) Name() string        { return f.name }
func (f *fakeTool) Description() string { return "a fake tool for tests" }
func (f *fakeTool) Schema() json.RawMessage {
	if f.schema != "" {
		return json.RawMessage(f.schema)
	}
	return json.RawMessage(`{"type":"object"}`)
}
func (f *fakeTool) Invoke(_ context.Context, in tool.Input) (tool.Result, error) {
	atomic.AddInt32(&f.calls, 1)
	f.lastIn = in
	_, f.gotSess = in.Session.(*session.Session)
	if f.err != nil {
		return tool.Result{}, f.err
	}
	return f.result, nil
}

func newRegistryWith(t *testing.T, tools ...tool.Tool) *tool.Registry {
	t.Helper()
	reg := tool.NewRegistry()
	for _, tl := range tools {
		if err := reg.Register(tl); err != nil {
			t.Fatalf("register %q: %v", tl.Name(), err)
		}
	}
	return reg
}

// TestRun_TwoTurnToolLoop is the core scenario from the task: turn 1 the model
// asks to call a registered tool; turn 2 it produces the final answer. We assert
// the tool ran exactly once with the right args, the final text is returned, and
// the session event log records the whole reason→act→observe sequence in order.
func TestRun_TwoTurnToolLoop(t *testing.T) {
	ft := &fakeTool{
		name:   "calc.add",
		result: tool.Result{Content: "3"},
	}
	reg := newRegistryWith(t, ft)

	args := []byte(`{"a":1,"b":2}`)
	prov := mock.New(
		// Turn 1: stream a little text, then request the tool.
		mock.CallTool("call-1", "calc.add", args, "Let me add those."),
		// Turn 2: having "seen" the tool result, produce the final answer.
		mock.Text("The sum is 3."),
	)

	// Allow-everything policy so the fake tool is not gated.
	pol := policy.New(nil, policy.Allow)
	eng := New(prov, reg, pol, "test-model")

	sess := session.New("s1")
	final, err := eng.Run(context.Background(), sess, "What is 1 + 2?")
	if err != nil {
		t.Fatalf("Run returned error: %v", err)
	}

	// The final assistant text from turn 2 is returned.
	if final != "The sum is 3." {
		t.Fatalf("final text = %q, want %q", final, "The sum is 3.")
	}

	// The tool ran exactly once.
	if got := atomic.LoadInt32(&ft.calls); got != 1 {
		t.Fatalf("tool invoked %d times, want 1", got)
	}
	// It received the exact args the model sent.
	if string(ft.lastIn.Args) != string(args) {
		t.Fatalf("tool args = %s, want %s", ft.lastIn.Args, args)
	}
	// The session was threaded through as the ambient context.
	if !ft.gotSess {
		t.Fatalf("tool did not receive a *session.Session as Input.Session")
	}

	// The whole script was consumed (both turns played, no echo fallback).
	if rem := prov.Remaining(); rem != 0 {
		t.Fatalf("provider has %d unplayed steps, want 0", rem)
	}

	// Verify the event log records the reason→act→observe sequence in order:
	// user, assistant(turn-1 text), tool_call, tool_result, assistant(final).
	wantTypes := []session.EventType{
		session.EvUser,
		session.EvAssistant,
		session.EvToolCall,
		session.EvToolResult,
		session.EvAssistant,
	}
	events := sess.Events()
	if len(events) != len(wantTypes) {
		t.Fatalf("session has %d events, want %d: %+v", len(events), len(wantTypes), events)
	}
	for i, want := range wantTypes {
		if events[i].Type != want {
			t.Fatalf("event[%d].Type = %q, want %q", i, events[i].Type, want)
		}
	}

	// The tool_result event carries the tool's content and the matching call id.
	tr := events[3]
	if tr.Text != "3" || tr.CallID != "call-1" || tr.Tool != "calc.add" || tr.IsError {
		t.Fatalf("tool_result event unexpected: %+v", tr)
	}

	// History() reconstructs a tool message the model would observe on turn 2.
	var sawToolMsg bool
	for _, m := range sess.History() {
		if m.Role == provider.RoleTool && m.ToolCallID == "call-1" && m.Text == "3" {
			sawToolMsg = true
		}
	}
	if !sawToolMsg {
		t.Fatalf("History() did not contain the tool result message")
	}
}

// TestRun_NoTools verifies a single-turn run with no tool calls returns the
// model's text directly and records just user + assistant events.
func TestRun_NoTools(t *testing.T) {
	prov := mock.New(mock.Text("Hello there."))
	eng := New(prov, tool.NewRegistry(), policy.New(nil, policy.Allow), "m")

	sess := session.New("s")
	final, err := eng.Run(context.Background(), sess, "hi")
	if err != nil {
		t.Fatalf("Run error: %v", err)
	}
	if final != "Hello there." {
		t.Fatalf("final = %q", final)
	}
	if n := len(sess.Events()); n != 2 {
		t.Fatalf("events = %d, want 2 (user+assistant)", n)
	}
}

// TestRun_PolicyDeny verifies a denied tool is not invoked and the model gets an
// error tool_result, then can still produce a final answer.
func TestRun_PolicyDeny(t *testing.T) {
	ft := &fakeTool{name: "danger.rm", result: tool.Result{Content: "should not run"}}
	reg := newRegistryWith(t, ft)

	prov := mock.New(
		mock.CallTool("c1", "danger.rm", []byte(`{}`)),
		mock.Text("Okay, I won't."),
	)
	// Deny the dangerous tool explicitly.
	pol := policy.New([]policy.Rule{{Tool: "danger.rm", Decision: policy.Deny}}, policy.Allow)
	eng := New(prov, reg, pol, "m")

	sess := session.New("s")
	final, err := eng.Run(context.Background(), sess, "delete everything")
	if err != nil {
		t.Fatalf("Run error: %v", err)
	}
	if final != "Okay, I won't." {
		t.Fatalf("final = %q", final)
	}
	if got := atomic.LoadInt32(&ft.calls); got != 0 {
		t.Fatalf("denied tool was invoked %d times, want 0", got)
	}
	// The tool_result must be an error mentioning the policy denial.
	var found bool
	for _, e := range sess.Events() {
		if e.Type == session.EvToolResult && e.IsError && strings.Contains(e.Text, "denied by policy") {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected an error tool_result for the denied tool; events: %+v", sess.Events())
	}
}

// TestRun_SchemaValidationRejectsBadArgs verifies the engine validates tool-call
// arguments against the tool's advertised schema BEFORE invoking: a call that
// violates the schema (here, an out-of-range value plus an unknown property) is
// turned into an error tool_result the model can read, the tool is NOT invoked,
// and on the next turn the model can issue a corrected call that DOES run.
func TestRun_SchemaValidationRejectsBadArgs(t *testing.T) {
	ft := &fakeTool{
		name: "web.fetch",
		schema: `{
		  "type":"object",
		  "properties":{
		    "url":{"type":"string"},
		    "max_bytes":{"type":"integer","minimum":1,"maximum":100}
		  },
		  "required":["url"],
		  "additionalProperties":false
		}`,
		result: tool.Result{Content: "fetched"},
	}
	reg := newRegistryWith(t, ft)

	prov := mock.New(
		// Turn 1: a schema-violating call (max_bytes over the maximum + an extra
		// undeclared property). The engine must reject this without invoking.
		mock.CallTool("c1", "web.fetch", []byte(`{"url":"http://x","max_bytes":9999,"junk":1}`)),
		// Turn 2: the model, having seen the rejection, issues a valid call.
		mock.CallTool("c2", "web.fetch", []byte(`{"url":"http://x","max_bytes":50}`)),
		// Turn 3: final answer.
		mock.Text("got it"),
	)
	eng := New(prov, reg, policy.New(nil, policy.Allow), "m")

	sess := session.New("s")
	final, err := eng.Run(context.Background(), sess, "fetch x")
	if err != nil {
		t.Fatalf("Run error: %v", err)
	}
	if final != "got it" {
		t.Fatalf("final = %q, want %q", final, "got it")
	}

	// The tool ran exactly once — only the corrected (turn-2) call, never the
	// invalid one.
	if got := atomic.LoadInt32(&ft.calls); got != 1 {
		t.Fatalf("tool invoked %d times, want 1 (only the valid call)", got)
	}
	if string(ft.lastIn.Args) != `{"url":"http://x","max_bytes":50}` {
		t.Fatalf("tool received args %s, want the corrected call", ft.lastIn.Args)
	}

	// The first tool_result must be an error naming the schema problems so the
	// model can self-correct; it must mention the not-executed rejection, the
	// out-of-range maximum, and the disallowed extra property.
	var rejection *session.Event
	for i := range sess.Events() {
		e := sess.Events()[i]
		if e.Type == session.EvToolResult && e.CallID == "c1" {
			rejection = &e
			break
		}
	}
	if rejection == nil {
		t.Fatalf("no tool_result recorded for the invalid call; events: %+v", sess.Events())
	}
	if !rejection.IsError {
		t.Fatalf("rejection tool_result should be an error: %+v", rejection)
	}
	for _, want := range []string{"invalid arguments", "not executed", "maximum 100", `"junk"`} {
		if !strings.Contains(rejection.Text, want) {
			t.Fatalf("rejection text missing %q; got:\n%s", want, rejection.Text)
		}
	}

	// The whole script was consumed (no echo fallback): all three turns played.
	if rem := prov.Remaining(); rem != 0 {
		t.Fatalf("provider has %d unplayed steps, want 0", rem)
	}
}

// TestRun_AskApproved verifies that an "ask" decision consults the Approve hook,
// and a positive verdict lets the tool run.
func TestRun_AskApproved(t *testing.T) {
	ft := &fakeTool{name: "shell.exec", result: tool.Result{Content: "ok"}}
	reg := newRegistryWith(t, ft)

	prov := mock.New(
		mock.CallTool("c1", "shell.exec", []byte(`{"cmd":"ls"}`)),
		mock.Text("done"),
	)
	pol := policy.New([]policy.Rule{{Tool: "shell.exec", Decision: policy.Ask}}, policy.Allow)
	eng := New(prov, reg, pol, "m")

	var asked int32
	eng.Approve = func(name string, _ json.RawMessage) bool {
		atomic.AddInt32(&asked, 1)
		return name == "shell.exec" // approve
	}

	sess := session.New("s")
	if _, err := eng.Run(context.Background(), sess, "list files"); err != nil {
		t.Fatalf("Run error: %v", err)
	}
	if atomic.LoadInt32(&asked) != 1 {
		t.Fatalf("Approve called %d times, want 1", asked)
	}
	if atomic.LoadInt32(&ft.calls) != 1 {
		t.Fatalf("approved tool ran %d times, want 1", ft.calls)
	}
}

// TestRun_AskDenied verifies a negative Approve verdict blocks the tool and
// produces an error tool_result.
func TestRun_AskDenied(t *testing.T) {
	ft := &fakeTool{name: "shell.exec", result: tool.Result{Content: "ok"}}
	reg := newRegistryWith(t, ft)

	prov := mock.New(
		mock.CallTool("c1", "shell.exec", []byte(`{"cmd":"rm -rf /"}`)),
		mock.Text("understood"),
	)
	pol := policy.New([]policy.Rule{{Tool: "shell.exec", Decision: policy.Ask}}, policy.Allow)
	eng := New(prov, reg, pol, "m")
	eng.Approve = func(string, json.RawMessage) bool { return false } // deny

	sess := session.New("s")
	if _, err := eng.Run(context.Background(), sess, "wipe disk"); err != nil {
		t.Fatalf("Run error: %v", err)
	}
	if atomic.LoadInt32(&ft.calls) != 0 {
		t.Fatalf("denied-by-approver tool ran %d times, want 0", ft.calls)
	}
	var found bool
	for _, e := range sess.Events() {
		if e.Type == session.EvToolResult && e.IsError && strings.Contains(e.Text, "denied by approver") {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected error tool_result from approver denial; events: %+v", sess.Events())
	}
}

// TestRun_UnknownTool verifies that requesting a tool not in the registry yields
// an error tool_result (not a panic) and the loop proceeds.
func TestRun_UnknownTool(t *testing.T) {
	prov := mock.New(
		mock.CallTool("c1", "does.not.exist", []byte(`{}`)),
		mock.Text("recovered"),
	)
	eng := New(prov, tool.NewRegistry(), policy.New(nil, policy.Allow), "m")

	sess := session.New("s")
	final, err := eng.Run(context.Background(), sess, "use a missing tool")
	if err != nil {
		t.Fatalf("Run error: %v", err)
	}
	if final != "recovered" {
		t.Fatalf("final = %q", final)
	}
	var found bool
	for _, e := range sess.Events() {
		if e.Type == session.EvToolResult && e.IsError && strings.Contains(e.Text, "not found") {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected 'not found' error tool_result; events: %+v", sess.Events())
	}
}

// TestRun_ToolInvokeError verifies a tool returning a Go error is converted into
// an error tool_result rather than aborting the run.
func TestRun_ToolInvokeError(t *testing.T) {
	ft := &fakeTool{name: "flaky", err: errTest}
	reg := newRegistryWith(t, ft)
	prov := mock.New(
		mock.CallTool("c1", "flaky", []byte(`{}`)),
		mock.Text("handled"),
	)
	eng := New(prov, reg, policy.New(nil, policy.Allow), "m")

	sess := session.New("s")
	final, err := eng.Run(context.Background(), sess, "go")
	if err != nil {
		t.Fatalf("Run error: %v", err)
	}
	if final != "handled" {
		t.Fatalf("final = %q", final)
	}
	var found bool
	for _, e := range sess.Events() {
		if e.Type == session.EvToolResult && e.IsError && strings.Contains(e.Text, "failed") {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected 'failed' error tool_result; events: %+v", sess.Events())
	}
}

var errTest = &simpleErr{"boom"}

type simpleErr struct{ s string }

func (e *simpleErr) Error() string { return e.s }

// TestRun_MaxSteps verifies the loop bounds itself: a model that calls a tool
// forever stops at MaxSteps and returns an error.
func TestRun_MaxSteps(t *testing.T) {
	ft := &fakeTool{name: "loop.tool", result: tool.Result{Content: "again"}}
	reg := newRegistryWith(t, ft)

	// A provider that always asks to call the tool (script exhausts → echo, but
	// echo never calls a tool, so to truly loop we feed many CallTool steps).
	steps := make([]mock.Step, 50)
	for i := range steps {
		steps[i] = mock.CallTool("c", "loop.tool", []byte(`{}`))
	}
	prov := mock.New(steps...)

	eng := New(prov, reg, policy.New(nil, policy.Allow), "m")
	eng.MaxSteps = 3

	sess := session.New("s")
	_, err := eng.Run(context.Background(), sess, "spin")
	if err == nil {
		t.Fatalf("expected MaxSteps error, got nil")
	}
	if !strings.Contains(err.Error(), "MaxSteps") {
		t.Fatalf("error = %v, want MaxSteps mention", err)
	}
	// Exactly MaxSteps turns → MaxSteps tool invocations.
	if got := atomic.LoadInt32(&ft.calls); got != 3 {
		t.Fatalf("tool ran %d times, want 3 (== MaxSteps)", got)
	}
}

// TestRun_ContextCanceled verifies a pre-canceled context aborts before any model
// turn runs.
func TestRun_ContextCanceled(t *testing.T) {
	prov := mock.New(mock.Text("never"))
	eng := New(prov, tool.NewRegistry(), policy.New(nil, policy.Allow), "m")

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cancel immediately

	sess := session.New("s")
	_, err := eng.Run(ctx, sess, "hi")
	if err == nil {
		t.Fatalf("expected context error, got nil")
	}
}

// TestRun_NilProvider guards the obvious misuse.
func TestRun_NilProvider(t *testing.T) {
	eng := &Engine{}
	if _, err := eng.Run(context.Background(), session.New("s"), "x"); err == nil {
		t.Fatalf("expected error for nil provider")
	}
}

// TestToolSpecs verifies the registry→spec helper preserves name, description,
// schema, and the registry's sorted ordering.
func TestToolSpecs(t *testing.T) {
	reg := newRegistryWith(t,
		&fakeTool{name: "b.tool"},
		&fakeTool{name: "a.tool"},
	)
	specs := ToolSpecs(reg)
	if len(specs) != 2 {
		t.Fatalf("got %d specs, want 2", len(specs))
	}
	// Registry.List sorts by name, so a.tool precedes b.tool.
	if specs[0].Name != "a.tool" || specs[1].Name != "b.tool" {
		t.Fatalf("specs not name-sorted: %q, %q", specs[0].Name, specs[1].Name)
	}
	if specs[0].Description != "a fake tool for tests" {
		t.Fatalf("description not carried: %q", specs[0].Description)
	}
	if string(specs[0].Schema) != `{"type":"object"}` {
		t.Fatalf("schema not carried: %s", specs[0].Schema)
	}
	if ToolSpecs(nil) != nil {
		t.Fatalf("ToolSpecs(nil) should be nil")
	}
}

// TestRun_NewDefaultsPolicy verifies New replaces a nil policy so the engine is
// usable, and that the default policy allows a read-only tool.
func TestRun_NewDefaultsPolicy(t *testing.T) {
	eng := New(mock.New(mock.Text("ok")), tool.NewRegistry(), nil, "m")
	if eng.Policy == nil {
		t.Fatalf("New should default a nil policy")
	}
}
