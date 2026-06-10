package openaicompat

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/kubbot/agentry/internal/core/provider"
	"github.com/kubbot/agentry/internal/core/provider/retry"
)

// fastRetry is a near-instant retry policy for tests so backoff doesn't burn
// real wall-clock time.
func fastRetry() retry.Policy {
	return retry.Policy{MaxRetries: 3, BaseDelay: time.Millisecond, MaxDelay: 2 * time.Millisecond}
}

// captureRoundTrip records the most recent outgoing request body so request-shape
// assertions can inspect exactly what was sent on the wire, then returns a canned
// SSE response.
type captureRoundTrip struct {
	gotBody   []byte
	gotHeader http.Header
	gotURL    string
	respBody  string
}

func (c *captureRoundTrip) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.Body != nil {
		c.gotBody, _ = io.ReadAll(r.Body)
	}
	c.gotHeader = r.Header.Clone()
	c.gotURL = r.URL.String()
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": {"text/event-stream"}},
		Body:       io.NopCloser(strings.NewReader(c.respBody)),
	}, nil
}

// newTestClient wires a Client to a capturing round-tripper.
func newTestClient(rt http.RoundTripper) *Client {
	return New("test-key", "https://example.test/v1/", "default-model",
		WithHTTPClient(&http.Client{Transport: rt}))
}

// drain collects every event from a stream into a slice.
func drain(ch <-chan provider.Event) []provider.Event {
	var got []provider.Event
	for ev := range ch {
		got = append(got, ev)
	}
	return got
}

// TestRequestShape is the core request-shape unit test: it drives one Stream and
// asserts the JSON body, URL, and auth header match the OpenAI wire contract.
func TestRequestShape(t *testing.T) {
	rt := &captureRoundTrip{respBody: "data: [DONE]\n"}
	c := newTestClient(rt)

	temp := 0.7
	req := provider.Request{
		System:      "you are helpful",
		Temperature: &temp,
		MaxTokens:   256,
		Messages: []provider.Message{
			{Role: provider.RoleUser, Text: "hi"},
			{
				Role: provider.RoleAssistant,
				Text: "calling",
				ToolCalls: []provider.ToolCall{
					{ID: "call_1", Name: "get_weather", Args: json.RawMessage(`{"city":"SF"}`)},
				},
			},
			{Role: provider.RoleTool, ToolCallID: "call_1", Name: "get_weather", Text: "sunny"},
		},
		Tools: []provider.ToolSpec{
			{Name: "get_weather", Description: "weather by city", Schema: json.RawMessage(`{"type":"object"}`)},
		},
	}

	ch, err := c.Stream(context.Background(), req)
	if err != nil {
		t.Fatalf("Stream error: %v", err)
	}
	drain(ch)

	// URL: baseURL trailing slash trimmed, "/chat/completions" appended.
	if want := "https://example.test/v1/chat/completions"; rt.gotURL != want {
		t.Errorf("URL = %q, want %q", rt.gotURL, want)
	}
	// Auth header.
	if got := rt.gotHeader.Get("Authorization"); got != "Bearer test-key" {
		t.Errorf("Authorization = %q, want %q", got, "Bearer test-key")
	}

	var body wireRequest
	if err := json.Unmarshal(rt.gotBody, &body); err != nil {
		t.Fatalf("request body is not valid JSON: %v\nbody: %s", err, rt.gotBody)
	}

	if body.Model != "default-model" {
		t.Errorf("model = %q, want default-model", body.Model)
	}
	if !body.Stream {
		t.Errorf("stream = false, want true")
	}
	if body.Temperature == nil || *body.Temperature != 0.7 {
		t.Errorf("temperature = %v, want 0.7", body.Temperature)
	}
	if body.MaxTokens != 256 {
		t.Errorf("max_tokens = %d, want 256", body.MaxTokens)
	}

	// messages[0] is the system prompt synthesized from Request.System.
	if len(body.Messages) != 4 {
		t.Fatalf("len(messages) = %d, want 4 (system + 3)", len(body.Messages))
	}
	if body.Messages[0].Role != "system" || body.Messages[0].Content == nil || *body.Messages[0].Content != "you are helpful" {
		t.Errorf("messages[0] = %+v, want system 'you are helpful'", body.Messages[0])
	}
	// user
	if body.Messages[1].Role != "user" || body.Messages[1].Content == nil || *body.Messages[1].Content != "hi" {
		t.Errorf("messages[1] = %+v, want user 'hi'", body.Messages[1])
	}
	// assistant with a tool call: content present + tool_calls[] with stringified args.
	am := body.Messages[2]
	if am.Role != "assistant" {
		t.Errorf("messages[2].role = %q, want assistant", am.Role)
	}
	if len(am.ToolCalls) != 1 {
		t.Fatalf("assistant tool_calls = %d, want 1", len(am.ToolCalls))
	}
	tc := am.ToolCalls[0]
	if tc.ID != "call_1" || tc.Type != "function" || tc.Function.Name != "get_weather" {
		t.Errorf("assistant tool_call = %+v, want id=call_1 type=function name=get_weather", tc)
	}
	if tc.Function.Arguments != `{"city":"SF"}` {
		t.Errorf("tool_call arguments = %q, want stringified JSON", tc.Function.Arguments)
	}
	// tool result: role:tool with tool_call_id + content.
	tm := body.Messages[3]
	if tm.Role != "tool" || tm.ToolCallID != "call_1" || tm.Content == nil || *tm.Content != "sunny" {
		t.Errorf("messages[3] = %+v, want tool result for call_1 'sunny'", tm)
	}

	// tools[] shaped as type:function with parameters carrying the schema.
	if len(body.Tools) != 1 {
		t.Fatalf("len(tools) = %d, want 1", len(body.Tools))
	}
	if body.Tools[0].Type != "function" {
		t.Errorf("tools[0].type = %q, want function", body.Tools[0].Type)
	}
	if body.Tools[0].Function.Name != "get_weather" || body.Tools[0].Function.Description != "weather by city" {
		t.Errorf("tools[0].function = %+v, want get_weather/weather by city", body.Tools[0].Function)
	}
	if string(body.Tools[0].Function.Parameters) != `{"type":"object"}` {
		t.Errorf("tools[0].parameters = %s, want schema passthrough", body.Tools[0].Function.Parameters)
	}
}

// TestModelOverride verifies Request.Model takes precedence over the default and
// that an omitted optional (no temperature / max_tokens) leaves those fields out.
func TestModelOverride(t *testing.T) {
	rt := &captureRoundTrip{respBody: "data: [DONE]\n"}
	c := newTestClient(rt)

	ch, err := c.Stream(context.Background(), provider.Request{
		Model:    "qwen-plus",
		Messages: []provider.Message{{Role: provider.RoleUser, Text: "x"}},
	})
	if err != nil {
		t.Fatalf("Stream error: %v", err)
	}
	drain(ch)

	// Inspect the raw JSON so we can confirm omitted fields are truly absent.
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(rt.gotBody, &raw); err != nil {
		t.Fatalf("body not JSON: %v", err)
	}
	var model string
	_ = json.Unmarshal(raw["model"], &model)
	if model != "qwen-plus" {
		t.Errorf("model = %q, want qwen-plus", model)
	}
	if _, ok := raw["temperature"]; ok {
		t.Errorf("temperature should be omitted when nil")
	}
	if _, ok := raw["max_tokens"]; ok {
		t.Errorf("max_tokens should be omitted when zero")
	}
	if _, ok := raw["tools"]; ok {
		t.Errorf("tools should be omitted when none provided")
	}
}

// sseLine marshals v as a single `data: {json}` SSE line. Building chunks from
// real structs (rather than hand-written JSON) keeps the test fixtures valid and
// readable, especially for the brace-heavy tool-call fragments.
func sseLine(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal sse fixture: %v", err)
	}
	return "data: " + string(b)
}

// fragment is a tiny helper to build one streamed tool-call delta chunk.
func fragment(index int, id, name, args string) streamChunk {
	d := streamToolCallDelta{Index: index, ID: id}
	d.Function = &struct {
		Name      string `json:"name"`
		Arguments string `json:"arguments"`
	}{Name: name, Arguments: args}
	return streamChunk{Choices: []streamChoice{{Delta: streamDelta{ToolCalls: []streamToolCallDelta{d}}}}}
}

// TestStreamParsing exercises the SSE decoder: interleaved text deltas, a tool
// call assembled from fragments across chunks, usage, finish_reason, and [DONE].
func TestStreamParsing(t *testing.T) {
	finish := "tool_calls"
	lastFrag := fragment(0, "", "", "}")
	lastFrag.Choices[0].FinishReason = &finish

	lines := []string{
		sseLine(t, streamChunk{Choices: []streamChoice{{Delta: streamDelta{Content: "Hel"}}}}),
		sseLine(t, streamChunk{Choices: []streamChoice{{Delta: streamDelta{Content: "lo"}}}}),
		// tool call streamed in three fragments at index 0
		sseLine(t, fragment(0, "call_a", "search", `{"q":`)),
		sseLine(t, fragment(0, "", "", `"cats"`)),
		sseLine(t, lastFrag),
		sseLine(t, streamChunk{Usage: &wireUsage{PromptTokens: 11, CompletionTokens: 22}}),
		"data: [DONE]",
		"",
	}
	sse := strings.Join(lines, "\n")

	rt := &captureRoundTrip{respBody: sse}
	c := newTestClient(rt)

	ch, err := c.Stream(context.Background(), provider.Request{})
	if err != nil {
		t.Fatalf("Stream error: %v", err)
	}
	got := drain(ch)

	var text strings.Builder
	var toolCalls []*provider.ToolCall
	var usage *provider.Usage
	var stop string
	doneCount := 0
	for _, ev := range got {
		switch ev.Kind {
		case provider.EventText:
			text.WriteString(ev.TextDelta)
		case provider.EventToolCall:
			toolCalls = append(toolCalls, ev.ToolCall)
		case provider.EventUsage:
			usage = ev.Usage
		case provider.EventDone:
			doneCount++
			stop = ev.StopReason
		case provider.EventError:
			t.Fatalf("unexpected EventError: %v", ev.Err)
		}
	}

	if text.String() != "Hello" {
		t.Errorf("text = %q, want Hello", text.String())
	}
	if doneCount != 1 {
		t.Fatalf("EventDone count = %d, want 1", doneCount)
	}
	if stop != "tool_use" {
		t.Errorf("stop = %q, want tool_use (mapped from tool_calls)", stop)
	}
	if len(toolCalls) != 1 {
		t.Fatalf("tool calls = %d, want 1", len(toolCalls))
	}
	tc := toolCalls[0]
	if tc.ID != "call_a" || tc.Name != "search" {
		t.Errorf("tool call id/name = %q/%q, want call_a/search", tc.ID, tc.Name)
	}
	if string(tc.Args) != `{"q":"cats"}` {
		t.Errorf("tool call args = %s, want concatenated {\"q\":\"cats\"}", tc.Args)
	}
	if usage == nil || usage.InputTokens != 11 || usage.OutputTokens != 22 {
		t.Errorf("usage = %+v, want input=11 output=22", usage)
	}
	// EventDone must be terminal.
	if got[len(got)-1].Kind != provider.EventDone {
		t.Errorf("last event kind = %d, want EventDone", got[len(got)-1].Kind)
	}
}

// TestStreamNoDoneSentinel verifies a server that closes the stream without a
// [DONE] line still yields a terminal EventDone.
func TestStreamNoDoneSentinel(t *testing.T) {
	sse := `data: {"choices":[{"delta":{"content":"hi"},"finish_reason":"stop"}]}` + "\n"
	rt := &captureRoundTrip{respBody: sse}
	c := newTestClient(rt)

	ch, _ := c.Stream(context.Background(), provider.Request{})
	got := drain(ch)
	if got[len(got)-1].Kind != provider.EventDone {
		t.Fatalf("last event = %+v, want EventDone", got[len(got)-1])
	}
	if got[len(got)-1].StopReason != "end_turn" {
		t.Errorf("stop = %q, want end_turn", got[len(got)-1].StopReason)
	}
}

// TestHTTPError verifies a non-200 response surfaces synchronously as an error
// from Stream (no channel returned).
func TestHTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"error":{"message":"bad key"}}`)
	}))
	defer srv.Close()

	c := New("nope", srv.URL, "m")
	_, err := c.Stream(context.Background(), provider.Request{})
	if err == nil {
		t.Fatalf("expected error on 401, got nil")
	}
	if !strings.Contains(err.Error(), "401") || !strings.Contains(err.Error(), "bad key") {
		t.Errorf("error = %v, want it to mention 401 and the server message", err)
	}
}

// TestContextCancellation verifies a canceled context aborts emission and the
// stream still terminates without a clean EventDone.
func TestContextCancellation(t *testing.T) {
	// A long stream; we cancel before reading so the producer must bail.
	var b strings.Builder
	for i := 0; i < 100; i++ {
		b.WriteString(`data: {"choices":[{"delta":{"content":"x"}}]}` + "\n")
	}
	rt := &captureRoundTrip{respBody: b.String()}
	c := newTestClient(rt)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	ch, err := c.Stream(ctx, provider.Request{})
	if err != nil {
		// Cancellation may also surface as a synchronous Do error; that's fine.
		return
	}
	got := drain(ch)
	for _, ev := range got {
		if ev.Kind == provider.EventDone {
			t.Errorf("did not expect a clean EventDone after cancellation")
		}
	}
}

// TestImplementsProvider is a compile-time assertion that *Client satisfies the
// Provider seam.
func TestImplementsProvider(t *testing.T) {
	var _ provider.Provider = (*Client)(nil)
}

// TestStreamRetriesTransient429 is an end-to-end proof that the adapter's
// built-in retry layer rides out a transient rate-limit: the server returns 429
// once (with a short Retry-After) and then a valid SSE stream on the retry, and
// Stream surfaces the parsed text with no error.
func TestStreamRetriesTransient429(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// The adapter buffers the body; each attempt must carry it intact.
		b, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(b), `"hi"`) {
			t.Errorf("attempt body missing prompt: %s", b)
		}
		if atomic.AddInt32(&calls, 1) == 1 {
			w.Header().Set("Retry-After", "0") // retry immediately
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = io.WriteString(w, `{"error":{"message":"slow down"}}`)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, "data: {\"choices\":[{\"delta\":{\"content\":\"pong\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n")
	}))
	defer srv.Close()

	// Fast policy so the test doesn't wait on real backoff.
	c := New("k", srv.URL, "m", WithRetryPolicy(fastRetry()))

	ch, err := c.Stream(context.Background(), provider.Request{
		Messages: []provider.Message{{Role: provider.RoleUser, Text: "hi"}},
	})
	if err != nil {
		t.Fatalf("Stream returned synchronous error despite retry: %v", err)
	}
	got := drain(ch)

	var text strings.Builder
	for _, ev := range got {
		switch ev.Kind {
		case provider.EventText:
			text.WriteString(ev.TextDelta)
		case provider.EventError:
			t.Fatalf("unexpected EventError: %v", ev.Err)
		}
	}
	if text.String() != "pong" {
		t.Errorf("text = %q, want pong (recovered after 429)", text.String())
	}
	if n := atomic.LoadInt32(&calls); n != 2 {
		t.Errorf("server calls = %d, want 2 (429 then success)", n)
	}
}

// TestStreamFatal4xxNoRetry verifies a non-transient 401 is returned immediately
// (the retry layer must not retry auth failures).
func TestStreamFatal4xxNoRetry(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"error":{"message":"bad key"}}`)
	}))
	defer srv.Close()

	c := New("nope", srv.URL, "m", WithRetryPolicy(fastRetry()))
	_, err := c.Stream(context.Background(), provider.Request{})
	if err == nil {
		t.Fatal("expected error on 401")
	}
	if n := atomic.LoadInt32(&calls); n != 1 {
		t.Errorf("server calls = %d, want 1 (401 not retried)", n)
	}
}
