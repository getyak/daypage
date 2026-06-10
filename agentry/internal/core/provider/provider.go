// Package provider defines the vendor-independent LLM backend seam.
//
// The agent loop never imports a vendor SDK. Each concrete provider (Anthropic,
// OpenAI-compatible, mock, ...) translates to and from the normalized schema
// declared here, so the runtime can switch backends at runtime.
package provider

import (
	"context"
	"encoding/json"
)

// Role identifies the author of a Message.
type Role string

const (
	RoleSystem    Role = "system"
	RoleUser      Role = "user"
	RoleAssistant Role = "assistant"
	RoleTool      Role = "tool"
)

// Message is one normalized turn in a conversation. A single assistant message
// may contain text and/or one or more tool calls; a tool message carries the
// result of a prior tool call (matched by ToolCallID).
type Message struct {
	Role       Role       `json:"role"`
	Text       string     `json:"text,omitempty"`
	ToolCalls  []ToolCall `json:"tool_calls,omitempty"`  // assistant → wants these invoked
	ToolCallID string     `json:"tool_call_id,omitempty"` // tool result → which call it answers
	Name       string     `json:"name,omitempty"`         // tool name for a tool result
}

// ToolCall is a model request to invoke a tool with JSON arguments.
type ToolCall struct {
	ID   string          `json:"id"`
	Name string          `json:"name"`
	Args json.RawMessage `json:"args"`
}

// ToolSpec advertises a tool to the model (name + description + JSON Schema).
type ToolSpec struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Schema      json.RawMessage `json:"schema"`
}

// Request is a single model turn.
type Request struct {
	Model    string
	System   string
	Messages []Message
	Tools    []ToolSpec
	// Temperature is optional; nil means "use provider default".
	Temperature *float64
	MaxTokens   int
}

// Usage reports token accounting for a turn (best-effort; providers may omit).
type Usage struct {
	InputTokens  int `json:"input_tokens"`
	OutputTokens int `json:"output_tokens"`
}

// EventKind discriminates a streamed Event.
type EventKind int

const (
	EventText     EventKind = iota // TextDelta is set
	EventToolCall                  // ToolCall is set
	EventUsage                     // Usage is set
	EventDone                      // StopReason is set; stream is ending
	EventError                     // Err is set
)

// Event is one item in a provider's output stream.
type Event struct {
	Kind       EventKind
	TextDelta  string
	ToolCall   *ToolCall
	Usage      *Usage
	StopReason string // e.g. "end_turn", "tool_use", "max_tokens"
	Err        error
}

// Provider is the LLM backend seam. Stream runs exactly one model turn and emits
// events on the returned channel until it closes (EventDone or EventError last).
// Implementations must honor ctx cancellation.
type Provider interface {
	Name() string
	Stream(ctx context.Context, req Request) (<-chan Event, error)
}
