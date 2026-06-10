package orchestrator

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/kubbot/agentry/internal/core/agent"
	"github.com/kubbot/agentry/internal/core/policy"
	"github.com/kubbot/agentry/internal/core/provider"
	"github.com/kubbot/agentry/internal/core/provider/mock"
	"github.com/kubbot/agentry/internal/core/session"
	"github.com/kubbot/agentry/internal/core/tool"
)

// echoEngine builds a sub-agent engine backed by the mock provider in echo mode
// (an empty script), so calling Run returns the user's prompt verbatim. This is
// the simplest possible "agent that echoes" used to exercise the agent-as-tool
// and fan-out machinery without a network or a real model.
func echoEngine(_ AgentProfile) *agent.Engine {
	return agent.New(mock.New(), tool.NewRegistry(), policy.New(nil, policy.Allow), "echo-model")
}

// agentArgs marshals an {"input": ...} payload for an agent-as-tool call.
func agentArgs(t *testing.T, input string) json.RawMessage {
	t.Helper()
	b, err := json.Marshal(agentInput{Input: input})
	if err != nil {
		t.Fatalf("marshal agent args: %v", err)
	}
	return b
}

// TestAsTool_Name verifies the produced tool is named "agent.<profile.Name>".
func TestAsTool_Name(t *testing.T) {
	tl := AsTool(AgentProfile{Name: "researcher"}, echoEngine)
	if got := tl.Name(); got != "agent.researcher" {
		t.Fatalf("Name() = %q, want %q", got, "agent.researcher")
	}
	// An empty profile name must not yield a bare "agent." key.
	if got := AsTool(AgentProfile{}, echoEngine).Name(); got != "agent.unnamed" {
		t.Fatalf("empty-name Name() = %q, want %q", got, "agent.unnamed")
	}
}

// TestAsTool_SchemaIsValidJSON verifies the advertised schema parses and that it
// requires the "input" field, so providers/transports can rely on it.
func TestAsTool_SchemaIsValidJSON(t *testing.T) {
	tl := AsTool(AgentProfile{Name: "x"}, echoEngine)
	var m map[string]any
	if err := json.Unmarshal(tl.Schema(), &m); err != nil {
		t.Fatalf("schema is not valid JSON: %v", err)
	}
	req, _ := m["required"].([]any)
	if len(req) != 1 || req[0] != "input" {
		t.Fatalf("schema.required = %v, want [\"input\"]", m["required"])
	}
}

// TestAsTool_Invoke_RunsSubAgent is the core agent-as-tool scenario: invoking the
// tool spins a nested engine (via the factory) on a fresh session and returns the
// sub-agent's final text. The echo engine returns the prompt verbatim, so the
// result content must equal the input.
func TestAsTool_Invoke_RunsSubAgent(t *testing.T) {
	tl := AsTool(AgentProfile{Name: "echoer", Model: "echo-model"}, echoEngine)

	res, err := tl.Invoke(context.Background(), tool.Input{Args: agentArgs(t, "hello sub-agent")})
	if err != nil {
		t.Fatalf("Invoke returned error: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error result: %+v", res)
	}
	if res.Content != "hello sub-agent" {
		t.Fatalf("Content = %q, want %q", res.Content, "hello sub-agent")
	}
	// Meta should attribute the run to the profile.
	if got, _ := res.Meta["agent"].(string); got != "echoer" {
		t.Fatalf("Meta[agent] = %v, want %q", res.Meta["agent"], "echoer")
	}
}

// TestAsTool_Invoke_FreshSessionUsesParentNamespace verifies the sub-agent runs
// on a fresh, isolated session whose id is namespaced under the parent session
// (when one is supplied as the ambient context) for attribution.
func TestAsTool_Invoke_FreshSessionUsesParentNamespace(t *testing.T) {
	tl := AsTool(AgentProfile{Name: "child"}, echoEngine)
	parent := session.New("parent-1")

	res, err := tl.Invoke(context.Background(), tool.Input{
		Args:    agentArgs(t, "ping"),
		Session: parent,
	})
	if err != nil {
		t.Fatalf("Invoke error: %v", err)
	}
	sid, _ := res.Meta["session"].(string)
	if sid != "parent-1/agent:child" {
		t.Fatalf("sub-session id = %q, want %q", sid, "parent-1/agent:child")
	}
	// The parent session must be untouched by the nested run.
	if n := len(parent.Events()); n != 0 {
		t.Fatalf("parent session gained %d events; sub-agent must use a fresh session", n)
	}
}

// TestAsTool_Invoke_BadInput covers the bounded/validated argument paths: each
// produces an error Result (never a panic, never a Go error).
func TestAsTool_Invoke_BadInput(t *testing.T) {
	tl := AsTool(AgentProfile{Name: "v"}, echoEngine)
	cases := []struct {
		name string
		args json.RawMessage
		want string
	}{
		{"nil args", nil, "missing arguments"},
		{"empty object", json.RawMessage(`{}`), "non-empty string"},
		{"blank input", json.RawMessage(`{"input":"   "}`), "non-empty string"},
		{"malformed json", json.RawMessage(`{"input":`), "invalid arguments"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			res, err := tl.Invoke(context.Background(), tool.Input{Args: tc.args})
			if err != nil {
				t.Fatalf("Invoke returned Go error (want error Result): %v", err)
			}
			if !res.IsError {
				t.Fatalf("expected IsError result, got %+v", res)
			}
			if !strings.Contains(res.Content, tc.want) {
				t.Fatalf("Content = %q, want it to contain %q", res.Content, tc.want)
			}
		})
	}
}

// TestAsTool_Invoke_InputTooLarge verifies the size cap rejects oversized args
// before unmarshaling.
func TestAsTool_Invoke_InputTooLarge(t *testing.T) {
	tl := AsTool(AgentProfile{Name: "v"}, echoEngine)
	big := make([]byte, maxInputBytes+1)
	for i := range big {
		big[i] = 'a'
	}
	res, err := tl.Invoke(context.Background(), tool.Input{Args: json.RawMessage(big)})
	if err != nil {
		t.Fatalf("Invoke error: %v", err)
	}
	if !res.IsError || !strings.Contains(res.Content, "too large") {
		t.Fatalf("expected 'too large' error result, got %+v", res)
	}
}

// TestAsTool_Invoke_NilFactory verifies a tool built without a factory reports an
// error result instead of dereferencing nil.
func TestAsTool_Invoke_NilFactory(t *testing.T) {
	tl := AsTool(AgentProfile{Name: "v"}, nil)
	res, err := tl.Invoke(context.Background(), tool.Input{Args: agentArgs(t, "go")})
	if err != nil {
		t.Fatalf("Invoke error: %v", err)
	}
	if !res.IsError || !strings.Contains(res.Content, "no engine factory") {
		t.Fatalf("expected 'no engine factory' error result, got %+v", res)
	}
}

// TestAsTool_Invoke_FactoryReturnsNil verifies a factory that cannot realize the
// profile (returns nil) is reported, not dereferenced.
func TestAsTool_Invoke_FactoryReturnsNil(t *testing.T) {
	tl := AsTool(AgentProfile{Name: "v"}, func(AgentProfile) *agent.Engine { return nil })
	res, err := tl.Invoke(context.Background(), tool.Input{Args: agentArgs(t, "go")})
	if err != nil {
		t.Fatalf("Invoke error: %v", err)
	}
	if !res.IsError || !strings.Contains(res.Content, "returned nil") {
		t.Fatalf("expected 'returned nil' error result, got %+v", res)
	}
}

// TestAsTool_Invoke_SubAgentRunError verifies a non-cancellation run failure is
// surfaced as an error Result (with partial text in Meta), not a Go error, so the
// parent loop can react.
func TestAsTool_Invoke_SubAgentRunError(t *testing.T) {
	// Build a sub-engine whose mock always asks for a (missing) tool, with
	// MaxSteps=1, so Run returns a "reached MaxSteps" error deterministically.
	factory := func(AgentProfile) *agent.Engine {
		prov := mock.New(mock.CallTool("c", "missing.tool", []byte(`{}`)))
		eng := agent.New(prov, tool.NewRegistry(), policy.New(nil, policy.Allow), "m")
		eng.MaxSteps = 1
		return eng
	}
	tl := AsTool(AgentProfile{Name: "flaky"}, factory)

	res, err := tl.Invoke(context.Background(), tool.Input{Args: agentArgs(t, "do it")})
	if err != nil {
		t.Fatalf("expected error encoded in Result, got Go error: %v", err)
	}
	if !res.IsError || !strings.Contains(res.Content, "failed") {
		t.Fatalf("expected 'failed' error result, got %+v", res)
	}
	if _, ok := res.Meta["partial"]; !ok {
		t.Fatalf("expected Meta to carry partial text key, got %+v", res.Meta)
	}
}

// TestAsTool_Invoke_ContextCanceled verifies a canceled context is propagated as
// a Go error (a real teardown), distinct from sub-agent data errors.
func TestAsTool_Invoke_ContextCanceled(t *testing.T) {
	tl := AsTool(AgentProfile{Name: "c"}, echoEngine)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, err := tl.Invoke(ctx, tool.Input{Args: agentArgs(t, "x")})
	if err == nil {
		t.Fatalf("expected context error to propagate as a Go error")
	}
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v, want context.Canceled", err)
	}
}

// TestAsTool_NestedSchedulingThroughParentEngine is the end-to-end scheduling
// scenario from DESIGN §9: a PARENT engine has the sub-agent registered as the
// tool "agent.echoer"; the parent model decides to call it; the engine invokes
// it, which spins the nested engine and feeds its output back. This proves an
// agent can SCHEDULE another agent purely through the Tool seam.
func TestAsTool_NestedSchedulingThroughParentEngine(t *testing.T) {
	// The sub-agent tool wraps an echo engine.
	subTool := AsTool(AgentProfile{Name: "echoer"}, echoEngine)

	reg := tool.NewRegistry()
	if err := reg.Register(subTool); err != nil {
		t.Fatalf("register sub-agent tool: %v", err)
	}

	// Parent provider: turn 1 calls the sub-agent; turn 2 produces the final
	// answer (it has, by then, "observed" the sub-agent's result).
	parentProv := mock.New(
		mock.CallTool("call-1", "agent.echoer", agentArgs(t, "delegated task")),
		mock.Text("sub-agent handled it."),
	)
	parent := agent.New(parentProv, reg, policy.New(nil, policy.Allow), "parent-model")

	sess := session.New("top")
	final, err := parent.Run(context.Background(), sess, "please delegate")
	if err != nil {
		t.Fatalf("parent Run error: %v", err)
	}
	if final != "sub-agent handled it." {
		t.Fatalf("final = %q, want %q", final, "sub-agent handled it.")
	}

	// The tool_result recorded on the parent session must carry the sub-agent's
	// echoed output ("delegated task").
	var subResult string
	for _, e := range sess.Events() {
		if e.Type == session.EvToolResult && e.Tool == "agent.echoer" {
			subResult = e.Text
		}
	}
	if subResult != "delegated task" {
		t.Fatalf("sub-agent tool_result = %q, want %q", subResult, "delegated task")
	}
}

// TestFanOut_OrderedResults verifies FanOut returns results aligned with inputs
// even though runs proceed concurrently. The echo engine returns each prompt
// verbatim, so results[i] must equal inputs[i].
func TestFanOut_OrderedResults(t *testing.T) {
	eng := echoEngine(AgentProfile{})

	inputs := make([]string, 50)
	for i := range inputs {
		inputs[i] = "prompt-" + strconv.Itoa(i)
	}

	results := FanOut(context.Background(), eng, inputs)
	if len(results) != len(inputs) {
		t.Fatalf("got %d results, want %d", len(results), len(inputs))
	}
	for i, in := range inputs {
		if results[i] != in {
			t.Fatalf("results[%d] = %q, want %q", i, results[i], in)
		}
	}
}

// TestFanOut_Concurrency asserts that runs actually overlap: a barrier tool that
// blocks until all N concurrent calls are in flight would deadlock if FanOut ran
// serially, so completion alone proves overlap; we additionally assert observed
// peak concurrency >= 2.
//
// Concurrency correctness requires each run to drive itself to the barrier
// deterministically and independently. A single shared mock.New(...) script
// cannot do that — its cursor is consumed by whichever goroutine races to it
// first, so some runs would never reach the barrier and the gate would never
// open. We therefore use a stateless barrierProvider that decides each turn from
// the request alone: if the conversation has no tool result yet, emit a barrier
// call; once it sees the result, emit final text. This is safe to share across
// concurrent runs because it holds no mutable state.
func TestFanOut_Concurrency(t *testing.T) {
	var inFlight int32
	var peak int32

	inputs := []string{"a", "b", "c", "d"}

	bt := &barrierTool{
		inFlight: &inFlight,
		peak:     &peak,
		gate:     make(chan struct{}),
		want:     int32(len(inputs)), // release once all four are in flight
	}
	reg := tool.NewRegistry()
	if err := reg.Register(bt); err != nil {
		t.Fatalf("register barrier tool: %v", err)
	}

	eng := agent.New(&barrierProvider{}, reg, policy.New(nil, policy.Allow), "m")

	// Bound the test so a regression that breaks overlap fails fast instead of
	// hanging until the package-level test timeout.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	results := FanOut(ctx, eng, inputs)
	if len(results) != len(inputs) {
		t.Fatalf("got %d results, want %d", len(results), len(inputs))
	}
	for i, r := range results {
		if r != "barrier passed" {
			t.Fatalf("results[%d] = %q, want %q (a run did not complete through the barrier)", i, r, "barrier passed")
		}
	}
	if atomic.LoadInt32(&peak) < 2 {
		t.Fatalf("peak concurrency = %d, want >= 2 (runs did not overlap)", peak)
	}
}

// TestFanOut_Empty verifies the trivial inputs cases.
func TestFanOut_Empty(t *testing.T) {
	eng := echoEngine(AgentProfile{})
	if got := FanOut(context.Background(), eng, nil); len(got) != 0 {
		t.Fatalf("FanOut(nil) = %v, want empty", got)
	}
	if got := FanOut(context.Background(), eng, []string{}); len(got) != 0 {
		t.Fatalf("FanOut([]) = %v, want empty", got)
	}
}

// TestFanOut_NilEngine verifies a nil engine yields a same-length error slice
// rather than panicking.
func TestFanOut_NilEngine(t *testing.T) {
	results := FanOut(context.Background(), nil, []string{"x", "y"})
	if len(results) != 2 {
		t.Fatalf("got %d results, want 2", len(results))
	}
	for i, r := range results {
		if !strings.Contains(r, "nil engine") {
			t.Fatalf("results[%d] = %q, want a nil-engine error", i, r)
		}
	}
}

// TestFanOut_CanceledContext verifies a canceled context short-circuits: every
// slot reports an error rather than running.
func TestFanOut_CanceledContext(t *testing.T) {
	eng := echoEngine(AgentProfile{})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	results := FanOut(ctx, eng, []string{"a", "b", "c"})
	if len(results) != 3 {
		t.Fatalf("got %d results, want 3", len(results))
	}
	for i, r := range results {
		if !strings.HasPrefix(r, "error:") {
			t.Fatalf("results[%d] = %q, want an error result under cancellation", i, r)
		}
	}
}

// --- helpers ---

// barrierTool blocks each invocation until `want` invocations are concurrently
// in flight, proving FanOut runs overlap. It tracks the peak concurrency seen so
// a test can assert parallelism without flakiness: once `want` goroutines have
// entered, the last entrant opens the gate for everyone. The gate channel is
// created by the test before use, so there is no init race.
type barrierTool struct {
	inFlight *int32
	peak     *int32
	want     int32
	gate     chan struct{}
	closed   int32 // CAS guard so the gate is closed exactly once
}

func (b *barrierTool) Name() string           { return "barrier" }
func (b *barrierTool) Description() string     { return "test barrier" }
func (b *barrierTool) Schema() json.RawMessage { return json.RawMessage(`{"type":"object"}`) }
func (b *barrierTool) Invoke(ctx context.Context, _ tool.Input) (tool.Result, error) {
	n := atomic.AddInt32(b.inFlight, 1)
	// Record a new peak if this is the highest concurrency seen so far.
	for {
		old := atomic.LoadInt32(b.peak)
		if n <= old || atomic.CompareAndSwapInt32(b.peak, old, n) {
			break
		}
	}
	// The last expected entrant opens the gate for everyone, exactly once.
	if n >= b.want && atomic.CompareAndSwapInt32(&b.closed, 0, 1) {
		close(b.gate)
	}

	select {
	case <-b.gate:
	case <-ctx.Done():
		atomic.AddInt32(b.inFlight, -1)
		return tool.Result{}, ctx.Err()
	}

	atomic.AddInt32(b.inFlight, -1)
	return tool.Result{Content: "passed"}, nil
}

// barrierProvider is a stateless provider for the concurrency test. It decides
// each turn purely from the request, so it is safe to share across concurrent
// FanOut runs (unlike a scripted mock with a shared cursor):
//
//   - if the conversation contains no tool result yet, it requests the "barrier"
//     tool (driving this run to the synchronization point); and
//   - once a tool result is present, it emits the final text "barrier passed".
//
// Each concurrent run thus independently and deterministically reaches the
// barrier exactly once.
type barrierProvider struct{}

func (*barrierProvider) Name() string { return "barrier-provider" }

func (*barrierProvider) Stream(ctx context.Context, req provider.Request) (<-chan provider.Event, error) {
	sawToolResult := false
	for _, m := range req.Messages {
		if m.Role == provider.RoleTool {
			sawToolResult = true
			break
		}
	}

	out := make(chan provider.Event, 2)
	if sawToolResult {
		out <- provider.Event{Kind: provider.EventText, TextDelta: "barrier passed"}
		out <- provider.Event{Kind: provider.EventDone, StopReason: "end_turn"}
	} else {
		out <- provider.Event{Kind: provider.EventToolCall, ToolCall: &provider.ToolCall{ID: "b1", Name: "barrier", Args: []byte(`{}`)}}
		out <- provider.Event{Kind: provider.EventDone, StopReason: "tool_use"}
	}
	close(out)
	return out, nil
}
