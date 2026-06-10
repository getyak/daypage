// Package anthropic adapts the Anthropic Messages API to the vendor-independent
// provider.Provider seam. It speaks the wire protocol directly over net/http —
// no vendor SDK — translating provider.Request into an Anthropic request body,
// opening a streaming (SSE) response, and re-emitting the normalized
// provider.Event stream the agent loop consumes.
//
// Wire shape (POST {baseURL}/v1/messages):
//
//	headers: x-api-key, anthropic-version: 2023-06-01, content-type: application/json
//	body:    {model, system, messages[], tools[], max_tokens, temperature?, stream:true}
//
// Our normalized Messages are reconstructed into Anthropic's block model:
//   - RoleSystem  -> hoisted into the top-level "system" string (not a message)
//   - RoleUser    -> a user message with a text block
//   - RoleAssistant with text          -> assistant message with a text block
//   - RoleAssistant with ToolCalls     -> assistant message with tool_use block(s)
//   - RoleTool (a tool result)         -> a USER message carrying a tool_result
//     block whose tool_use_id == Message.ToolCallID
//
// Streaming events are parsed per the Anthropic SSE protocol:
//   - content_block_delta / text_delta        -> EventText
//   - content_block_start (type tool_use)     -> begin accumulating a tool call
//   - content_block_delta / input_json_delta  -> accumulate partial JSON args
//   - content_block_stop                      -> emit one EventToolCall (assembled)
//   - message_delta (stop_reason)             -> remembered for the terminal event
//   - message_stop                            -> EventDone (carrying stop_reason)
//   - any HTTP / parse / transport failure    -> EventError
package anthropic

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

// Default endpoint and required protocol version header value.
const (
	// DefaultBaseURL is the Anthropic API host used when New is given an empty
	// baseURL. The "/v1/messages" path is appended at request time.
	DefaultBaseURL = "https://api.anthropic.com"

	// anthropicVersion is the required "anthropic-version" header value.
	anthropicVersion = "2023-06-01"

	// providerName is reported by Name().
	providerName = "anthropic"

	// defaultMaxTokens is used when a Request does not specify MaxTokens.
	// The Messages API requires max_tokens, so a sane non-zero default is
	// substituted rather than sending 0 (which the API rejects).
	defaultMaxTokens = 4096

	// maxResponseLine caps a single SSE "data:" line to guard against a
	// pathological / hostile stream exhausting memory.
	maxResponseLine = 16 << 20 // 16 MiB
)

// Client is an Anthropic Messages API adapter. It is safe for concurrent use:
// Stream holds no per-call state on the Client and each call gets its own
// HTTP request, goroutine, and output channel.
type Client struct {
	apiKey  string
	baseURL string // no trailing slash; "/v1/messages" is appended
	model   string // default model when Request.Model is empty
	http    *http.Client
}

// New constructs an Anthropic provider client.
//
// apiKey is sent as the x-api-key header. baseURL overrides DefaultBaseURL when
// non-empty (trailing slashes are trimmed). model is the fallback used when a
// given Request leaves Model empty. The HTTP client has no global timeout —
// streaming responses are long-lived — so cancellation is driven entirely by
// the context passed to Stream.
func New(apiKey, baseURL, model string) *Client {
	base := strings.TrimRight(strings.TrimSpace(baseURL), "/")
	if base == "" {
		base = DefaultBaseURL
	}
	return &Client{
		apiKey:  strings.TrimSpace(apiKey),
		baseURL: base,
		model:   strings.TrimSpace(model),
		// No Timeout: streaming turns can legitimately run for minutes. The
		// context governs lifetime; a transport-level dial/idle safety net is
		// provided so a wedged connection cannot hang forever. The transport is
		// wrapped in a retry layer so a transient 429/5xx or a network error
		// before the SSE stream opens is retried with backoff (the request body
		// is fully buffered, so the POST is safely replayable).
		http: &http.Client{
			Transport: retry.New(&http.Transport{
				// Bound the wait for response headers; the body itself is
				// unbounded (it streams) and is cut off by ctx cancellation.
				ResponseHeaderTimeout: 60 * time.Second,
			}, retry.DefaultPolicy()),
		},
	}
}

// Name reports the provider name.
func (c *Client) Name() string { return providerName }

// ---- Request body types (provider.Request -> Anthropic) --------------------

type apiRequest struct {
	Model       string       `json:"model"`
	System      string       `json:"system,omitempty"`
	Messages    []apiMessage `json:"messages"`
	Tools       []apiTool    `json:"tools,omitempty"`
	MaxTokens   int          `json:"max_tokens"`
	Temperature *float64     `json:"temperature,omitempty"`
	Stream      bool         `json:"stream"`
}

// apiMessage is one Anthropic message. Content is always the block-array form
// (never the string shorthand) so text, tool_use, and tool_result can coexist.
type apiMessage struct {
	Role    string     `json:"role"` // "user" | "assistant"
	Content []apiBlock `json:"content"`
}

// apiBlock is a single content block. Only the fields relevant to the block's
// Type are populated; the rest are omitted. This one struct covers the few
// block kinds we ever send: text, tool_use, tool_result.
type apiBlock struct {
	Type string `json:"type"`

	// type == "text"
	Text string `json:"text,omitempty"`

	// type == "tool_use"
	ID    string          `json:"id,omitempty"`
	Name  string          `json:"name,omitempty"`
	Input json.RawMessage `json:"input,omitempty"`

	// type == "tool_result"
	ToolUseID string     `json:"tool_use_id,omitempty"`
	Content   []apiBlock `json:"content,omitempty"`
	IsError   bool       `json:"is_error,omitempty"`
}

type apiTool struct {
	Name        string          `json:"name"`
	Description string          `json:"description,omitempty"`
	InputSchema json.RawMessage `json:"input_schema"`
}

// buildRequest translates a normalized provider.Request into an Anthropic
// request body. It is pure (no I/O) and exported-in-spirit for unit testing via
// MarshalRequest below.
func (c *Client) buildRequest(req provider.Request) apiRequest {
	model := req.Model
	if strings.TrimSpace(model) == "" {
		model = c.model
	}

	maxTokens := req.MaxTokens
	if maxTokens <= 0 {
		maxTokens = defaultMaxTokens
	}

	out := apiRequest{
		Model:       model,
		System:      req.System,
		MaxTokens:   maxTokens,
		Temperature: req.Temperature,
		Stream:      true,
		Messages:    make([]apiMessage, 0, len(req.Messages)),
	}

	// Any system text carried as a RoleSystem message is folded into the
	// top-level system string (Anthropic has no system role inside messages).
	var systemParts []string
	if s := strings.TrimSpace(req.System); s != "" {
		systemParts = append(systemParts, req.System)
	}

	for _, m := range req.Messages {
		switch m.Role {
		case provider.RoleSystem:
			if strings.TrimSpace(m.Text) != "" {
				systemParts = append(systemParts, m.Text)
			}

		case provider.RoleUser:
			out.Messages = append(out.Messages, apiMessage{
				Role:    "user",
				Content: []apiBlock{{Type: "text", Text: m.Text}},
			})

		case provider.RoleAssistant:
			blocks := make([]apiBlock, 0, 1+len(m.ToolCalls))
			if strings.TrimSpace(m.Text) != "" {
				blocks = append(blocks, apiBlock{Type: "text", Text: m.Text})
			}
			for _, tc := range m.ToolCalls {
				blocks = append(blocks, apiBlock{
					Type:  "tool_use",
					ID:    tc.ID,
					Name:  tc.Name,
					Input: ensureJSONObject(tc.Args),
				})
			}
			// An assistant turn must carry at least one block.
			if len(blocks) == 0 {
				blocks = append(blocks, apiBlock{Type: "text", Text: ""})
			}
			out.Messages = append(out.Messages, apiMessage{
				Role:    "assistant",
				Content: blocks,
			})

		case provider.RoleTool:
			// A tool result is delivered to Anthropic as a *user* message
			// containing a tool_result block keyed by the originating
			// tool_use id (our ToolCallID).
			out.Messages = append(out.Messages, apiMessage{
				Role: "user",
				Content: []apiBlock{{
					Type:      "tool_result",
					ToolUseID: m.ToolCallID,
					Content:   []apiBlock{{Type: "text", Text: m.Text}},
				}},
			})

		default:
			// Unknown roles are skipped rather than panicking; defensive.
		}
	}

	if len(systemParts) > 0 {
		out.System = strings.Join(systemParts, "\n\n")
	}

	for _, t := range req.Tools {
		out.Tools = append(out.Tools, apiTool{
			Name:        t.Name,
			Description: t.Description,
			InputSchema: ensureJSONObject(t.Schema),
		})
	}

	return out
}

// MarshalRequest builds and JSON-encodes the Anthropic request body for the
// given provider.Request. It performs no network I/O and is the seam unit tests
// use to assert the translated wire shape.
func (c *Client) MarshalRequest(req provider.Request) ([]byte, error) {
	return json.Marshal(c.buildRequest(req))
}

// ensureJSONObject returns raw if it is non-empty valid JSON, otherwise an empty
// JSON object. Anthropic requires object-typed input_schema and tool input, so a
// nil/empty value must be sent as "{}" rather than null.
func ensureJSONObject(raw json.RawMessage) json.RawMessage {
	if len(bytes.TrimSpace(raw)) == 0 {
		return json.RawMessage(`{}`)
	}
	return raw
}

// ---- Streaming -------------------------------------------------------------

// Stream runs exactly one model turn. It POSTs the translated request with
// stream:true and parses the SSE response, emitting provider.Events on the
// returned channel until the channel closes. The terminal event is EventDone on
// success or EventError on failure. ctx cancellation aborts the request and
// stops emission promptly.
func (c *Client) Stream(ctx context.Context, req provider.Request) (<-chan provider.Event, error) {
	body, err := c.MarshalRequest(req)
	if err != nil {
		return nil, fmt.Errorf("anthropic: encode request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/v1/messages", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("anthropic: build http request: %w", err)
	}
	httpReq.Header.Set("content-type", "application/json")
	httpReq.Header.Set("accept", "text/event-stream")
	httpReq.Header.Set("x-api-key", c.apiKey)
	httpReq.Header.Set("anthropic-version", anthropicVersion)

	resp, err := c.http.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("anthropic: request failed: %w", err)
	}

	// Non-2xx: drain the (bounded) error body and surface it. Done before any
	// goroutine/channel is created so the caller gets the error synchronously.
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		defer resp.Body.Close()
		msg := readErrorBody(resp.Body)
		return nil, fmt.Errorf("anthropic: http %d: %s", resp.StatusCode, msg)
	}

	out := make(chan provider.Event)
	go func() {
		defer close(out)
		defer resp.Body.Close()
		parseSSE(ctx, resp.Body, out)
	}()
	return out, nil
}

// readErrorBody reads up to 64 KiB of an error response body and returns a
// trimmed single-line summary, preferring the Anthropic error.message field.
func readErrorBody(r io.Reader) string {
	raw, _ := io.ReadAll(io.LimitReader(r, 64<<10))
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 {
		return "(empty response body)"
	}
	var env struct {
		Error struct {
			Type    string `json:"type"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(raw, &env) == nil && env.Error.Message != "" {
		if env.Error.Type != "" {
			return env.Error.Type + ": " + env.Error.Message
		}
		return env.Error.Message
	}
	return string(raw)
}

// ---- SSE event payload types (Anthropic -> provider) -----------------------

// sseEvent is the discriminated union of the streamed JSON payloads we care
// about. Only the fields used by parseSSE are declared.
type sseEvent struct {
	Type string `json:"type"`

	// content_block_start
	Index        int `json:"index"`
	ContentBlock struct {
		Type string `json:"type"`
		ID   string `json:"id"`
		Name string `json:"name"`
	} `json:"content_block"`

	// content_block_delta
	Delta struct {
		Type string `json:"type"`

		// text_delta
		Text string `json:"text"`

		// input_json_delta
		PartialJSON string `json:"partial_json"`

		// message_delta
		StopReason string `json:"stop_reason"`
	} `json:"delta"`

	// message_start / message_delta usage
	Usage *struct {
		InputTokens  int `json:"input_tokens"`
		OutputTokens int `json:"output_tokens"`
	} `json:"usage"`

	// error
	Error *struct {
		Type    string `json:"type"`
		Message string `json:"message"`
	} `json:"error"`
}

// toolAccumulator buffers a tool_use block as its input JSON arrives in
// input_json_delta fragments, keyed by content block index.
type toolAccumulator struct {
	id   string
	name string
	args strings.Builder
}

// parseSSE consumes the Anthropic SSE body and emits normalized provider.Events
// on out. It returns when the stream ends, a terminal event is produced, or ctx
// is cancelled. It never panics on malformed input: unparseable data lines are
// skipped, and a hard read error becomes a terminal EventError.
func parseSSE(ctx context.Context, body io.Reader, out chan<- provider.Event) {
	send := func(ev provider.Event) bool {
		select {
		case <-ctx.Done():
			return false
		case out <- ev:
			return true
		}
	}

	scanner := bufio.NewScanner(body)
	scanner.Buffer(make([]byte, 0, 64<<10), maxResponseLine)

	// Active tool_use blocks, indexed by SSE content block index.
	tools := map[int]*toolAccumulator{}
	stopReason := ""
	var usage *provider.Usage
	doneEmitted := false

	for scanner.Scan() {
		// Bail out promptly if the consumer/context is gone.
		if ctx.Err() != nil {
			return
		}

		line := scanner.Text()
		// SSE framing: we only need the "data:" payload lines. "event:" lines
		// duplicate the JSON "type" field, so they are ignored. Blank lines are
		// record separators.
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		payload := strings.TrimSpace(line[len("data:"):])
		if payload == "" {
			continue
		}

		var ev sseEvent
		if err := json.Unmarshal([]byte(payload), &ev); err != nil {
			// Skip malformed frames rather than aborting the whole stream.
			continue
		}

		switch ev.Type {
		case "message_start":
			if ev.Usage != nil {
				usage = &provider.Usage{
					InputTokens:  ev.Usage.InputTokens,
					OutputTokens: ev.Usage.OutputTokens,
				}
			}

		case "content_block_start":
			if ev.ContentBlock.Type == "tool_use" {
				tools[ev.Index] = &toolAccumulator{
					id:   ev.ContentBlock.ID,
					name: ev.ContentBlock.Name,
				}
			}

		case "content_block_delta":
			switch ev.Delta.Type {
			case "text_delta":
				if ev.Delta.Text != "" {
					if !send(provider.Event{Kind: provider.EventText, TextDelta: ev.Delta.Text}) {
						return
					}
				}
			case "input_json_delta":
				if acc := tools[ev.Index]; acc != nil {
					acc.args.WriteString(ev.Delta.PartialJSON)
				}
			}

		case "content_block_stop":
			if acc := tools[ev.Index]; acc != nil {
				args := acc.args.String()
				if strings.TrimSpace(args) == "" {
					// A tool with no arguments streams no input_json_delta;
					// normalize to an empty JSON object.
					args = "{}"
				}
				tc := &provider.ToolCall{
					ID:   acc.id,
					Name: acc.name,
					Args: json.RawMessage(args),
				}
				delete(tools, ev.Index)
				if !send(provider.Event{Kind: provider.EventToolCall, ToolCall: tc}) {
					return
				}
			}

		case "message_delta":
			if ev.Delta.StopReason != "" {
				stopReason = ev.Delta.StopReason
			}
			if ev.Usage != nil {
				// message_delta carries the final output_tokens count.
				if usage == nil {
					usage = &provider.Usage{}
				}
				if ev.Usage.InputTokens != 0 {
					usage.InputTokens = ev.Usage.InputTokens
				}
				usage.OutputTokens = ev.Usage.OutputTokens
			}

		case "message_stop":
			if usage != nil {
				// Best-effort usage report just before the terminal event.
				if !send(provider.Event{Kind: provider.EventUsage, Usage: usage}) {
					return
				}
				usage = nil
			}
			_ = send(provider.Event{Kind: provider.EventDone, StopReason: stopReason})
			doneEmitted = true
			return

		case "error":
			msg := "anthropic: stream error"
			if ev.Error != nil && ev.Error.Message != "" {
				if ev.Error.Type != "" {
					msg = fmt.Sprintf("anthropic: %s: %s", ev.Error.Type, ev.Error.Message)
				} else {
					msg = "anthropic: " + ev.Error.Message
				}
			}
			_ = send(provider.Event{Kind: provider.EventError, Err: fmt.Errorf("%s", msg)})
			return

		case "ping":
			// Keep-alive heartbeat; nothing to do.

		default:
			// Unknown event types are ignored for forward compatibility.
		}
	}

	// The scanner stopped without a message_stop. Distinguish a read error from
	// a clean-but-truncated stream.
	if err := scanner.Err(); err != nil {
		if ctx.Err() != nil {
			return // cancellation, not a real error
		}
		_ = send(provider.Event{Kind: provider.EventError, Err: fmt.Errorf("anthropic: read stream: %w", err)})
		return
	}
	// Stream ended cleanly but the API never sent message_stop; synthesize a
	// terminal Done so consumers are not left hanging.
	if !doneEmitted {
		_ = send(provider.Event{Kind: provider.EventDone, StopReason: stopReason})
	}
}

// compile-time assertion that *Client satisfies the seam.
var _ provider.Provider = (*Client)(nil)
