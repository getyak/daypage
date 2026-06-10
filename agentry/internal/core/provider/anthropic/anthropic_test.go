package anthropic

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/kubbot/agentry/internal/core/provider"
)

// decodeBody marshals the request via the same path Stream uses and returns it
// decoded into a generic map for shape assertions.
func decodeBody(t *testing.T, c *Client, req provider.Request) map[string]any {
	t.Helper()
	raw, err := c.MarshalRequest(req)
	if err != nil {
		t.Fatalf("MarshalRequest: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("unmarshal body: %v\nbody=%s", err, raw)
	}
	return m
}

func TestNewDefaultsBaseURL(t *testing.T) {
	c := New("key", "", "claude-sonnet-4-6")
	if c.baseURL != DefaultBaseURL {
		t.Errorf("baseURL = %q, want %q", c.baseURL, DefaultBaseURL)
	}
	// Trailing slash should be trimmed.
	c2 := New("key", "https://proxy.example.com/", "m")
	if c2.baseURL != "https://proxy.example.com" {
		t.Errorf("baseURL = %q, want trimmed", c2.baseURL)
	}
	if c.Name() != "anthropic" {
		t.Errorf("Name() = %q, want anthropic", c.Name())
	}
}

// TestBuildRequestShape asserts the translated wire body: system hoisting,
// per-role block mapping, tool_result reconstruction, tools, and stream:true.
func TestBuildRequestShape(t *testing.T) {
	c := New("key", "", "fallback-model")

	temp := 0.5
	req := provider.Request{
		// Model left empty -> fallback to client default.
		System:      "be terse",
		Temperature: &temp,
		MaxTokens:   1234,
		Messages: []provider.Message{
			{Role: provider.RoleSystem, Text: "extra system"},
			{Role: provider.RoleUser, Text: "hi"},
			{Role: provider.RoleAssistant, Text: "calling tool", ToolCalls: []provider.ToolCall{
				{ID: "toolu_1", Name: "get_weather", Args: json.RawMessage(`{"city":"NYC"}`)},
			}},
			{Role: provider.RoleTool, ToolCallID: "toolu_1", Name: "get_weather", Text: "72F"},
		},
		Tools: []provider.ToolSpec{
			{Name: "get_weather", Description: "weather", Schema: json.RawMessage(`{"type":"object"}`)},
		},
	}

	m := decodeBody(t, c, req)

	if m["model"] != "fallback-model" {
		t.Errorf("model = %v, want fallback-model", m["model"])
	}
	if m["stream"] != true {
		t.Errorf("stream = %v, want true", m["stream"])
	}
	if m["max_tokens"].(float64) != 1234 {
		t.Errorf("max_tokens = %v, want 1234", m["max_tokens"])
	}
	if m["temperature"].(float64) != 0.5 {
		t.Errorf("temperature = %v, want 0.5", m["temperature"])
	}

	// System should combine the top-level System and the RoleSystem message.
	sys, _ := m["system"].(string)
	if !strings.Contains(sys, "be terse") || !strings.Contains(sys, "extra system") {
		t.Errorf("system = %q, want both system parts combined", sys)
	}

	msgs, ok := m["messages"].([]any)
	if !ok {
		t.Fatalf("messages not an array: %T", m["messages"])
	}
	// RoleSystem is hoisted, not a message: user, assistant, tool-result(user).
	if len(msgs) != 3 {
		t.Fatalf("messages len = %d, want 3 (system hoisted)", len(msgs))
	}

	// [0] user text block
	user := msgs[0].(map[string]any)
	if user["role"] != "user" {
		t.Errorf("msg[0] role = %v, want user", user["role"])
	}
	ublocks := user["content"].([]any)
	b0 := ublocks[0].(map[string]any)
	if b0["type"] != "text" || b0["text"] != "hi" {
		t.Errorf("msg[0] block = %v, want text:hi", b0)
	}

	// [1] assistant: text block + tool_use block
	asst := msgs[1].(map[string]any)
	if asst["role"] != "assistant" {
		t.Errorf("msg[1] role = %v, want assistant", asst["role"])
	}
	ablocks := asst["content"].([]any)
	if len(ablocks) != 2 {
		t.Fatalf("assistant blocks = %d, want 2 (text + tool_use)", len(ablocks))
	}
	tu := ablocks[1].(map[string]any)
	if tu["type"] != "tool_use" || tu["id"] != "toolu_1" || tu["name"] != "get_weather" {
		t.Errorf("tool_use block = %v", tu)
	}
	input := tu["input"].(map[string]any)
	if input["city"] != "NYC" {
		t.Errorf("tool_use input = %v, want city:NYC", input)
	}

	// [2] tool result -> user message with tool_result block keyed by tool_use_id
	tr := msgs[2].(map[string]any)
	if tr["role"] != "user" {
		t.Errorf("msg[2] role = %v, want user (tool_result carrier)", tr["role"])
	}
	trBlock := tr["content"].([]any)[0].(map[string]any)
	if trBlock["type"] != "tool_result" || trBlock["tool_use_id"] != "toolu_1" {
		t.Errorf("tool_result block = %v", trBlock)
	}
	inner := trBlock["content"].([]any)[0].(map[string]any)
	if inner["type"] != "text" || inner["text"] != "72F" {
		t.Errorf("tool_result inner = %v, want text:72F", inner)
	}

	// tools[] carried through with input_schema.
	tools := m["tools"].([]any)
	if len(tools) != 1 {
		t.Fatalf("tools len = %d, want 1", len(tools))
	}
	tool0 := tools[0].(map[string]any)
	if tool0["name"] != "get_weather" || tool0["input_schema"] == nil {
		t.Errorf("tool[0] = %v, want name + input_schema", tool0)
	}
}

// TestBuildRequestDefaults verifies max_tokens fallback and empty-schema/empty-arg
// normalization to "{}".
func TestBuildRequestDefaults(t *testing.T) {
	c := New("key", "", "m")
	req := provider.Request{
		Messages: []provider.Message{
			{Role: provider.RoleAssistant, ToolCalls: []provider.ToolCall{
				{ID: "t1", Name: "noargs"}, // nil Args -> "{}"
			}},
		},
		Tools: []provider.ToolSpec{
			{Name: "noschema"}, // nil Schema -> "{}"
		},
	}
	m := decodeBody(t, c, req)

	if m["max_tokens"].(float64) != defaultMaxTokens {
		t.Errorf("max_tokens = %v, want default %d", m["max_tokens"], defaultMaxTokens)
	}
	// temperature omitted when nil.
	if _, ok := m["temperature"]; ok {
		t.Errorf("temperature should be omitted when nil")
	}

	asst := m["messages"].([]any)[0].(map[string]any)
	tu := asst["content"].([]any)[0].(map[string]any)
	if got := tu["input"]; len(got.(map[string]any)) != 0 {
		t.Errorf("empty tool args = %v, want empty object", got)
	}
	tool0 := m["tools"].([]any)[0].(map[string]any)
	if got := tool0["input_schema"]; len(got.(map[string]any)) != 0 {
		t.Errorf("empty schema = %v, want empty object", got)
	}
}

// TestEnsureJSONObject covers the nil/blank/valid cases directly.
func TestEnsureJSONObject(t *testing.T) {
	cases := []struct {
		in   json.RawMessage
		want string
	}{
		{nil, "{}"},
		{json.RawMessage(""), "{}"},
		{json.RawMessage("   "), "{}"},
		{json.RawMessage(`{"a":1}`), `{"a":1}`},
	}
	for _, tc := range cases {
		if got := string(ensureJSONObject(tc.in)); got != tc.want {
			t.Errorf("ensureJSONObject(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// TestParseSSE drives the SSE parser with a representative Anthropic stream and
// asserts the normalized event sequence (text deltas, an assembled tool call
// from input_json_delta fragments, usage, and a terminal Done with stop_reason).
func TestParseSSE(t *testing.T) {
	stream := strings.Join([]string{
		`event: message_start`,
		`data: {"type":"message_start","message":{"id":"msg_1"},"usage":{"input_tokens":10,"output_tokens":0}}`,
		``,
		`event: content_block_start`,
		`data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`,
		``,
		`event: content_block_delta`,
		`data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}`,
		``,
		`data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}`,
		``,
		`event: content_block_stop`,
		`data: {"type":"content_block_stop","index":0}`,
		``,
		`event: content_block_start`,
		`data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_9","name":"search"}}`,
		``,
		`data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"q\":"}}`,
		``,
		`data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"go\"}"}}`,
		``,
		`data: {"type":"content_block_stop","index":1}`,
		``,
		`event: message_delta`,
		`data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}`,
		``,
		`event: message_stop`,
		`data: {"type":"message_stop"}`,
		``,
	}, "\n")

	out := make(chan provider.Event, 32)
	parseSSE(context.Background(), strings.NewReader(stream), out)
	close(out)

	var (
		text       strings.Builder
		toolCalls  []*provider.ToolCall
		usageSeen  *provider.Usage
		stopReason string
		doneSeen   bool
		errSeen    error
	)
	for ev := range out {
		switch ev.Kind {
		case provider.EventText:
			text.WriteString(ev.TextDelta)
		case provider.EventToolCall:
			toolCalls = append(toolCalls, ev.ToolCall)
		case provider.EventUsage:
			usageSeen = ev.Usage
		case provider.EventDone:
			doneSeen = true
			stopReason = ev.StopReason
		case provider.EventError:
			errSeen = ev.Err
		}
	}

	if errSeen != nil {
		t.Fatalf("unexpected error event: %v", errSeen)
	}
	if got := text.String(); got != "Hello world" {
		t.Errorf("text = %q, want %q", got, "Hello world")
	}
	if len(toolCalls) != 1 {
		t.Fatalf("tool calls = %d, want 1", len(toolCalls))
	}
	tc := toolCalls[0]
	if tc.ID != "toolu_9" || tc.Name != "search" {
		t.Errorf("tool call meta = %+v", tc)
	}
	var args map[string]any
	if err := json.Unmarshal(tc.Args, &args); err != nil {
		t.Fatalf("tool args not valid JSON %q: %v", tc.Args, err)
	}
	if args["q"] != "go" {
		t.Errorf("tool args = %v, want q:go", args)
	}
	if !doneSeen || stopReason != "tool_use" {
		t.Errorf("done=%v stopReason=%q, want done with tool_use", doneSeen, stopReason)
	}
	if usageSeen == nil || usageSeen.InputTokens != 10 || usageSeen.OutputTokens != 7 {
		t.Errorf("usage = %+v, want in=10 out=7", usageSeen)
	}
}

// TestParseSSETruncated ensures a stream that ends without message_stop still
// produces a terminal Done (consumers must not hang).
func TestParseSSETruncated(t *testing.T) {
	stream := "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n"
	out := make(chan provider.Event, 8)
	parseSSE(context.Background(), strings.NewReader(stream), out)
	close(out)

	var sawText, sawDone bool
	for ev := range out {
		switch ev.Kind {
		case provider.EventText:
			sawText = true
		case provider.EventDone:
			sawDone = true
		}
	}
	if !sawText || !sawDone {
		t.Errorf("sawText=%v sawDone=%v, want both", sawText, sawDone)
	}
}

// TestParseSSEErrorEvent maps an Anthropic "error" SSE frame to EventError.
func TestParseSSEErrorEvent(t *testing.T) {
	stream := "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"slow down\"}}\n\n"
	out := make(chan provider.Event, 8)
	parseSSE(context.Background(), strings.NewReader(stream), out)
	close(out)

	var errSeen error
	for ev := range out {
		if ev.Kind == provider.EventError {
			errSeen = ev.Err
		}
	}
	if errSeen == nil || !strings.Contains(errSeen.Error(), "overloaded_error") {
		t.Errorf("error event = %v, want overloaded_error", errSeen)
	}
}

// TestParseSSECancelled verifies that a cancelled context stops emission.
func TestParseSSECancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // already cancelled

	stream := "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n"
	out := make(chan provider.Event) // unbuffered: a send would block if attempted

	done := make(chan struct{})
	go func() {
		parseSSE(ctx, strings.NewReader(stream), out)
		close(done)
	}()

	// parseSSE must return without blocking on a send.
	select {
	case <-done:
	case <-out:
		t.Fatal("parseSSE emitted despite cancelled context")
	}
}
