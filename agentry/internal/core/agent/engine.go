// Package agent implements the reason→act→observe loop — the heart of agentry.
//
// An Engine wires together the four seams (Provider, Tool registry, Policy, and
// Session) and drives one user prompt to completion. Each iteration of the loop:
//
//  1. builds a provider.Request from the session's reconstructed history plus the
//     system prompt and the advertised tool specs;
//  2. streams one model turn, accumulating assistant text and collecting any
//     tool-call requests the model emits;
//  3. mediates every requested tool call through the Policy gate
//     (allow / deny / ask) and invokes the allowed ones via the registry;
//  4. records assistant text and tool results back onto the session so live
//     subscribers (TUI / Web UI / stdio transport) see the run unfold; and
//  5. loops again if any tool ran this turn (so the model can observe results),
//     otherwise returns the accumulated final assistant text.
//
// The loop is headless-first: it has no UI dependency. Interactive approval is
// injected via the Approve hook; transports/UIs supply their own. A MaxSteps cap
// and ctx cancellation bound every run so a misbehaving model can never spin
// forever.
package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/kubbot/agentry/internal/core/policy"
	"github.com/kubbot/agentry/internal/core/provider"
	"github.com/kubbot/agentry/internal/core/session"
	"github.com/kubbot/agentry/internal/core/tool"
)

// defaultMaxSteps bounds the reason→act→observe loop so a model that keeps
// requesting tools (or a buggy tool that always errors) cannot spin forever.
// Each "step" is one model turn; a step that runs tools costs another turn.
const defaultMaxSteps = 12

// ApprovalFunc decides an interactive "ask" tool call. It is invoked only when
// the Policy returns Ask for a given (tool, args); returning true allows the
// call, false denies it. It must not block indefinitely — the caller (a UI or
// transport) is responsible for any timeout. nil means "no approver wired",
// which the Engine treats as allow (headless default), since a headless run has
// no one to ask.
type ApprovalFunc func(toolName string, args json.RawMessage) bool

// DefaultSystemPrompt is used when Engine.System is empty. It is intentionally
// minimal; richer prompts are supplied by callers/agent profiles.
const DefaultSystemPrompt = "You are agentry, a capable autonomous agent. " +
	"Use the available tools when they help you complete the user's request, " +
	"and stop once the task is done."

// Engine drives a single conversation's reason→act→observe loop against a
// Provider, a Tool registry, and a Policy gate. It is safe to reuse across
// sessions (it holds no per-run mutable state); concurrency within a single Run
// is a single goroutine, matching DESIGN §5.
type Engine struct {
	// Provider is the LLM backend that produces model turns.
	Provider provider.Provider
	// Tools is the set of capabilities advertised to the model and invoked on
	// its behalf. Must be non-nil for tool use; a nil registry simply means no
	// tools are offered.
	Tools *tool.Registry
	// Policy mediates every tool call (allow / deny / ask). If nil, a default
	// permissive policy is synthesized lazily so the Engine is usable bare.
	Policy *policy.Policy
	// Model overrides the model id placed on each request. Empty falls back to
	// the session's Model.
	Model string
	// System is the system prompt sent on every turn. Empty uses
	// DefaultSystemPrompt.
	System string
	// MaxSteps caps the number of model turns per Run. <= 0 uses defaultMaxSteps.
	MaxSteps int
	// Temperature, if set, is forwarded to the provider; nil uses the provider
	// default.
	Temperature *float64
	// MaxTokens, if > 0, caps the provider's output tokens per turn.
	MaxTokens int
	// Approve resolves Policy "ask" decisions. nil => allow (headless default).
	Approve ApprovalFunc
}

// New constructs an Engine with the common fields. Optional behavior (System,
// MaxSteps, Approve, Temperature, MaxTokens) can be set on the returned struct.
// A nil policy is replaced with policy.Default so the result is always usable.
func New(p provider.Provider, tools *tool.Registry, pol *policy.Policy, model string) *Engine {
	if pol == nil {
		pol = policy.Default()
	}
	return &Engine{
		Provider: p,
		Tools:    tools,
		Policy:   pol,
		Model:    model,
		MaxSteps: defaultMaxSteps,
	}
}

// Run drives one user prompt to completion against sess and returns the final
// assistant text.
//
// It appends the user input, then loops: stream a model turn, mediate+invoke any
// requested tools, and repeat while tools keep running, up to MaxSteps. All
// assistant text and tool activity is appended to sess as it happens so live
// subscribers observe the run. The returned string is the assistant text from
// the final (tool-free) turn; if the loop hits MaxSteps mid-tool-use, it returns
// the most recent assistant text together with an error.
func (e *Engine) Run(ctx context.Context, sess *session.Session, userInput string) (string, error) {
	if e.Provider == nil {
		return "", errors.New("agent: Engine.Provider is nil")
	}
	if sess == nil {
		return "", errors.New("agent: session is nil")
	}

	// 1. Record the user's prompt. History() will surface it to the provider.
	sess.Append(session.Event{Type: session.EvUser, Text: userInput})

	maxSteps := e.MaxSteps
	if maxSteps <= 0 {
		maxSteps = defaultMaxSteps
	}

	// specs are stable across turns; compute once.
	specs := e.toolSpecs()

	var lastText string
	for step := 0; step < maxSteps; step++ {
		// Honor cancellation at the top of every turn.
		if err := ctx.Err(); err != nil {
			return lastText, err
		}

		// 2. Build the request from current history + system + tool specs.
		req := provider.Request{
			Model:       e.modelFor(sess),
			System:      e.systemPrompt(),
			Messages:    sess.History(),
			Tools:       specs,
			Temperature: e.Temperature,
			MaxTokens:   e.MaxTokens,
		}

		// 3. Stream one model turn, accumulating text + collecting tool calls.
		turn, err := e.streamTurn(ctx, sess, req)
		if err != nil {
			return lastText, err
		}
		if turn.text != "" {
			lastText = turn.text
		}

		// 4. If the model requested no tools, this turn produced the final
		// answer — we're done.
		if len(turn.calls) == 0 {
			return lastText, nil
		}

		// Otherwise mediate + invoke each requested tool, recording results onto
		// the session so the next turn's History() includes them.
		if err := e.runToolCalls(ctx, sess, turn.calls); err != nil {
			// Only ctx cancellation aborts the run; tool-level failures are fed
			// back to the model as error tool_results and the loop continues.
			return lastText, err
		}

		// 5. A tool ran this turn → loop so the model can observe the results.
	}

	// 6. Exhausted the step budget while still calling tools.
	return lastText, fmt.Errorf("agent: reached MaxSteps (%d) without a final answer", maxSteps)
}

// turnResult captures the outcome of consuming one provider stream: the
// accumulated assistant text and any tool calls the model requested.
type turnResult struct {
	text  string
	calls []provider.ToolCall
}

// streamTurn runs one provider turn: it opens the stream, drains its events,
// accumulates text deltas, collects tool-call requests, and records usage as a
// meta event. The assistant text (if any) is appended to the session as a single
// EvAssistant event once the turn ends, so subscribers and History() see a
// coherent message rather than per-delta fragments.
//
// It returns an error only for stream-level failures (an EventError, or the
// provider failing to start). A turn that simply ends with tool calls or text is
// a success.
func (e *Engine) streamTurn(ctx context.Context, sess *session.Session, req provider.Request) (turnResult, error) {
	ch, err := e.Provider.Stream(ctx, req)
	if err != nil {
		return turnResult{}, fmt.Errorf("agent: provider stream: %w", err)
	}

	var (
		text  strings.Builder
		calls []provider.ToolCall
	)

	for ev := range ch {
		switch ev.Kind {
		case provider.EventText:
			text.WriteString(ev.TextDelta)

		case provider.EventToolCall:
			if ev.ToolCall != nil {
				// Copy so we never alias provider-owned memory across turns.
				tc := *ev.ToolCall
				tc.Args = append(json.RawMessage(nil), ev.ToolCall.Args...)
				calls = append(calls, tc)
			}

		case provider.EventUsage:
			if ev.Usage != nil {
				sess.Append(session.Event{
					Type: session.EvMeta,
					Meta: map[string]any{
						"input_tokens":  ev.Usage.InputTokens,
						"output_tokens": ev.Usage.OutputTokens,
					},
				})
			}

		case provider.EventError:
			// A provider-reported error ends the turn. Surface assistant text
			// gathered so far onto the session for observability, then fail the
			// run: an error mid-stream is not something the loop can recover from
			// (unlike a tool error, which is data the model can react to).
			e.appendAssistant(sess, text.String())
			if ev.Err != nil {
				return turnResult{text: text.String()}, fmt.Errorf("agent: provider error: %w", ev.Err)
			}
			return turnResult{text: text.String()}, errors.New("agent: provider error")

		case provider.EventDone:
			// Terminal marker; nothing more to consume. The channel will close
			// next. We keep ranging so the producer goroutine can finish cleanly.
		}
	}

	// Channel closed: the turn is complete. Record the assistant text (if any)
	// as one coalesced message. Tool calls are recorded separately, per call,
	// in runToolCalls (paired with their results), matching session.History()'s
	// reconstruction model.
	final := text.String()
	e.appendAssistant(sess, final)
	return turnResult{text: final, calls: calls}, nil
}

// runToolCalls mediates and executes every tool call requested in a turn,
// appending a tool_call event and a tool_result event for each so the next
// model turn observes the outcome.
//
// Policy mediation per call:
//   - Deny  → a tool_result error "denied by policy" (the model sees the refusal).
//   - Ask   → consult e.Approve; nil approver allows (headless). A denial becomes
//     a tool_result error "denied by approver".
//   - Allow → look up the tool and Invoke it; the Result (or invocation error) is
//     recorded as the tool_result.
//
// It returns an error only on ctx cancellation; every other failure mode is
// converted into an error tool_result so the model can react, keeping the loop
// resilient.
func (e *Engine) runToolCalls(ctx context.Context, sess *session.Session, calls []provider.ToolCall) error {
	for _, call := range calls {
		if err := ctx.Err(); err != nil {
			return err
		}

		// Record the model's intent to call the tool (for UIs / audit). This is
		// distinct from the result and is not folded into History() as an
		// assistant message — History reconstructs tool results, not requests.
		sess.Append(session.Event{
			Type:   session.EvToolCall,
			Tool:   call.Name,
			CallID: call.ID,
			Args:   rawArgs(call.Args),
		})

		content, isErr, meta := e.dispatch(ctx, sess, call)

		sess.Append(session.Event{
			Type:    session.EvToolResult,
			Tool:    call.Name,
			CallID:  call.ID,
			Text:    content,
			IsError: isErr,
			Meta:    meta,
		})
	}
	return nil
}

// dispatch mediates a single tool call through the policy and, if allowed,
// invokes it. It returns the result content, whether it is an error result, and
// any tool-supplied Meta. It never panics and never returns a Go error: every
// outcome is expressed as tool_result data the model can observe.
func (e *Engine) dispatch(ctx context.Context, sess *session.Session, call provider.ToolCall) (content string, isErr bool, meta map[string]any) {
	args := rawArgsJSON(call.Args)

	// Gate the call.
	switch e.policy().Check(call.Name, args) {
	case policy.Deny:
		return fmt.Sprintf("tool %q denied by policy", call.Name), true, nil

	case policy.Ask:
		// No approver wired => headless allow. Otherwise honor the verdict.
		if e.Approve != nil && !e.Approve(call.Name, args) {
			return fmt.Sprintf("tool %q denied by approver", call.Name), true, nil
		}
		// fall through to invocation
	case policy.Allow:
		// fall through to invocation
	default:
		// An unknown decision is treated conservatively as a denial rather than
		// silently running a side effect.
		return fmt.Sprintf("tool %q blocked: unknown policy decision", call.Name), true, nil
	}

	// Resolve the tool.
	if e.Tools == nil {
		return fmt.Sprintf("tool %q is not available (no registry)", call.Name), true, nil
	}
	t, ok := e.Tools.Get(call.Name)
	if !ok {
		return fmt.Sprintf("tool %q not found", call.Name), true, nil
	}

	// Validate the model-supplied arguments against the tool's advertised schema
	// BEFORE invoking, so a malformed call (missing required field, wrong type,
	// out-of-range value, disallowed extra property, …) becomes a clear,
	// field-anchored error the model can read and self-correct from — uniformly
	// for every tool — instead of relying on each tool's ad-hoc checks or letting
	// advertised constraints (minimum/maximum/enum) be silently ignored. The
	// validator is permissive: schema features it does not model never cause a
	// rejection, so third-party (MCP-proxied) tools are unaffected.
	if problems := tool.ValidateArgs(t.Schema(), args); len(problems) > 0 {
		return tool.FormatValidationProblems(call.Name, problems), true, nil
	}

	// Invoke it. A returned Go error becomes an error tool_result; a Result with
	// IsError is passed through as-is.
	res, err := t.Invoke(ctx, tool.Input{Args: args, Session: sess})
	if err != nil {
		return fmt.Sprintf("tool %q failed: %v", call.Name, err), true, nil
	}
	return res.Content, res.IsError, res.Meta
}

// appendAssistant records assistant text as a single EvAssistant event, skipping
// empty turns (a tool-only turn produces no assistant message).
func (e *Engine) appendAssistant(sess *session.Session, text string) {
	if text == "" {
		return
	}
	sess.Append(session.Event{Type: session.EvAssistant, Text: text})
}

// toolSpecs converts the registry's tools into provider.ToolSpec advertisements.
// A nil registry yields no specs.
func (e *Engine) toolSpecs() []provider.ToolSpec {
	if e.Tools == nil {
		return nil
	}
	return ToolSpecs(e.Tools)
}

// modelFor resolves the model id for a request: the Engine's Model override if
// set, else the session's Model.
func (e *Engine) modelFor(sess *session.Session) string {
	if e.Model != "" {
		return e.Model
	}
	return sess.Model
}

// systemPrompt returns the configured system prompt or the default.
func (e *Engine) systemPrompt() string {
	if e.System != "" {
		return e.System
	}
	return DefaultSystemPrompt
}

// policy returns the configured policy, lazily defaulting to a permissive one so
// an Engine constructed as a bare struct literal still mediates safely.
func (e *Engine) policy() *policy.Policy {
	if e.Policy == nil {
		e.Policy = policy.Default()
	}
	return e.Policy
}

// ToolSpecs maps every tool in a registry to a provider.ToolSpec, preserving the
// registry's stable (name-sorted) ordering. Exposed as a package helper so
// transports and the orchestrator can advertise the same tool surface the Engine
// uses without duplicating the conversion.
func ToolSpecs(reg *tool.Registry) []provider.ToolSpec {
	if reg == nil {
		return nil
	}
	tools := reg.List()
	specs := make([]provider.ToolSpec, 0, len(tools))
	for _, t := range tools {
		specs = append(specs, ToolSpec(t))
	}
	return specs
}

// ToolSpec converts a single Tool into its provider advertisement.
func ToolSpec(t tool.Tool) provider.ToolSpec {
	return provider.ToolSpec{
		Name:        t.Name(),
		Description: t.Description(),
		Schema:      t.Schema(),
	}
}

// rawArgs returns the call args as something JSON-friendly to store on a session
// event (which marshals Args via encoding/json). We store the raw message so the
// on-disk JSONL faithfully echoes what the model sent; an empty payload becomes
// nil so it is omitted rather than written as the literal "null".
func rawArgs(args json.RawMessage) any {
	if len(args) == 0 {
		return nil
	}
	return args
}

// rawArgsJSON normalizes possibly-nil/empty args into a value safe to hand to a
// tool's Invoke. Tools expect valid JSON (or empty) for their Args; we never
// fabricate fields, we just avoid passing a stray empty slice that some decoders
// treat differently from nil.
func rawArgsJSON(args json.RawMessage) json.RawMessage {
	if len(args) == 0 {
		return nil
	}
	return args
}
