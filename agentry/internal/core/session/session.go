// Package session defines durable conversation state as an append-only event
// log. The same event stream is persisted (JSONL), replayed on resume, and
// rendered by every client (TUI, Web UI, stdio transport).
package session

import (
	"sync"
	"time"

	"github.com/kubbot/agentry/internal/core/provider"
)

// EventType discriminates a session Event.
type EventType string

const (
	EvUser       EventType = "user"
	EvAssistant  EventType = "assistant"
	EvToolCall   EventType = "tool_call"
	EvToolResult EventType = "tool_result"
	EvMeta       EventType = "meta"
	EvError      EventType = "error"
)

// Event is one immutable entry in a session's history.
type Event struct {
	Seq     int            `json:"seq"`
	Type    EventType      `json:"type"`
	Text    string         `json:"text,omitempty"`
	Tool    string         `json:"tool,omitempty"`
	CallID  string         `json:"call_id,omitempty"`
	Args    any            `json:"args,omitempty"`
	IsError bool           `json:"is_error,omitempty"`
	Meta    map[string]any `json:"meta,omitempty"`
	At      time.Time      `json:"at"`
}

// Session is one conversation: identity, ambient execution context, and history.
// It is safe for concurrent append + read.
type Session struct {
	mu sync.RWMutex

	ID    string `json:"id"`
	Title string `json:"title,omitempty"`
	Model string `json:"model,omitempty"`

	// Ambient execution context available to tools.
	Cwd string            `json:"cwd,omitempty"`
	Env map[string]string `json:"env,omitempty"`

	events  []Event
	seq     int
	subs    []chan Event // live subscribers (TUI/Web/stdio)
	created time.Time
}

// New returns an empty session with the given id.
func New(id string) *Session {
	return &Session{ID: id, Env: map[string]string{}, created: time.Now()}
}

// Append records an event, assigns its Seq/At, and fans it out to subscribers.
func (s *Session) Append(e Event) Event {
	s.mu.Lock()
	s.seq++
	e.Seq = s.seq
	if e.At.IsZero() {
		e.At = time.Now()
	}
	s.events = append(s.events, e)
	subs := append([]chan Event(nil), s.subs...)
	s.mu.Unlock()

	for _, ch := range subs {
		// Non-blocking: a slow subscriber never stalls the loop.
		select {
		case ch <- e:
		default:
		}
	}
	return e
}

// Events returns a copy of the full history.
func (s *Session) Events() []Event {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return append([]Event(nil), s.events...)
}

// Len reports the number of events in the session's history without copying it,
// so a caller that only needs the count (e.g. a session listing) does not pay for
// a full Events() clone.
func (s *Session) Len() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.events)
}

// Created reports when the session was first created. A session loaded from the
// store carries the original creation time recorded in its header; a freshly
// constructed one carries the time New ran. Exposed (read-only) so a listing can
// order or display sessions by age without reaching into unexported state.
func (s *Session) Created() time.Time {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.created
}

// Subscribe returns a channel of future events and an unsubscribe func.
func (s *Session) Subscribe() (<-chan Event, func()) {
	ch := make(chan Event, 256)
	s.mu.Lock()
	s.subs = append(s.subs, ch)
	s.mu.Unlock()
	return ch, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		for i, c := range s.subs {
			if c == ch {
				s.subs = append(s.subs[:i], s.subs[i+1:]...)
				close(ch)
				return
			}
		}
	}
}

// History reconstructs the provider-facing message list from the event log.
// Consecutive assistant text/tool-call events within a turn are coalesced.
func (s *Session) History() []provider.Message {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var msgs []provider.Message
	for _, e := range s.events {
		switch e.Type {
		case EvUser:
			msgs = append(msgs, provider.Message{Role: provider.RoleUser, Text: e.Text})
		case EvAssistant:
			msgs = append(msgs, provider.Message{Role: provider.RoleAssistant, Text: e.Text})
		case EvToolResult:
			msgs = append(msgs, provider.Message{
				Role:       provider.RoleTool,
				ToolCallID: e.CallID,
				Name:       e.Tool,
				Text:       e.Text,
			})
		}
	}
	return msgs
}
