package policy

import (
	"encoding/json"
	"path/filepath"
	"sync"
	"testing"
)

// newIsolated returns a Default policy whose approvals persist to a temp file,
// so tests never read or clobber the real ~/.agentry/exec-approvals.json.
func newIsolated(t *testing.T) *Policy {
	t.Helper()
	p := Default()
	p.SetPath(filepath.Join(t.TempDir(), "exec-approvals.json"))
	return p
}

// TestDefaultDecisions covers the three outcomes (allow/deny/ask) produced by
// the Default policy across read-only tools, mutating tools, and unknowns.
func TestDefaultDecisions(t *testing.T) {
	p := newIsolated(t)

	tests := []struct {
		tool string
		want Decision
	}{
		// Read-only => allow.
		{"fs.read", Allow},
		{"fs.list", Allow},
		{"web.fetch", Allow},
		{"web.extract", Allow},
		{"web.search", Allow},
		{"browser.read", Allow},
		{"browser.navigate", Allow},
		{"browser.screenshot", Allow},
		// Mutating / dangerous => ask.
		{"shell.exec", Ask},
		{"fs.write", Ask},
		{"browser.click", Ask},
		{"browser.type", Ask},
		{"browser.eval", Ask},
		// Unknown read-ish tool falls through to the default (allow).
		{"some.unknown", Allow},
		{"agent.researcher", Allow},
	}
	for _, tc := range tests {
		if got := p.Check(tc.tool, nil); got != tc.want {
			t.Errorf("Check(%q) = %q, want %q", tc.tool, got, tc.want)
		}
	}
}

// TestExplicitDeny verifies a deny rule is honored and that first-match ordering
// lets a specific rule override a broader later one.
func TestExplicitDeny(t *testing.T) {
	p := New([]Rule{
		{Tool: "shell.exec", Decision: Deny}, // specific deny first
		{Tool: "shell.*", Decision: Ask},     // broader rule after
		{Tool: "fs.*", Decision: Allow},
	}, Ask)
	p.SetPath("") // no persistence needed

	if got := p.Check("shell.exec", nil); got != Deny {
		t.Errorf("shell.exec = %q, want deny (specific rule must win)", got)
	}
	if got := p.Check("shell.other", nil); got != Ask {
		t.Errorf("shell.other = %q, want ask (matches shell.*)", got)
	}
	if got := p.Check("fs.read", nil); got != Allow {
		t.Errorf("fs.read = %q, want allow", got)
	}
	if got := p.Check("totally.unmatched", nil); got != Ask {
		t.Errorf("unmatched = %q, want ask (default)", got)
	}
}

// TestGlobMatching checks the path.Match-based glob semantics, including that a
// malformed pattern never matches (and never panics).
func TestGlobMatching(t *testing.T) {
	tests := []struct {
		pattern, name string
		want          bool
	}{
		{"fs.*", "fs.read", true},
		{"fs.*", "fs.write", true},
		{"fs.*", "web.fetch", false},
		{"*", "anything", true},
		{"browser.eval", "browser.eval", true},
		{"browser.eval", "browser.click", false},
		{"[", "anything", false}, // malformed glob => no match, no panic
	}
	for _, tc := range tests {
		if got := globMatch(tc.pattern, tc.name); got != tc.want {
			t.Errorf("globMatch(%q, %q) = %v, want %v", tc.pattern, tc.name, got, tc.want)
		}
	}
}

// TestRememberToolWide verifies that Remember flips a tool that would otherwise
// be "ask" into "allow" for all future calls regardless of args.
func TestRememberToolWide(t *testing.T) {
	p := newIsolated(t)

	if got := p.Check("shell.exec", nil); got != Ask {
		t.Fatalf("precondition: shell.exec = %q, want ask", got)
	}

	p.Remember("shell.exec")

	if got := p.Check("shell.exec", nil); got != Allow {
		t.Errorf("after Remember: shell.exec = %q, want allow", got)
	}
	// Tool-wide approval covers calls carrying any args too.
	if got := p.Check("shell.exec", json.RawMessage(`{"cmd":"ls"}`)); got != Allow {
		t.Errorf("after Remember with args: shell.exec = %q, want allow", got)
	}
	if !p.IsRemembered("shell.exec", nil) {
		t.Errorf("IsRemembered = false, want true")
	}
}

// TestRememberArgsScoped verifies arg-scoped approvals only allow byte-identical
// args, leaving other invocations of the same tool still gated.
func TestRememberArgsScoped(t *testing.T) {
	p := newIsolated(t)
	safe := json.RawMessage(`{"cmd":"ls"}`)
	danger := json.RawMessage(`{"cmd":"rm -rf /"}`)

	p.RememberArgs("shell.exec", safe)

	if got := p.Check("shell.exec", safe); got != Allow {
		t.Errorf("approved args: shell.exec = %q, want allow", got)
	}
	if got := p.Check("shell.exec", danger); got != Ask {
		t.Errorf("other args: shell.exec = %q, want ask (must stay gated)", got)
	}
	// A bare (no-args) call must NOT be allowed by an arg-scoped approval.
	if got := p.Check("shell.exec", nil); got != Ask {
		t.Errorf("no-args call: shell.exec = %q, want ask", got)
	}
}

// TestForget removes a remembered approval and re-gates the tool.
func TestForget(t *testing.T) {
	p := newIsolated(t)
	p.Remember("fs.write")
	if got := p.Check("fs.write", nil); got != Allow {
		t.Fatalf("precondition: fs.write = %q, want allow", got)
	}

	if !p.Forget("fs.write", nil) {
		t.Errorf("Forget returned false, want true (something was removed)")
	}
	if got := p.Check("fs.write", nil); got != Ask {
		t.Errorf("after Forget: fs.write = %q, want ask", got)
	}
	// Forgetting again is a no-op.
	if p.Forget("fs.write", nil) {
		t.Errorf("second Forget returned true, want false")
	}
}

// TestPersistenceRoundTrip verifies a remembered approval is written to disk and
// loaded back by a fresh policy pointed at the same file.
func TestPersistenceRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "exec-approvals.json")

	p1 := Default()
	p1.SetPath(path)
	p1.Remember("shell.exec")                                  // tool-wide
	p1.RememberArgs("fs.write", json.RawMessage(`{"p":"/a"}`)) // arg-scoped

	// A second policy loading the same file inherits both approvals.
	p2 := New(Default().Rules(), Allow)
	p2.SetPath(path)
	if err := p2.Load(); err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := p2.Check("shell.exec", nil); got != Allow {
		t.Errorf("loaded tool-wide: shell.exec = %q, want allow", got)
	}
	if got := p2.Check("fs.write", json.RawMessage(`{"p":"/a"}`)); got != Allow {
		t.Errorf("loaded arg-scoped: fs.write = %q, want allow", got)
	}
	// The arg-scoped approval must not leak into other args after load.
	if got := p2.Check("fs.write", json.RawMessage(`{"p":"/other"}`)); got != Ask {
		t.Errorf("loaded arg-scoped other args: fs.write = %q, want ask", got)
	}
}

// TestLoadMissingFileIsOK confirms loading from a nonexistent path is a no-op,
// not an error (first-run behavior).
func TestLoadMissingFileIsOK(t *testing.T) {
	p := Default()
	p.SetPath(filepath.Join(t.TempDir(), "does-not-exist.json"))
	if err := p.Load(); err != nil {
		t.Errorf("Load of missing file = %v, want nil", err)
	}
}

// TestDisabledPersistence verifies an empty path turns Save/Load into safe
// no-ops while in-memory approvals still work.
func TestDisabledPersistence(t *testing.T) {
	p := New(Default().Rules(), Allow)
	p.SetPath("")
	p.Remember("shell.exec") // must not error despite no path
	if err := p.Save(); err != nil {
		t.Errorf("Save with empty path = %v, want nil", err)
	}
	if err := p.Load(); err != nil {
		t.Errorf("Load with empty path = %v, want nil", err)
	}
	if got := p.Check("shell.exec", nil); got != Allow {
		t.Errorf("in-memory approval lost: shell.exec = %q, want allow", got)
	}
}

// TestInvalidDefaultNormalized ensures a bogus default decision becomes Ask
// (fail-closed) rather than silently allowing everything.
func TestInvalidDefaultNormalized(t *testing.T) {
	p := New(nil, Decision("garbage"))
	p.SetPath("")
	if got := p.Check("anything", nil); got != Ask {
		t.Errorf("garbage default: Check = %q, want ask", got)
	}
}

// TestConcurrentAccess exercises Check + Remember from many goroutines under the
// race detector to confirm thread-safety. With -race, a data race fails the run.
func TestConcurrentAccess(t *testing.T) {
	p := newIsolated(t)
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			_ = p.Check("shell.exec", json.RawMessage(`{"cmd":"x"}`))
			if n%2 == 0 {
				p.Remember("shell.exec")
			} else {
				_ = p.Rules()
				_ = p.IsRemembered("fs.write", nil)
			}
		}(i)
	}
	wg.Wait()
	// After at least one Remember, the tool must be allowed.
	if got := p.Check("shell.exec", nil); got != Allow {
		t.Errorf("post-concurrency: shell.exec = %q, want allow", got)
	}
}

// TestRulesCopy verifies Rules returns an independent copy.
func TestRulesCopy(t *testing.T) {
	p := Default()
	rules := p.Rules()
	if len(rules) == 0 {
		t.Fatal("Default returned no rules")
	}
	rules[0].Decision = Deny // mutate the copy
	// The policy's own behavior is unaffected by mutating the returned slice.
	for _, r := range p.Rules() {
		if r.Tool == rules[0].Tool && r.Decision == Deny {
			t.Errorf("mutating returned Rules() leaked into the policy")
		}
	}
}
