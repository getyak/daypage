// Package policy is the safety-by-mediation gate. Every side-effecting tool
// call the agent loop wants to make first passes through Policy.Check, which
// returns one of three decisions: allow (run it), deny (refuse, surface an
// error to the model), or ask (raise an approval request to the active UI /
// transport). This mirrors openclaw's exec-approvals model.
//
// The gate is deliberately simple and fully in-process: a default decision, an
// ordered list of glob rules matched against the tool name, and an "approvals"
// store of remembered allow choices (the user clicking "always allow"). The
// store can be persisted best-effort to ~/.agentry/exec-approvals.json so a
// remembered choice survives restarts.
//
// All exported methods are safe for concurrent use.
package policy

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path"
	"path/filepath"
	"sort"
	"sync"
)

// Decision is the outcome of mediating a single tool call.
type Decision string

const (
	// Allow runs the tool without prompting.
	Allow Decision = "allow"
	// Deny refuses the tool; the loop should return a tool_result error.
	Deny Decision = "deny"
	// Ask defers to the active UI/transport for an interactive approval.
	Ask Decision = "ask"
)

// Rule maps a tool-name pattern to a decision. Tool is a glob in the syntax of
// path.Match (e.g. "fs.*", "browser.eval", "*"). The first matching rule in a
// Policy's ordered rule list wins.
type Rule struct {
	Tool     string   `json:"tool"`
	Decision Decision `json:"decision"`
}

// Policy is the mediation gate: an ordered rule list, a fallback decision for
// tools no rule matches, and a store of remembered allow approvals.
//
// The zero value is not ready for use; construct with Default or New.
type Policy struct {
	mu sync.RWMutex
	// rules are evaluated in order; first glob match wins.
	rules []Rule
	// def is returned when no rule matches.
	def Decision
	// approvals are remembered "always allow" keys (see approvalKey). A hit
	// here short-circuits Check to Allow regardless of the matched rule, which
	// is how an "ask" tool becomes silently allowed after the user consents.
	approvals map[string]bool
	// path is where approvals are persisted; empty disables persistence.
	path string
}

// New builds a policy from an ordered rule list and a default decision. The
// default decision is normalized to Ask if it is not one of the three known
// values, so an unconfigured/garbage default never silently allows.
func New(rules []Rule, def Decision) *Policy {
	if !def.valid() {
		def = Ask
	}
	cp := make([]Rule, len(rules))
	copy(cp, rules)
	return &Policy{
		rules:     cp,
		def:       def,
		approvals: map[string]bool{},
		path:      defaultApprovalsPath(),
	}
}

// Default returns the standard policy:
//
//   - Read-only tools (fs.read, fs.list, web.fetch, web.extract, web.search,
//     browser.read, browser.navigate, browser.screenshot) => allow.
//   - Mutating / dangerous tools (shell.exec, fs.write, browser.click,
//     browser.type, browser.eval) => ask.
//   - Anything else => allow, on the assumption that unknown tools are read-ish
//     by default. (Tighten this per-deployment with New if you prefer
//     deny-by-default.)
//
// Rules are ordered most-specific-first; because Check uses first-match, the
// explicit ask rules take precedence over any broader allow.
func Default() *Policy {
	p := New([]Rule{
		// Explicit read-only allows.
		{Tool: "fs.read", Decision: Allow},
		{Tool: "fs.list", Decision: Allow},
		{Tool: "web.fetch", Decision: Allow},
		{Tool: "web.extract", Decision: Allow},
		{Tool: "web.search", Decision: Allow},
		{Tool: "browser.read", Decision: Allow},
		{Tool: "browser.navigate", Decision: Allow},
		{Tool: "browser.screenshot", Decision: Allow},

		// Mutating / dangerous => ask for consent.
		{Tool: "shell.exec", Decision: Ask},
		{Tool: "fs.write", Decision: Ask},
		{Tool: "browser.click", Decision: Ask},
		{Tool: "browser.type", Decision: Ask},
		{Tool: "browser.eval", Decision: Ask},
	}, Allow)
	// Pull in any previously remembered approvals (best-effort).
	p.Load()
	return p
}

// Check mediates a single tool call and returns the decision.
//
// Order of evaluation:
//  1. A remembered approval for this tool (and coarse arg signature) => Allow.
//  2. The first rule whose glob matches the tool name => that rule's decision.
//  3. The policy's default decision.
//
// args may be nil; it is only consulted to build the approval key. A malformed
// glob in a rule is treated as a non-match (it never matches and never panics).
func (p *Policy) Check(toolName string, args json.RawMessage) Decision {
	p.mu.RLock()
	defer p.mu.RUnlock()

	// 1. Remembered approvals short-circuit to Allow. We check both the
	// arg-scoped key and the tool-wide key so that Remember(tool) (no args)
	// covers every future call to that tool.
	if p.approvals[approvalKey(toolName, args)] || p.approvals[approvalKey(toolName, nil)] {
		return Allow
	}

	// 2. First matching rule wins.
	for _, r := range p.rules {
		if globMatch(r.Tool, toolName) {
			return r.Decision
		}
	}

	// 3. Fall back to the default.
	return p.def
}

// Remember records an "always allow" approval for a tool. Subsequent Check
// calls for that tool return Allow regardless of the matched rule. The choice
// is persisted best-effort (errors are swallowed: a remembered approval is a
// convenience, never a correctness requirement).
//
// The approval is recorded tool-wide (not scoped to specific args), matching
// the coarse "remember this tool" UX. To scope to a particular argument shape,
// use RememberArgs.
func (p *Policy) Remember(toolName string) {
	p.remember(approvalKey(toolName, nil))
}

// RememberArgs records an approval scoped to a coarse signature of args, so a
// remembered choice for `shell.exec {"cmd":"ls"}` does not silently allow
// `shell.exec {"cmd":"rm -rf /"}`. The signature is a hash of the raw args, so
// only byte-identical args match; this is intentionally conservative.
func (p *Policy) RememberArgs(toolName string, args json.RawMessage) {
	p.remember(approvalKey(toolName, args))
}

// IsRemembered reports whether an approval key for the tool (tool-wide or for
// the given args) has been remembered. Exposed mainly for tests and UIs.
func (p *Policy) IsRemembered(toolName string, args json.RawMessage) bool {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.approvals[approvalKey(toolName, nil)] || p.approvals[approvalKey(toolName, args)]
}

// Forget removes any remembered approvals for a tool (both tool-wide and the
// given args). It persists the change best-effort. Returns true if anything
// was removed.
func (p *Policy) Forget(toolName string, args json.RawMessage) bool {
	p.mu.Lock()
	removed := false
	for _, k := range []string{approvalKey(toolName, nil), approvalKey(toolName, args)} {
		if p.approvals[k] {
			delete(p.approvals, k)
			removed = true
		}
	}
	p.mu.Unlock()
	if removed {
		_ = p.Save()
	}
	return removed
}

// Rules returns a copy of the policy's rule list (safe to inspect/mutate by the
// caller without affecting the policy).
func (p *Policy) Rules() []Rule {
	p.mu.RLock()
	defer p.mu.RUnlock()
	out := make([]Rule, len(p.rules))
	copy(out, p.rules)
	return out
}

// SetPath overrides where approvals persist. Empty disables persistence. This
// is primarily for tests that want an isolated temp file.
func (p *Policy) SetPath(path string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.path = path
}

// remember inserts a key and persists best-effort.
func (p *Policy) remember(key string) {
	p.mu.Lock()
	if p.approvals == nil {
		p.approvals = map[string]bool{}
	}
	already := p.approvals[key]
	p.approvals[key] = true
	p.mu.Unlock()
	if !already {
		_ = p.Save() // best-effort; persistence failure is non-fatal.
	}
}

// approvalsFile is the on-disk shape of the approvals store. We persist the set
// of remembered keys; the policy rules themselves are code, not config, so they
// are not round-tripped here.
type approvalsFile struct {
	// Keys is the sorted list of remembered approval keys.
	Keys []string `json:"keys"`
}

// Save writes the remembered approvals to p.path (best-effort). It returns an
// error for callers that care, but Remember ignores it by design. Writes are
// atomic (temp file + rename) so a crash never leaves a half-written file.
func (p *Policy) Save() error {
	p.mu.RLock()
	path := p.path
	keys := make([]string, 0, len(p.approvals))
	for k := range p.approvals {
		keys = append(keys, k)
	}
	p.mu.RUnlock()

	if path == "" {
		return nil // persistence disabled
	}
	sort.Strings(keys) // stable on-disk ordering

	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(approvalsFile{Keys: keys}, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".exec-approvals-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	// Clean up the temp file on any error path below.
	defer func() { _ = os.Remove(tmpName) }()

	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

// Load merges remembered approvals from p.path into the in-memory set
// (best-effort). A missing file is not an error. Existing in-memory approvals
// are preserved (the union is taken), so Load never drops a just-remembered
// choice.
func (p *Policy) Load() error {
	p.mu.RLock()
	path := p.path
	p.mu.RUnlock()
	if path == "" {
		return nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil // first run: nothing to load
		}
		return err
	}
	var af approvalsFile
	if err := json.Unmarshal(data, &af); err != nil {
		// A corrupt approvals file should not wedge startup; ignore its content
		// and keep going with whatever is in memory.
		return err
	}
	p.mu.Lock()
	if p.approvals == nil {
		p.approvals = map[string]bool{}
	}
	for _, k := range af.Keys {
		p.approvals[k] = true
	}
	p.mu.Unlock()
	return nil
}

// valid reports whether d is one of the three known decisions.
func (d Decision) valid() bool {
	switch d {
	case Allow, Deny, Ask:
		return true
	default:
		return false
	}
}

// globMatch reports whether name matches the glob pattern using path.Match
// semantics. A malformed pattern yields false (never an error/panic), so a bad
// rule simply never matches rather than crashing the gate.
func globMatch(pattern, name string) bool {
	ok, err := path.Match(pattern, name)
	return err == nil && ok
}

// approvalKey derives the map key for a remembered approval. With nil/empty
// args it is the bare tool name (a tool-wide approval). With args it appends a
// short stable hash of the raw arg bytes, giving a coarse per-argument scope
// without storing or leaking the arguments themselves.
func approvalKey(toolName string, args json.RawMessage) string {
	if len(args) == 0 {
		return toolName
	}
	sum := sha256.Sum256(args)
	return toolName + "#" + hex.EncodeToString(sum[:8]) // 16 hex chars is plenty
}

// defaultApprovalsPath returns ~/.agentry/exec-approvals.json, or "" if the
// home directory cannot be determined (which disables persistence).
func defaultApprovalsPath() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, ".agentry", "exec-approvals.json")
}
