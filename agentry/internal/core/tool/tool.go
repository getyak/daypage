// Package tool defines the capability seam and a concurrency-safe registry.
//
// A browser action, a filesystem read, an MCP-proxied remote tool, and a
// sub-agent are all Tools. That uniformity is what lets the agent loop treat
// every capability identically and lets the policy gate mediate all of them.
package tool

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"sync"
)

// Input carries the model-supplied arguments plus an ambient context handle.
// The concrete ambient type is provided by the caller (the agent engine passes
// its *session.Session); tools that need it type-assert via the accessor on
// Context. Kept as any here to avoid an import cycle with session.
type Input struct {
	Args json.RawMessage
	// Session is the ambient *session.Session, exposed as any to break the
	// import cycle (session imports tool indirectly via the engine).
	Session any
}

// Result is what a tool returns to the model.
type Result struct {
	// Content is the textual result shown to the model.
	Content string `json:"content"`
	// IsError marks a tool-level failure that the model should see and react to
	// (as opposed to a transport error returned via the error value).
	IsError bool `json:"is_error,omitempty"`
	// Meta is optional structured data for UIs (e.g. a screenshot path).
	Meta map[string]any `json:"meta,omitempty"`
}

// Tool is a single capability the agent can invoke.
type Tool interface {
	Name() string
	Description() string
	Schema() json.RawMessage // JSON Schema for Args
	Invoke(ctx context.Context, in Input) (Result, error)
}

// Registry is a concurrency-safe set of tools keyed by name.
type Registry struct {
	mu    sync.RWMutex
	tools map[string]Tool
}

// NewRegistry returns an empty registry.
func NewRegistry() *Registry { return &Registry{tools: map[string]Tool{}} }

// Register adds a tool, returning an error on duplicate names.
func (r *Registry) Register(t Tool) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.tools[t.Name()]; ok {
		return fmt.Errorf("tool %q already registered", t.Name())
	}
	r.tools[t.Name()] = t
	return nil
}

// MustRegister panics on error; for static wiring at startup.
func (r *Registry) MustRegister(t Tool) {
	if err := r.Register(t); err != nil {
		panic(err)
	}
}

// Get returns a tool by name.
func (r *Registry) Get(name string) (Tool, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	t, ok := r.tools[name]
	return t, ok
}

// List returns all tools sorted by name (stable for specs/UX).
func (r *Registry) List() []Tool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]Tool, 0, len(r.tools))
	for _, t := range r.tools {
		out = append(out, t)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name() < out[j].Name() })
	return out
}
