// Package mock provides a deterministic provider.Provider for tests and offline
// runs. It never touches the network, never uses time or randomness, and always
// emits the same events for the same script — so engine tests can drive
// multi-turn tool loops reproducibly.
//
// Two modes:
//
//  1. Scripted. Construct with New(steps...). Each call to Stream pops the next
//     Step from the queue and emits its text deltas and/or tool call, finishing
//     with an EventDone. This lets a test script an entire reason→act→observe
//     loop (e.g. "turn 1: ask to call tool X; turn 2: produce final answer").
//
//  2. Echo. If the queue is empty/exhausted, Stream falls back to echoing the
//     text of the last user message in the request. This keeps a bare
//     mock.New() useful as a trivial stand-in.
package mock

import (
	"context"
	"sync"

	"github.com/kubbot/agentry/internal/core/provider"
)

// Step is one canned model turn. Its events are emitted in this order:
// every TextDeltas entry (as EventText), then ToolCall (as EventToolCall) if
// non-nil, then a single EventUsage if Usage is non-nil, then a terminal
// EventDone carrying StopReason.
//
// A zero Step is valid: it emits nothing but the terminal EventDone.
type Step struct {
	// TextDeltas are streamed one-by-one as EventText events. Splitting a reply
	// into several deltas lets tests exercise incremental rendering.
	TextDeltas []string
	// ToolCall, if set, is emitted as a single EventToolCall after the text.
	ToolCall *provider.ToolCall
	// Usage, if set, is emitted as an EventUsage before the terminal event.
	Usage *provider.Usage
	// StopReason is carried on the terminal EventDone. If empty, a sensible
	// default is chosen: "tool_use" when ToolCall is set, else "end_turn".
	StopReason string
}

// Text is a convenience constructor for a plain text turn delivered as a single
// delta and ending the turn.
func Text(s string) Step { return Step{TextDeltas: []string{s}, StopReason: "end_turn"} }

// CallTool is a convenience constructor for a turn that requests a single tool
// call. The optional leading text (if any) is sent before the call.
func CallTool(id, name string, args []byte, text ...string) Step {
	return Step{
		TextDeltas: text,
		ToolCall:   &provider.ToolCall{ID: id, Name: name, Args: append([]byte(nil), args...)},
		StopReason: "tool_use",
	}
}

// Mock is a deterministic Provider. It is safe for concurrent use; the agent
// loop calls Stream once per turn, advancing through the script under a mutex.
type Mock struct {
	name string

	mu     sync.Mutex
	script []Step
	cursor int // index of the next Step to play
}

// Option configures a Mock.
type Option func(*Mock)

// WithName overrides the provider name (default "mock").
func WithName(name string) Option {
	return func(m *Mock) { m.name = name }
}

// New returns a Mock that plays the given steps in order, then falls back to
// echo mode once the script is exhausted.
func New(script ...Step) *Mock {
	return &Mock{name: "mock", script: append([]Step(nil), script...)}
}

// NewWith returns a Mock configured by options in addition to a script.
func NewWith(opts []Option, script ...Step) *Mock {
	m := New(script...)
	for _, opt := range opts {
		opt(m)
	}
	return m
}

// Name reports the provider name.
func (m *Mock) Name() string { return m.name }

// Remaining reports how many scripted steps have not yet been played. Useful in
// tests to assert the whole script was consumed.
func (m *Mock) Remaining() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.cursor >= len(m.script) {
		return 0
	}
	return len(m.script) - m.cursor
}

// Reset rewinds the script cursor to the beginning.
func (m *Mock) Reset() {
	m.mu.Lock()
	m.cursor = 0
	m.mu.Unlock()
}

// Stream plays one turn. It pops the next scripted Step if one remains;
// otherwise it synthesizes an echo Step from the request's last user message.
// Events are produced on a goroutine and the channel is closed when the turn
// ends. ctx cancellation stops emission promptly.
func (m *Mock) Stream(ctx context.Context, req provider.Request) (<-chan provider.Event, error) {
	step, ok := m.next()
	if !ok {
		step = echoStep(req)
	}

	out := make(chan provider.Event)
	go func() {
		defer close(out)
		emit(ctx, out, step)
	}()
	return out, nil
}

// next pops the next scripted step, reporting whether one was available.
func (m *Mock) next() (Step, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.cursor >= len(m.script) {
		return Step{}, false
	}
	s := m.script[m.cursor]
	m.cursor++
	return s, true
}

// emit writes a Step's events to out, respecting ctx cancellation between each
// send. On cancellation it emits a terminal EventError (best-effort) and stops.
func emit(ctx context.Context, out chan<- provider.Event, step Step) {
	send := func(ev provider.Event) bool {
		select {
		case <-ctx.Done():
			return false
		case out <- ev:
			return true
		}
	}

	for _, d := range step.TextDeltas {
		if d == "" {
			continue
		}
		if !send(provider.Event{Kind: provider.EventText, TextDelta: d}) {
			signalCanceled(ctx, out)
			return
		}
	}

	if step.ToolCall != nil {
		// Defensively copy so callers cannot observe mutation across turns.
		tc := *step.ToolCall
		if !send(provider.Event{Kind: provider.EventToolCall, ToolCall: &tc}) {
			signalCanceled(ctx, out)
			return
		}
	}

	if step.Usage != nil {
		u := *step.Usage
		if !send(provider.Event{Kind: provider.EventUsage, Usage: &u}) {
			signalCanceled(ctx, out)
			return
		}
	}

	stop := step.StopReason
	if stop == "" {
		if step.ToolCall != nil {
			stop = "tool_use"
		} else {
			stop = "end_turn"
		}
	}
	_ = send(provider.Event{Kind: provider.EventDone, StopReason: stop})
}

// signalCanceled best-effort emits a terminal EventError carrying ctx.Err().
// It does not block: if the consumer is gone, the event is simply dropped.
func signalCanceled(ctx context.Context, out chan<- provider.Event) {
	select {
	case out <- provider.Event{Kind: provider.EventError, Err: ctx.Err()}:
	default:
	}
}

// echoStep builds a single-turn step that echoes the last user message text.
// If there is no user message, it produces an empty end_turn.
func echoStep(req provider.Request) Step {
	for i := len(req.Messages) - 1; i >= 0; i-- {
		if req.Messages[i].Role == provider.RoleUser {
			return Text(req.Messages[i].Text)
		}
	}
	return Step{StopReason: "end_turn"}
}
