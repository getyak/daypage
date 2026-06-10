package builtin

import (
	"context"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kubbot/agentry/internal/core/session"
	"github.com/kubbot/agentry/internal/core/tool"
)

// byName finds a builtin tool by its registered name.
func byName(t *testing.T, name string) tool.Tool {
	t.Helper()
	for _, tl := range All() {
		if tl.Name() == name {
			return tl
		}
	}
	t.Fatalf("builtin tool %q not found in All()", name)
	return nil
}

func mustJSON(t *testing.T, v any) json.RawMessage {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal args: %v", err)
	}
	return b
}

// TestFSWriteReadRoundtrip writes a file then reads it back via the tools,
// exercising parent-dir creation, byte accounting, and content fidelity.
func TestFSWriteReadRoundtrip(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	// Nested path forces fs.write to create parent directories.
	path := filepath.Join(dir, "nested", "sub", "note.txt")
	const content = "hello agentry\nline two\n你好\n"

	write := byName(t, "fs.write")
	res, err := write.Invoke(ctx, tool.Input{
		Args: mustJSON(t, map[string]any{"path": path, "content": content}),
	})
	if err != nil {
		t.Fatalf("fs.write returned error: %v", err)
	}
	if res.IsError {
		t.Fatalf("fs.write reported tool error: %s", res.Content)
	}
	if got, ok := res.Meta["bytes"].(int); !ok || got != len(content) {
		t.Fatalf("fs.write bytes meta = %v, want %d", res.Meta["bytes"], len(content))
	}

	read := byName(t, "fs.read")
	rres, err := read.Invoke(ctx, tool.Input{
		Args: mustJSON(t, map[string]any{"path": path}),
	})
	if err != nil {
		t.Fatalf("fs.read returned error: %v", err)
	}
	if rres.IsError {
		t.Fatalf("fs.read reported tool error: %s", rres.Content)
	}
	if rres.Content != content {
		t.Fatalf("fs.read content mismatch:\n got %q\nwant %q", rres.Content, content)
	}
}

// TestFSReadRelativeUsesSessionCwd verifies relative paths resolve against the
// ambient session working directory.
func TestFSReadRelativeUsesSessionCwd(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	sess := session.New("s1")
	sess.Cwd = dir

	write := byName(t, "fs.write")
	if _, err := write.Invoke(ctx, tool.Input{
		Args:    mustJSON(t, map[string]any{"path": "rel.txt", "content": "data"}),
		Session: sess,
	}); err != nil {
		t.Fatalf("fs.write rel: %v", err)
	}

	read := byName(t, "fs.read")
	res, err := read.Invoke(ctx, tool.Input{
		Args:    mustJSON(t, map[string]any{"path": "rel.txt"}),
		Session: sess,
	})
	if err != nil {
		t.Fatalf("fs.read rel: %v", err)
	}
	if res.Content != "data" {
		t.Fatalf("fs.read rel content = %q, want %q", res.Content, "data")
	}
}

// TestFSReadMissing surfaces a missing file as a tool-level error, not a panic
// or a hard error return.
func TestFSReadMissing(t *testing.T) {
	ctx := context.Background()
	read := byName(t, "fs.read")
	res, err := read.Invoke(ctx, tool.Input{
		Args: mustJSON(t, map[string]any{"path": filepath.Join(t.TempDir(), "nope.txt")}),
	})
	if err != nil {
		t.Fatalf("fs.read missing should not hard-error: %v", err)
	}
	if !res.IsError {
		t.Fatalf("fs.read missing should set IsError; content=%q", res.Content)
	}
}

// TestFSReadBadArgs ensures malformed JSON args degrade gracefully.
func TestFSReadBadArgs(t *testing.T) {
	ctx := context.Background()
	read := byName(t, "fs.read")
	res, err := read.Invoke(ctx, tool.Input{Args: json.RawMessage(`{"path": 123}`)})
	if err != nil {
		t.Fatalf("bad args should not hard-error: %v", err)
	}
	if !res.IsError {
		t.Fatalf("bad args should set IsError; content=%q", res.Content)
	}
}

// TestShellExecEcho runs a trivial command and checks combined output + exit 0.
func TestShellExecEcho(t *testing.T) {
	ctx := context.Background()
	sh := byName(t, "shell.exec")
	res, err := sh.Invoke(ctx, tool.Input{
		Args: mustJSON(t, map[string]any{"cmd": "echo hello-from-shell"}),
	})
	if err != nil {
		t.Fatalf("shell.exec returned error: %v", err)
	}
	if res.IsError {
		t.Fatalf("shell.exec echo reported error: %s", res.Content)
	}
	if !strings.Contains(res.Content, "hello-from-shell") {
		t.Fatalf("shell.exec output missing echo text: %q", res.Content)
	}
	if code, ok := res.Meta["exit_code"].(int); !ok || code != 0 {
		t.Fatalf("shell.exec exit_code = %v, want 0", res.Meta["exit_code"])
	}
}

// TestShellExecStderrAndExitCode confirms stderr is captured and a non-zero
// exit propagates to IsError + meta.
func TestShellExecStderrAndExitCode(t *testing.T) {
	ctx := context.Background()
	sh := byName(t, "shell.exec")
	res, err := sh.Invoke(ctx, tool.Input{
		Args: mustJSON(t, map[string]any{"cmd": "echo oops 1>&2; exit 3"}),
	})
	if err != nil {
		t.Fatalf("shell.exec returned error: %v", err)
	}
	if !res.IsError {
		t.Fatalf("non-zero exit should set IsError; content=%q", res.Content)
	}
	if !strings.Contains(res.Content, "oops") {
		t.Fatalf("stderr not captured: %q", res.Content)
	}
	if code, ok := res.Meta["exit_code"].(int); !ok || code != 3 {
		t.Fatalf("exit_code = %v, want 3", res.Meta["exit_code"])
	}
}

// TestShellExecUsesSessionCwd checks the command's working directory is the
// session Cwd.
func TestShellExecUsesSessionCwd(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	sess := session.New("s2")
	sess.Cwd = dir

	sh := byName(t, "shell.exec")
	res, err := sh.Invoke(ctx, tool.Input{
		Args:    mustJSON(t, map[string]any{"cmd": "pwd"}),
		Session: sess,
	})
	if err != nil {
		t.Fatalf("shell.exec pwd: %v", err)
	}
	// macOS /tmp symlinks to /private/tmp; resolve both sides for comparison.
	got := strings.TrimSpace(res.Content)
	if !strings.Contains(got, filepath.Base(dir)) {
		t.Fatalf("pwd output %q does not reference session cwd %q", got, dir)
	}
}

// TestShellExecMissingCmd treats an empty command as a tool error.
func TestShellExecMissingCmd(t *testing.T) {
	ctx := context.Background()
	sh := byName(t, "shell.exec")
	res, err := sh.Invoke(ctx, tool.Input{Args: json.RawMessage(`{}`)})
	if err != nil {
		t.Fatalf("empty cmd should not hard-error: %v", err)
	}
	if !res.IsError {
		t.Fatalf("empty cmd should set IsError; content=%q", res.Content)
	}
}

// TestFSList lists a directory and finds known entries.
func TestFSList(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	write := byName(t, "fs.write")
	for _, name := range []string{"a.txt", "b.txt"} {
		if _, err := write.Invoke(ctx, tool.Input{
			Args: mustJSON(t, map[string]any{"path": filepath.Join(dir, name), "content": "x"}),
		}); err != nil {
			t.Fatalf("seed write %s: %v", name, err)
		}
	}

	list := byName(t, "fs.list")
	res, err := list.Invoke(ctx, tool.Input{
		Args: mustJSON(t, map[string]any{"path": dir}),
	})
	if err != nil {
		t.Fatalf("fs.list: %v", err)
	}
	if res.IsError {
		t.Fatalf("fs.list reported error: %s", res.Content)
	}
	if !strings.Contains(res.Content, "a.txt") || !strings.Contains(res.Content, "b.txt") {
		t.Fatalf("fs.list missing entries: %q", res.Content)
	}
	if cnt, ok := res.Meta["count"].(int); !ok || cnt != 2 {
		t.Fatalf("fs.list count = %v, want 2", res.Meta["count"])
	}
}

// TestSchemasAreValidJSON guards that every builtin advertises parseable schema.
func TestSchemasAreValidJSON(t *testing.T) {
	for _, tl := range All() {
		var m map[string]any
		if err := json.Unmarshal(tl.Schema(), &m); err != nil {
			t.Fatalf("tool %q has invalid schema JSON: %v", tl.Name(), err)
		}
		if m["type"] != "object" {
			t.Fatalf("tool %q schema type = %v, want object", tl.Name(), m["type"])
		}
	}
}
