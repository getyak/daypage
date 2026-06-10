// Package orchestrator implements agentry's scheduling primitives: it lets one
// agent run another (agent-as-tool) and lets a caller drive many prompts through
// an engine concurrently (fan-out). These are the building blocks for the
// multi-agent control flow described in DESIGN §9.
//
// The central idea is that a *sub-agent is just a Tool*. AsTool wraps a named
// AgentProfile (its own system prompt, model, and tool allow-list) as a
// tool.Tool called "agent.<name>". When the model invokes that tool, the
// orchestrator spins up a NESTED agent.Engine — built by a caller-supplied
// factory — runs it on a fresh session, and returns the sub-agent's final text
// as the tool result. This is precisely how an agent *schedules* another agent,
// using the exact same Tool seam every other capability uses.
//
// The engine factory is injected rather than constructed here for two reasons:
//
//  1. It breaks the import cycle that would otherwise arise (agent already
//     depends on tool/session/provider/policy; if orchestrator built engines and
//     agent imported orchestrator we would loop). orchestrator depends on agent,
//     never the reverse.
//  2. It keeps this package provider- and tool-agnostic. The caller decides how
//     each profile maps to a provider, a tool registry (filtered by AllowTools),
//     a policy, and a model — wiring the orchestrator cannot and should not know.
//
// Every entry point is bounded and panic-free: malformed tool arguments become
// ordinary error results, a nil factory or nil engine is reported rather than
// dereferenced, and runs honor context cancellation.
package orchestrator

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"runtime"
	"strings"
	"sync"

	"github.com/kubbot/agentry/internal/core/agent"
	"github.com/kubbot/agentry/internal/core/session"
	"github.com/kubbot/agentry/internal/core/tool"
)

// maxInputBytes caps the size of a sub-agent prompt accepted via the tool
// interface. A model (or a remote caller) cannot make us buffer an unbounded
// string before we even start the nested run. 256 KiB is generous for a prompt
// while still bounding memory.
const maxInputBytes = 256 << 10

// AgentProfile names a sub-agent: a distinct persona with its own system prompt,
// model, and the subset of tools it is permitted to use. It is pure data — how a
// profile becomes a runnable engine is the job of the factory passed to AsTool —
// so a profile can be declared in config, serialized, and reused across runs.
type AgentProfile struct {
	// Name is the profile's identifier. The tool produced by AsTool is named
	// "agent.<Name>", so it must be a usable tool-name segment.
	Name string `json:"name"`
	// System is the sub-agent's system prompt. The factory is expected to apply
	// it to the engine it builds; AsTool does not second-guess the factory.
	System string `json:"system,omitempty"`
	// Model overrides the model id the sub-agent runs against (empty = factory /
	// session default).
	Model string `json:"model,omitempty"`
	// AllowTools is the allow-list of tool names this sub-agent may use. It is
	// advisory metadata that the factory consults when assembling the nested
	// engine's registry; the orchestrator itself does not enforce it (the engine
	// and its policy do). nil/empty means "the factory decides".
	AllowTools []string `json:"allow_tools,omitempty"`
}

// EngineFactory builds a fresh agent.Engine for a given profile. It is called
// once per sub-agent invocation so each call gets an isolated engine (and the
// caller may, if it wishes, return a shared engine — that is the caller's
// choice). Returning nil signals the profile could not be realized; AsTool turns
// that into an error tool result rather than panicking.
type EngineFactory func(profile AgentProfile) *agent.Engine

// agentInput is the argument schema for an agent-as-tool invocation: a single
// free-text prompt handed to the sub-agent.
type agentInput struct {
	Input string `json:"input"`
}

// agentToolSchema is the JSON Schema advertised for every agent.<name> tool. It
// is a fixed single-string-field object, so we declare it once as a constant
// rather than re-marshaling per tool.
const agentToolSchema = `{
  "type": "object",
  "properties": {
    "input": {
      "type": "string",
      "description": "The task or question to delegate to this sub-agent."
    }
  },
  "required": ["input"],
  "additionalProperties": false
}`

// agentTool adapts an AgentProfile to the tool.Tool seam. Invoking it runs the
// profile as a nested engine and returns the sub-agent's final text.
type agentTool struct {
	profile    AgentProfile
	makeEngine EngineFactory
	name       string // cached "agent.<profile.Name>"
}

// AsTool exposes an AgentProfile as a tool.Tool named "agent.<profile.Name>".
//
// When the returned tool is invoked with {"input": "<prompt>"}, it:
//
//  1. validates and bounds the input;
//  2. calls makeEngine(profile) to obtain a NESTED *agent.Engine (the factory is
//     responsible for wiring the provider, the tool registry filtered to
//     profile.AllowTools, the policy, the system prompt, and the model);
//  3. runs that engine on a FRESH, isolated session.Session (so the sub-agent
//     does not see or mutate the parent conversation); and
//  4. returns the sub-agent's final assistant text as the tool Result.
//
// This is the agent-as-tool primitive: it is how one agent SCHEDULES another.
// All failure modes (bad args, nil factory, nil engine, sub-agent error) are
// returned as tool Results — never panics — so the parent loop can observe and
// react to them like any other tool outcome.
func AsTool(profile AgentProfile, makeEngine EngineFactory) tool.Tool {
	return &agentTool{
		profile:    profile,
		makeEngine: makeEngine,
		name:       toolName(profile.Name),
	}
}

// toolName builds the "agent.<name>" tool identifier, trimming surrounding
// whitespace and falling back to a placeholder if the profile name is empty so
// the registry never sees a bare "agent." key.
func toolName(profileName string) string {
	n := strings.TrimSpace(profileName)
	if n == "" {
		n = "unnamed"
	}
	return "agent." + n
}

// Name reports the tool's registry key, "agent.<profile.Name>".
func (a *agentTool) Name() string { return a.name }

// Description is a human/model-facing summary, incorporating the profile's
// system prompt (truncated) when one is set so the calling model has a hint of
// what the sub-agent specializes in.
func (a *agentTool) Description() string {
	base := fmt.Sprintf("Delegate a task to the %q sub-agent and return its final answer.", a.profile.Name)
	if hint := strings.TrimSpace(a.profile.System); hint != "" {
		base += " Specialty: " + truncate(hint, 160)
	}
	return base
}

// Schema returns the fixed argument schema (a single required "input" string).
func (a *agentTool) Schema() json.RawMessage { return json.RawMessage(agentToolSchema) }

// Invoke runs the sub-agent. It parses the input, builds a nested engine via the
// injected factory, runs it on a fresh session, and returns the final text.
//
// It never panics and returns a Go error only for a context cancellation that
// the engine surfaces; every other problem (missing factory/engine, empty input,
// malformed JSON, a sub-agent run error) is reported as an error Result so the
// parent loop treats it as observable data rather than a transport failure.
func (a *agentTool) Invoke(ctx context.Context, in tool.Input) (tool.Result, error) {
	if a.makeEngine == nil {
		return tool.Result{
			Content: fmt.Sprintf("sub-agent %q has no engine factory configured", a.profile.Name),
			IsError: true,
		}, nil
	}

	// Bound the argument size before unmarshaling so a hostile payload cannot
	// force a large allocation. len on a []byte is the raw JSON size.
	if len(in.Args) > maxInputBytes {
		return tool.Result{
			Content: fmt.Sprintf("sub-agent %q input too large (%d bytes, max %d)", a.profile.Name, len(in.Args), maxInputBytes),
			IsError: true,
		}, nil
	}

	prompt, err := parseAgentInput(in.Args)
	if err != nil {
		return tool.Result{
			Content: fmt.Sprintf("sub-agent %q: %v", a.profile.Name, err),
			IsError: true,
		}, nil
	}

	// Build the nested engine. A factory that cannot realize the profile returns
	// nil; we report that rather than dereferencing it.
	eng := a.makeEngine(a.profile)
	if eng == nil {
		return tool.Result{
			Content: fmt.Sprintf("sub-agent %q: engine factory returned nil", a.profile.Name),
			IsError: true,
		}, nil
	}

	// Run on a FRESH session so the sub-agent's history is isolated from the
	// parent conversation. The session id namespaces it under the parent for
	// observability when one is available.
	sub := session.New(subSessionID(in.Session, a.profile.Name))
	if a.profile.Model != "" {
		sub.Model = a.profile.Model
	}

	final, runErr := eng.Run(ctx, sub, prompt)
	if runErr != nil {
		// A canceled context is a real transport-level failure the parent should
		// propagate (it usually means the whole run is being torn down); surface
		// it as a Go error. Any other run error is sub-agent data: report it as an
		// error Result so the parent model can decide how to proceed, and still
		// hand back whatever partial text was produced.
		if errors.Is(runErr, context.Canceled) || errors.Is(runErr, context.DeadlineExceeded) {
			return tool.Result{Content: final, IsError: true}, runErr
		}
		return tool.Result{
			Content: fmt.Sprintf("sub-agent %q failed: %v", a.profile.Name, runErr),
			IsError: true,
			Meta:    map[string]any{"agent": a.profile.Name, "partial": final},
		}, nil
	}

	return tool.Result{
		Content: final,
		Meta:    map[string]any{"agent": a.profile.Name, "session": sub.ID},
	}, nil
}

// parseAgentInput extracts and validates the "input" field from the raw tool
// arguments. Empty/absent args or a blank input are rejected with a descriptive
// error so the model learns it must supply a prompt.
func parseAgentInput(args json.RawMessage) (string, error) {
	if len(args) == 0 {
		return "", errors.New(`missing arguments; expected {"input": "..."}`)
	}
	var ai agentInput
	if err := json.Unmarshal(args, &ai); err != nil {
		return "", fmt.Errorf("invalid arguments: %w", err)
	}
	prompt := strings.TrimSpace(ai.Input)
	if prompt == "" {
		return "", errors.New(`"input" must be a non-empty string`)
	}
	return prompt, nil
}

// subSessionID derives a readable, namespaced id for the sub-agent's session.
// When the ambient context is a *session.Session we prefix with the parent id so
// nested runs are attributable; otherwise we fall back to just the profile name.
func subSessionID(ambient any, profileName string) string {
	name := strings.TrimSpace(profileName)
	if name == "" {
		name = "unnamed"
	}
	if parent, ok := ambient.(*session.Session); ok && parent != nil && parent.ID != "" {
		return parent.ID + "/agent:" + name
	}
	return "agent:" + name
}

// FanOut runs the same engine over many prompts concurrently and returns the
// results positionally aligned with inputs (results[i] is the outcome of
// inputs[i]). Each prompt runs on its own fresh session so the concurrent runs
// never share or race on conversation state.
//
// Concurrency is BOUNDED: at most a small multiple of GOMAXPROCS runs proceed at
// once, so fanning out hundreds of prompts cannot spawn hundreds of simultaneous
// provider calls. Ordering of the returned slice is deterministic regardless of
// completion order.
//
// Failures are encoded into the result string for that index (prefixed with
// "error:") rather than aborting the whole batch, so one bad prompt does not
// sink the others. If ctx is canceled, in-flight and not-yet-started runs short-
// circuit and report the cancellation in their slots.
//
// A nil engine yields a same-length slice of error strings rather than panicking.
func FanOut(ctx context.Context, eng *agent.Engine, inputs []string) []string {
	results := make([]string, len(inputs))
	if len(inputs) == 0 {
		return results
	}
	if eng == nil {
		for i := range results {
			results[i] = "error: FanOut called with nil engine"
		}
		return results
	}

	// Bound concurrency. We never launch more workers than there are inputs, and
	// never more than the limit, so memory and provider pressure stay capped.
	limit := fanOutLimit()
	if limit > len(inputs) {
		limit = len(inputs)
	}

	sem := make(chan struct{}, limit)
	var wg sync.WaitGroup

	for i, input := range inputs {
		// Respect cancellation between launches so a canceled batch stops
		// scheduling new work promptly.
		if err := ctx.Err(); err != nil {
			results[i] = "error: " + err.Error()
			continue
		}

		wg.Add(1)
		sem <- struct{}{} // acquire a slot (blocks once `limit` are in flight)
		go func(idx int, prompt string) {
			defer wg.Done()
			defer func() { <-sem }() // release the slot

			// Each prompt gets an isolated session so concurrent runs never
			// touch the same Session (which, while mutex-guarded, must not be
			// driven by two Run loops at once).
			sess := session.New(fmt.Sprintf("fanout-%d", idx))
			out, err := eng.Run(ctx, sess, prompt)
			if err != nil {
				// Preserve any partial text alongside the error marker so a caller
				// can still inspect what the run produced before failing.
				if out != "" {
					results[idx] = "error: " + err.Error() + ": " + out
				} else {
					results[idx] = "error: " + err.Error()
				}
				return
			}
			results[idx] = out
		}(i, input)
	}

	wg.Wait()
	return results
}

// fanOutLimit chooses the maximum number of concurrent sub-runs. We scale with
// available parallelism but keep a sane floor and ceiling: model turns are
// I/O-bound (provider round-trips), so a modest multiple of GOMAXPROCS keeps the
// pipeline busy without unleashing an unbounded number of provider calls.
func fanOutLimit() int {
	n := runtime.GOMAXPROCS(0) * 2
	if n < 2 {
		n = 2
	}
	if n > 16 {
		n = 16
	}
	return n
}

// truncate shortens s to at most max runes, appending an ellipsis when it had to
// cut. It is rune-aware so it never splits a multibyte character.
func truncate(s string, max int) string {
	r := []rune(s)
	if len(r) <= max {
		return s
	}
	if max <= 1 {
		return string(r[:max])
	}
	return string(r[:max-1]) + "…"
}
