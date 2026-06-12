// Package openaicompat implements provider.Provider for any backend that speaks
// the OpenAI /v1/chat/completions API. That single wire format covers OpenAI
// itself, Aliyun DashScope (qwen), and the many local servers (llama.cpp,
// vLLM, Ollama's OpenAI shim, LM Studio, ...) that emulate it, so one adapter
// unlocks a large slice of the ecosystem.
//
// The adapter is deliberately thin: it translates the normalized
// provider.Request into the OpenAI request body, opens a streaming (SSE)
// connection, and folds the Server-Sent Events back into the normalized
// provider.Event stream. It depends only on net/http, bufio, and encoding/json.
//
// Streaming contract: OpenAI returns a sequence of `data: {json}` lines, each a
// chat-completion *chunk*. Text arrives as choices[].delta.content. Tool calls
// arrive incrementally — a chunk carries choices[].delta.tool_calls[] where
// each element has an index, and the name/id/arguments are spread across many
// chunks and must be concatenated per index. We buffer them and emit a single
// provider.EventToolCall per completed call when the stream finishes. The
// terminal `data: [DONE]` sentinel maps to provider.EventDone.
package openaicompat

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/kubbot/agentry/internal/core/provider"
	"github.com/kubbot/agentry/internal/core/provider/retry"
)

// providerName is the stable Name() of this adapter.
const providerName = "openaicompat"

// defaultTimeout bounds a single streaming turn end-to-end. Streaming responses
// can legitimately run long, so this is generous; ctx cancellation remains the
// primary, caller-driven stop signal.
const defaultTimeout = 5 * time.Minute

// maxLineBytes caps a single SSE line to guard against a hostile or buggy server
// streaming an unbounded line and exhausting memory. 8 MiB comfortably fits any
// realistic tool-argument payload.
const maxLineBytes = 8 << 20

// Client is an OpenAI-compatible provider.Provider. It is safe for concurrent
// use: it holds only immutable configuration plus an *http.Client (itself
// concurrency-safe), and all per-turn state lives on the stack of Stream.
type Client struct {
	apiKey  string
	baseURL string // normalized: trailing slash trimmed
	model   string // default model when Request.Model is empty
	http    *http.Client
	retry   retry.Policy // applied to http.Transport unless retries are disabled
	noRetry bool
}

// Option configures a Client.
type Option func(*Client)

// WithHTTPClient overrides the default *http.Client (e.g. to inject a custom
// transport, proxy, or test round-tripper). A nil client is ignored. The
// adapter still layers transient-failure retries on top of the supplied client's
// transport unless WithoutRetry is also given.
func WithHTTPClient(h *http.Client) Option {
	return func(c *Client) {
		if h != nil {
			c.http = h
		}
	}
}

// WithRetryPolicy overrides the default transient-failure retry policy
// (exponential backoff on 429/5xx/network errors). It has no effect when
// WithoutRetry is given.
func WithRetryPolicy(p retry.Policy) Option {
	return func(c *Client) { c.retry = p }
}

// WithoutRetry disables the built-in HTTP retry layer entirely, sending each
// request exactly once.
func WithoutRetry() Option {
	return func(c *Client) { c.noRetry = true }
}

// New constructs a Client targeting baseURL with the given API key and default
// model. baseURL should be the API root that precedes "/chat/completions"
// (e.g. "https://api.openai.com/v1" or
// "https://dashscope.aliyuncs.com/compatible-mode/v1"); any trailing slash is
// trimmed. The default model is used for requests that leave Request.Model
// empty.
func New(apiKey, baseURL, model string, opts ...Option) *Client {
	c := &Client{
		apiKey:  apiKey,
		baseURL: strings.TrimRight(baseURL, "/"),
		model:   model,
		http:    &http.Client{Timeout: defaultTimeout},
		retry:   retry.DefaultPolicy(),
	}
	for _, opt := range opts {
		opt(c)
	}
	// Layer transient-failure retries (429/5xx/network) onto the HTTP client's
	// transport unless explicitly disabled. The request body is fully buffered
	// before each send (bytes.Reader), so POSTs are safely replayable. Done after
	// options so it wraps whatever transport WithHTTPClient supplied.
	if !c.noRetry {
		c.http.Transport = retry.New(c.http.Transport, c.retry)
	}
	return c
}

// Name reports the provider name.
func (c *Client) Name() string { return providerName }

// Stream runs exactly one model turn. It builds and POSTs the chat-completions
// request, then spawns a goroutine that parses the SSE response and emits
// normalized events on the returned channel until it closes. The channel always
// closes; its final event is an EventDone (clean finish) or EventError
// (transport/parse failure or ctx cancellation). ctx cancellation aborts the
// in-flight HTTP request and stops emission promptly.
func (c *Client) Stream(ctx context.Context, req provider.Request) (<-chan provider.Event, error) {
	body, err := c.buildBody(req)
	if err != nil {
		return nil, fmt.Errorf("openaicompat: build request body: %w", err)
	}

	url := c.baseURL + "/chat/completions"
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("openaicompat: new request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "text/event-stream")
	if c.apiKey != "" {
		httpReq.Header.Set("Authorization", "Bearer "+c.apiKey)
	}

	resp, err := c.http.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("openaicompat: send request: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		// Drain and close the body so the connection can be reused, then surface
		// the server's error message (truncated) to the caller synchronously.
		msg := readErrorBody(resp.Body)
		resp.Body.Close()
		return nil, fmt.Errorf("openaicompat: http %d: %s", resp.StatusCode, msg)
	}

	out := make(chan provider.Event)
	go func() {
		defer close(out)
		defer resp.Body.Close()
		parseStream(ctx, resp.Body, out)
	}()
	return out, nil
}

// buildBody translates the normalized Request into the OpenAI chat-completions
// JSON wire body with stream:true.
func (c *Client) buildBody(req provider.Request) ([]byte, error) {
	model := req.Model
	if model == "" {
		model = c.model
	}

	msgs := make([]wireMessage, 0, len(req.Messages)+1)
	// OpenAI carries the system prompt as the first message, not a top-level
	// field. If both Request.System and a system Message exist, the explicit
	// field leads.
	if req.System != "" {
		sys := req.System
		msgs = append(msgs, wireMessage{Role: string(provider.RoleSystem), Content: &sys})
	}
	for _, m := range req.Messages {
		msgs = append(msgs, toWireMessage(m))
	}

	b := wireRequest{
		Model:    model,
		Messages: msgs,
		Stream:   true,
	}
	if len(req.Tools) > 0 {
		b.Tools = make([]wireTool, 0, len(req.Tools))
		for _, t := range req.Tools {
			b.Tools = append(b.Tools, toWireTool(t))
		}
	}
	if req.Temperature != nil {
		b.Temperature = req.Temperature
	}
	if req.MaxTokens > 0 {
		b.MaxTokens = req.MaxTokens
	}

	return json.Marshal(b)
}

// --- wire types (request) ---

type wireRequest struct {
	Model       string        `json:"model"`
	Messages    []wireMessage `json:"messages"`
	Tools       []wireTool    `json:"tools,omitempty"`
	Stream      bool          `json:"stream"`
	Temperature *float64      `json:"temperature,omitempty"`
	MaxTokens   int           `json:"max_tokens,omitempty"`
}

type wireMessage struct {
	Role string `json:"role"`
	// Content is a pointer so an assistant message that carries only tool_calls
	// can omit it entirely (some servers reject an empty string there).
	Content    *string        `json:"content,omitempty"`
	ToolCalls  []wireToolCall `json:"tool_calls,omitempty"`
	ToolCallID string         `json:"tool_call_id,omitempty"`
	Name       string         `json:"name,omitempty"`
}

type wireToolCall struct {
	ID       string           `json:"id"`
	Type     string           `json:"type"` // always "function"
	Index    int              `json:"index,omitempty"`
	Function wireFunctionCall `json:"function"`
}

type wireFunctionCall struct {
	Name string `json:"name"`
	// Arguments is a JSON-encoded string per the OpenAI schema (not an object).
	Arguments string `json:"arguments"`
}

type wireTool struct {
	Type     string           `json:"type"` // always "function"
	Function wireFunctionSpec `json:"function"`
}

type wireFunctionSpec struct {
	Name        string          `json:"name"`
	Description string          `json:"description,omitempty"`
	Parameters  json.RawMessage `json:"parameters,omitempty"`
}

// toWireMessage maps one normalized provider.Message to the OpenAI shape.
func toWireMessage(m provider.Message) wireMessage {
	wm := wireMessage{Role: string(m.Role)}

	switch m.Role {
	case provider.RoleTool:
		// A tool result: role:tool with the originating call id and content.
		// The name must match the (encoded) function name the model emitted, so
		// the backend can correlate the result with its tool call.
		wm.ToolCallID = m.ToolCallID
		wm.Name = encodeToolName(m.Name)
		c := m.Text
		wm.Content = &c
	case provider.RoleAssistant:
		if m.Text != "" {
			c := m.Text
			wm.Content = &c
		}
		if len(m.ToolCalls) > 0 {
			wm.ToolCalls = make([]wireToolCall, 0, len(m.ToolCalls))
			for _, tc := range m.ToolCalls {
				wm.ToolCalls = append(wm.ToolCalls, wireToolCall{
					ID:   tc.ID,
					Type: "function",
					Function: wireFunctionCall{
						Name:      encodeToolName(tc.Name),
						Arguments: argsToString(tc.Args),
					},
				})
			}
		}
	default:
		// system / user: plain content.
		c := m.Text
		wm.Content = &c
	}
	return wm
}

// Agentry tool names use a "<namespace>.<verb>" convention (e.g. "fs.read",
// "web.fetch", "agent.<name>"), but some OpenAI-compatible backends — notably
// DeepSeek — reject function names that don't match ^[a-zA-Z0-9_-]+$, so the dot
// triggers an HTTP 400 before any tool can run. encodeToolName/decodeToolName
// are a transport-only escaping that keeps the wire name within that charset
// while preserving the real registry key on the way back.
//
// Only the dot is rewritten ("." <-> "__"); names already within the charset —
// including ones that legitimately contain underscores like "get_weather" — are
// passed through untouched, so this is invisible to backends that never had a
// problem. The namespaced convention never places an underscore directly against
// the dot, so "__" is an unambiguous stand-in for the separator.
func encodeToolName(name string) string {
	if !strings.Contains(name, ".") {
		return name // already wire-safe (covers plain and underscore-only names)
	}
	return strings.ReplaceAll(name, ".", "__")
}

// decodeToolName reverses encodeToolName, mapping the "__" separator back to a
// dot. Names without "__" (the common case, and any plain underscore name)
// round-trip unchanged.
func decodeToolName(name string) string {
	if !strings.Contains(name, "__") {
		return name
	}
	return strings.ReplaceAll(name, "__", ".")
}

// toWireTool maps a ToolSpec to the OpenAI function-tool shape.
func toWireTool(t provider.ToolSpec) wireTool {
	return wireTool{
		Type: "function",
		Function: wireFunctionSpec{
			Name:        encodeToolName(t.Name),
			Description: t.Description,
			Parameters:  t.Schema,
		},
	}
}

// argsToString renders normalized tool-call Args (raw JSON) as the JSON *string*
// the OpenAI "arguments" field expects. Empty/invalid args degrade to "{}" so
// the server always receives a valid JSON object literal.
func argsToString(raw json.RawMessage) string {
	s := strings.TrimSpace(string(raw))
	if s == "" || s == "null" {
		return "{}"
	}
	return s
}

// --- wire types (streaming response chunk) ---

type streamChunk struct {
	Choices []streamChoice `json:"choices"`
	Usage   *wireUsage     `json:"usage"`
}

type streamChoice struct {
	Delta        streamDelta `json:"delta"`
	FinishReason *string     `json:"finish_reason"`
}

type streamDelta struct {
	Content   string                `json:"content"`
	ToolCalls []streamToolCallDelta `json:"tool_calls"`
}

type streamToolCallDelta struct {
	Index    int    `json:"index"`
	ID       string `json:"id"`
	Type     string `json:"type"`
	Function *struct {
		Name      string `json:"name"`
		Arguments string `json:"arguments"`
	} `json:"function"`
}

type wireUsage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
}

// toolCallAccumulator buffers the fragments of one tool call as they stream in
// across chunks. The id and name typically arrive in the first fragment for a
// given index; arguments are concatenated from every fragment.
type toolCallAccumulator struct {
	id   string
	name string
	args strings.Builder
}

// parseStream reads the SSE body line-by-line and emits normalized events.
// It runs on Stream's goroutine and is responsible for the channel's content
// (the caller closes the channel and the body).
func parseStream(ctx context.Context, body io.Reader, out chan<- provider.Event) {
	send := func(ev provider.Event) bool {
		select {
		case <-ctx.Done():
			return false
		case out <- ev:
			return true
		}
	}

	scanner := bufio.NewScanner(body)
	scanner.Buffer(make([]byte, 0, 64<<10), maxLineBytes)

	// Tool calls keyed and ordered by stream index, so we can emit them in the
	// order the model produced them once the turn finishes.
	calls := map[int]*toolCallAccumulator{}
	var order []int
	finish := ""

	for scanner.Scan() {
		// Honor cancellation between lines as well as between sends.
		if ctx.Err() != nil {
			send(provider.Event{Kind: provider.EventError, Err: ctx.Err()})
			return
		}

		line := strings.TrimRight(scanner.Text(), "\r")
		if line == "" || strings.HasPrefix(line, ":") {
			// Blank separator line or SSE comment/heartbeat — ignore.
			continue
		}
		data, ok := strings.CutPrefix(line, "data:")
		if !ok {
			// SSE fields other than "data:" (event:, id:, retry:) are unused here.
			continue
		}
		data = strings.TrimSpace(data)

		if data == "[DONE]" {
			// Terminal sentinel: flush buffered tool calls, then finish.
			if !flushToolCalls(send, calls, order) {
				return
			}
			send(provider.Event{Kind: provider.EventDone, StopReason: normalizeFinish(finish)})
			return
		}

		var chunk streamChunk
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			// A malformed chunk is non-fatal: skip it and keep reading rather
			// than tearing down a possibly-recoverable stream.
			continue
		}

		if chunk.Usage != nil {
			if !send(provider.Event{
				Kind:  provider.EventUsage,
				Usage: &provider.Usage{InputTokens: chunk.Usage.PromptTokens, OutputTokens: chunk.Usage.CompletionTokens},
			}) {
				return
			}
		}

		for _, ch := range chunk.Choices {
			if ch.Delta.Content != "" {
				if !send(provider.Event{Kind: provider.EventText, TextDelta: ch.Delta.Content}) {
					return
				}
			}
			for _, tcd := range ch.Delta.ToolCalls {
				accumulateToolCall(calls, &order, tcd)
			}
			if ch.FinishReason != nil && *ch.FinishReason != "" {
				finish = *ch.FinishReason
			}
		}
	}

	// The stream ended without an explicit [DONE] sentinel (some servers just
	// close the connection). Treat a clean scanner end as a normal finish:
	// flush any buffered tool calls and emit a terminal done.
	if err := scanner.Err(); err != nil {
		// A read error after cancellation is just the canceled ctx surfacing.
		if ctx.Err() != nil {
			send(provider.Event{Kind: provider.EventError, Err: ctx.Err()})
			return
		}
		send(provider.Event{Kind: provider.EventError, Err: fmt.Errorf("openaicompat: read stream: %w", err)})
		return
	}
	if !flushToolCalls(send, calls, order) {
		return
	}
	send(provider.Event{Kind: provider.EventDone, StopReason: normalizeFinish(finish)})
}

// accumulateToolCall folds one streamed tool-call fragment into the per-index
// accumulator, recording first-seen order so emission preserves model order.
func accumulateToolCall(calls map[int]*toolCallAccumulator, order *[]int, d streamToolCallDelta) {
	acc, ok := calls[d.Index]
	if !ok {
		acc = &toolCallAccumulator{}
		calls[d.Index] = acc
		*order = append(*order, d.Index)
	}
	if d.ID != "" {
		acc.id = d.ID
	}
	if d.Function != nil {
		if d.Function.Name != "" {
			acc.name = d.Function.Name
		}
		if d.Function.Arguments != "" {
			acc.args.WriteString(d.Function.Arguments)
		}
	}
}

// flushToolCalls emits one EventToolCall per buffered call, in stream order.
// It returns false if a send was canceled (caller should stop).
func flushToolCalls(send func(provider.Event) bool, calls map[int]*toolCallAccumulator, order []int) bool {
	for _, idx := range order {
		acc := calls[idx]
		if acc == nil || acc.name == "" {
			// A fragment with no resolved function name is not a usable call.
			continue
		}
		args := strings.TrimSpace(acc.args.String())
		if args == "" {
			args = "{}"
		}
		tc := &provider.ToolCall{
			ID: acc.id,
			// Decode the wire name back to the real registry key (e.g.
			// "fs__read" -> "fs.read") so the engine can resolve the tool.
			Name: decodeToolName(acc.name),
			Args: json.RawMessage(args),
		}
		if !send(provider.Event{Kind: provider.EventToolCall, ToolCall: tc}) {
			return false
		}
	}
	return true
}

// normalizeFinish maps OpenAI finish_reason values onto the vocabulary the rest
// of the runtime uses. Unknown values pass through unchanged.
func normalizeFinish(reason string) string {
	switch reason {
	case "stop":
		return "end_turn"
	case "tool_calls", "function_call":
		return "tool_use"
	case "length":
		return "max_tokens"
	case "":
		return "end_turn"
	default:
		return reason
	}
}

// readErrorBody reads up to a small bound of an error response body for
// inclusion in an error message, collapsing whitespace.
func readErrorBody(r io.Reader) string {
	const max = 4 << 10
	b, _ := io.ReadAll(io.LimitReader(r, max))
	s := strings.TrimSpace(string(b))
	if s == "" {
		return "(empty body)"
	}
	return s
}
