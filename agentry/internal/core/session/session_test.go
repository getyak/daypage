package session

import (
	"testing"
	"time"
)

// TestLenTracksAppends verifies Len reports the running event count without a
// full Events() copy, and stays in sync as events are appended.
func TestLenTracksAppends(t *testing.T) {
	s := New("len-test")
	if got := s.Len(); got != 0 {
		t.Fatalf("Len() of fresh session = %d, want 0", got)
	}
	s.Append(Event{Type: EvUser, Text: "one"})
	s.Append(Event{Type: EvAssistant, Text: "two"})
	if got := s.Len(); got != 2 {
		t.Fatalf("Len() = %d, want 2", got)
	}
	if got, want := s.Len(), len(s.Events()); got != want {
		t.Fatalf("Len() = %d but len(Events()) = %d; they must agree", got, want)
	}
}

// TestCreatedIsSetAndSurvivesRoundTrip verifies Created reports a non-zero time
// for a fresh session and that the original creation time is preserved across a
// Save/Load round trip (so a listing can order/display sessions by age).
func TestCreatedIsSetAndSurvivesRoundTrip(t *testing.T) {
	s := New("created-test")
	created := s.Created()
	if created.IsZero() {
		t.Fatal("Created() of a fresh session is zero")
	}

	store := NewJSONLStore(t.TempDir())
	if err := store.Save(s); err != nil {
		t.Fatalf("Save: %v", err)
	}
	loaded, err := store.Load("created-test")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	// The persisted header records Created; the reloaded session must echo it
	// (allowing for sub-second JSON time encoding equality via Equal).
	if !loaded.Created().Equal(created) {
		t.Errorf("reloaded Created() = %v, want %v", loaded.Created(), created)
	}
	// And it must remain a sane, non-future timestamp.
	if loaded.Created().After(time.Now().Add(time.Minute)) {
		t.Errorf("reloaded Created() %v is implausibly in the future", loaded.Created())
	}
}

// TestHistoryAttachesToolCallsToAssistant verifies that EvToolCall events are
// folded into the preceding assistant message's ToolCalls, so the reconstructed
// history satisfies the OpenAI/Anthropic contract that every role:tool result is
// preceded by an assistant message carrying the matching tool_calls. Without
// this, strict backends (e.g. DeepSeek) reject the request with HTTP 400.
func TestHistoryAttachesToolCallsToAssistant(t *testing.T) {
	s := New("history-toolcalls")
	s.Append(Event{Type: EvUser, Text: "read the file"})
	s.Append(Event{Type: EvAssistant, Text: "sure, reading"})
	s.Append(Event{Type: EvToolCall, Tool: "fs.read", CallID: "call_1", Args: []byte(`{"path":"x"}`)})
	s.Append(Event{Type: EvToolResult, Tool: "fs.read", CallID: "call_1", Text: "contents"})
	s.Append(Event{Type: EvAssistant, Text: "the file says hi"})

	msgs := s.History()
	if len(msgs) != 4 {
		t.Fatalf("History len = %d, want 4 (user, assistant+toolcall, tool, assistant)", len(msgs))
	}
	// messages[1] = assistant carrying the tool call.
	am := msgs[1]
	if am.Role != "assistant" || am.Text != "sure, reading" {
		t.Fatalf("msgs[1] = %+v, want assistant 'sure, reading'", am)
	}
	if len(am.ToolCalls) != 1 {
		t.Fatalf("assistant ToolCalls = %d, want 1", len(am.ToolCalls))
	}
	if tc := am.ToolCalls[0]; tc.ID != "call_1" || tc.Name != "fs.read" || string(tc.Args) != `{"path":"x"}` {
		t.Errorf("ToolCalls[0] = %+v, want id=call_1 name=fs.read args={\"path\":\"x\"}", tc)
	}
	// messages[2] = the tool result, immediately after the assistant tool_calls.
	if tm := msgs[2]; tm.Role != "tool" || tm.ToolCallID != "call_1" || tm.Text != "contents" {
		t.Errorf("msgs[2] = %+v, want tool result for call_1", tm)
	}
}

// TestHistorySynthesizesAssistantCarrier verifies that a tool_call with no
// preceding assistant message (e.g. the model jumped straight to a tool) still
// produces an assistant carrier rather than an orphaned role:tool.
func TestHistorySynthesizesAssistantCarrier(t *testing.T) {
	s := New("history-carrier")
	s.Append(Event{Type: EvUser, Text: "go"})
	s.Append(Event{Type: EvToolCall, Tool: "web.fetch", CallID: "c1", Args: []byte(`{"url":"http://x"}`)})
	s.Append(Event{Type: EvToolResult, Tool: "web.fetch", CallID: "c1", Text: "200"})

	msgs := s.History()
	if len(msgs) != 3 {
		t.Fatalf("History len = %d, want 3 (user, synth-assistant, tool)", len(msgs))
	}
	am := msgs[1]
	if am.Role != "assistant" || am.Text != "" || len(am.ToolCalls) != 1 {
		t.Fatalf("msgs[1] = %+v, want empty-text assistant with 1 tool call", am)
	}
	if am.ToolCalls[0].Name != "web.fetch" {
		t.Errorf("carrier tool call name = %q, want web.fetch", am.ToolCalls[0].Name)
	}
}

// TestHistoryArgsSurvivePersistedRoundTrip verifies that tool-call Args decoded
// from JSONL (where they are a map, not a json.RawMessage) are re-marshaled back
// to valid JSON in the reconstructed history.
func TestHistoryArgsSurvivePersistedRoundTrip(t *testing.T) {
	s := New("history-args")
	s.Append(Event{Type: EvAssistant, Text: ""})
	// Simulate a replayed event: Args decoded from JSON is a map[string]any.
	s.Append(Event{Type: EvToolCall, Tool: "fs.read", CallID: "c1", Args: map[string]any{"path": "y"}})

	msgs := s.History()
	if len(msgs) != 1 {
		t.Fatalf("History len = %d, want 1 (assistant with tool call)", len(msgs))
	}
	if len(msgs[0].ToolCalls) != 1 {
		t.Fatalf("ToolCalls = %d, want 1", len(msgs[0].ToolCalls))
	}
	if got := string(msgs[0].ToolCalls[0].Args); got != `{"path":"y"}` {
		t.Errorf("re-marshaled args = %s, want {\"path\":\"y\"}", got)
	}
}
