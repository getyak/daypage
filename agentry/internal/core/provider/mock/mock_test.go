package mock

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/kubbot/agentry/internal/core/provider"
)

// drain collects every event from a stream into a slice. It assumes the stream
// terminates (the mock always closes its channel).
func drain(t *testing.T, ch <-chan provider.Event) []provider.Event {
	t.Helper()
	var got []provider.Event
	for ev := range ch {
		got = append(got, ev)
	}
	return got
}

func TestStream_Steps(t *testing.T) {
	tests := []struct {
		name string
		step Step
		req  provider.Request
		// want is the expected sequence of (Kind, payload) pairs, described
		// compactly: text deltas, an optional tool call name, and the final
		// stop reason on the terminal EventDone.
		wantDeltas []string
		wantTool   string // tool call name, "" if none
		wantStop   string
	}{
		{
			name:       "single text delta",
			step:       Text("hello"),
			wantDeltas: []string{"hello"},
			wantStop:   "end_turn",
		},
		{
			name:       "multiple text deltas stream in order",
			step:       Step{TextDeltas: []string{"a", "b", "c"}},
			wantDeltas: []string{"a", "b", "c"},
			wantStop:   "end_turn", // defaulted: no tool call
		},
		{
			name:       "empty deltas are skipped",
			step:       Step{TextDeltas: []string{"x", "", "y"}},
			wantDeltas: []string{"x", "y"},
			wantStop:   "end_turn",
		},
		{
			name:       "tool call with leading text defaults to tool_use",
			step:       CallTool("c1", "fs.read", json.RawMessage(`{"path":"/tmp"}`), "thinking"),
			wantDeltas: []string{"thinking"},
			wantTool:   "fs.read",
			wantStop:   "tool_use",
		},
		{
			name:       "explicit stop reason is honored",
			step:       Step{TextDeltas: []string{"done"}, StopReason: "max_tokens"},
			wantDeltas: []string{"done"},
			wantStop:   "max_tokens",
		},
		{
			name:       "zero step emits only terminal done",
			step:       Step{},
			wantDeltas: nil,
			wantStop:   "end_turn",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			m := New(tc.step)
			ch, err := m.Stream(context.Background(), tc.req)
			if err != nil {
				t.Fatalf("Stream returned error: %v", err)
			}
			got := drain(t, ch)

			var gotDeltas []string
			var gotTool, gotStop string
			doneCount := 0
			for _, ev := range got {
				switch ev.Kind {
				case provider.EventText:
					gotDeltas = append(gotDeltas, ev.TextDelta)
				case provider.EventToolCall:
					if ev.ToolCall == nil {
						t.Fatalf("EventToolCall with nil ToolCall")
					}
					gotTool = ev.ToolCall.Name
				case provider.EventDone:
					doneCount++
					gotStop = ev.StopReason
				case provider.EventError:
					t.Fatalf("unexpected EventError: %v", ev.Err)
				}
			}

			if doneCount != 1 {
				t.Fatalf("expected exactly 1 EventDone, got %d (events: %+v)", doneCount, got)
			}
			if !equalStrings(gotDeltas, tc.wantDeltas) {
				t.Errorf("deltas = %q, want %q", gotDeltas, tc.wantDeltas)
			}
			if gotTool != tc.wantTool {
				t.Errorf("tool = %q, want %q", gotTool, tc.wantTool)
			}
			if gotStop != tc.wantStop {
				t.Errorf("stop = %q, want %q", gotStop, tc.wantStop)
			}
			// EventDone must be the last event in the stream.
			if last := got[len(got)-1]; last.Kind != provider.EventDone {
				t.Errorf("last event kind = %d, want EventDone", last.Kind)
			}
		})
	}
}

// TestMultiTurnScript verifies the queue advances one Step per Stream call,
// modeling an engine driving a tool loop, and that the cursor is reported.
func TestMultiTurnScript(t *testing.T) {
	m := New(
		CallTool("c1", "calc", json.RawMessage(`{"x":2}`)),
		Text("the answer is 4"),
	)
	if got := m.Remaining(); got != 2 {
		t.Fatalf("Remaining before = %d, want 2", got)
	}

	// Turn 1: tool call.
	ch, _ := m.Stream(context.Background(), provider.Request{})
	ev1 := drain(t, ch)
	if ev1[0].Kind != provider.EventToolCall || ev1[0].ToolCall.Name != "calc" {
		t.Fatalf("turn 1 first event = %+v, want tool call calc", ev1[0])
	}
	if got := m.Remaining(); got != 1 {
		t.Fatalf("Remaining after turn 1 = %d, want 1", got)
	}

	// Turn 2: final text.
	ch, _ = m.Stream(context.Background(), provider.Request{})
	ev2 := drain(t, ch)
	if ev2[0].Kind != provider.EventText || ev2[0].TextDelta != "the answer is 4" {
		t.Fatalf("turn 2 first event = %+v, want text", ev2[0])
	}
	if got := m.Remaining(); got != 0 {
		t.Fatalf("Remaining after turn 2 = %d, want 0", got)
	}

	// Reset replays the script from the top.
	m.Reset()
	if got := m.Remaining(); got != 2 {
		t.Fatalf("Remaining after Reset = %d, want 2", got)
	}
}

// TestEchoFallback verifies that an exhausted/empty script echoes the last user
// message, and that non-user trailing messages are skipped.
func TestEchoFallback(t *testing.T) {
	tests := []struct {
		name string
		msgs []provider.Message
		want string // expected single echoed delta, "" means no text event
	}{
		{
			name: "echoes last user message",
			msgs: []provider.Message{
				{Role: provider.RoleUser, Text: "first"},
				{Role: provider.RoleAssistant, Text: "reply"},
				{Role: provider.RoleUser, Text: "second"},
			},
			want: "second",
		},
		{
			name: "skips trailing tool/assistant to find user",
			msgs: []provider.Message{
				{Role: provider.RoleUser, Text: "question"},
				{Role: provider.RoleAssistant, Text: "ans"},
				{Role: provider.RoleTool, Text: "toolout"},
			},
			want: "question",
		},
		{
			name: "no user message yields no text",
			msgs: []provider.Message{{Role: provider.RoleSystem, Text: "sys"}},
			want: "",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			m := New() // unscripted → echo mode
			ch, _ := m.Stream(context.Background(), provider.Request{Messages: tc.msgs})
			got := drain(t, ch)

			var text string
			for _, ev := range got {
				if ev.Kind == provider.EventText {
					text = ev.TextDelta
				}
			}
			if text != tc.want {
				t.Errorf("echo text = %q, want %q", text, tc.want)
			}
			if got[len(got)-1].Kind != provider.EventDone {
				t.Errorf("stream did not end with EventDone")
			}
		})
	}
}

// TestContextCancellation verifies that a canceled context stops emission and
// the stream still terminates (channel closes) rather than leaking a goroutine.
func TestContextCancellation(t *testing.T) {
	// Many deltas so emission would block on an unbuffered channel; we cancel
	// before reading, so the producer should bail out promptly.
	m := New(Step{TextDeltas: []string{"a", "b", "c", "d", "e"}})

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cancel up front

	ch, err := m.Stream(ctx, provider.Request{})
	if err != nil {
		t.Fatalf("Stream error: %v", err)
	}

	// Drain to completion; must not hang. The producer either emits an
	// EventError (ctx.Err) or simply closes after the cancel is observed.
	got := drain(t, ch)
	for _, ev := range got {
		if ev.Kind == provider.EventDone {
			t.Errorf("did not expect EventDone after cancellation, got %+v", ev)
		}
	}
}

func TestName(t *testing.T) {
	if got := New().Name(); got != "mock" {
		t.Errorf("default Name() = %q, want mock", got)
	}
	if got := NewWith([]Option{WithName("fake")}).Name(); got != "fake" {
		t.Errorf("Name() with WithName = %q, want fake", got)
	}
}

// TestImplementsProvider is a compile-time assertion that *Mock satisfies the
// Provider seam.
func TestImplementsProvider(t *testing.T) {
	var _ provider.Provider = (*Mock)(nil)
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
