// Package builtin provides the core, always-available local tools: filesystem
// reads/writes/listings and a bounded shell executor. Each is an ordinary
// tool.Tool so the engine registers and the policy gate mediates them exactly
// like any other capability (web, MCP-proxied, or sub-agent).
//
// Safety is non-negotiable here: every Invoke validates its arguments, bounds
// its work (size caps on reads/output, timeouts on exec), resolves relative
// paths against the ambient session working directory, and never panics on bad
// input — malformed args surface as a tool-level error (Result.IsError), while
// genuinely exceptional conditions return the error value.
package builtin

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/kubbot/agentry/internal/core/session"
	"github.com/kubbot/agentry/internal/core/tool"
)

// Bounds shared across the filesystem and shell tools.
const (
	// maxReadBytes caps fs.read output so a single file can't blow up context
	// or memory. ~256 KiB.
	maxReadBytes = 256 * 1024
	// maxListEntries caps the number of directory entries fs.list returns.
	maxListEntries = 1000
	// maxExecOutput caps combined stdout+stderr captured by shell.exec (~256 KiB);
	// excess is truncated with a marker so the model still sees a bounded result.
	maxExecOutput = 256 * 1024

	// defaultExecTimeout is used when shell.exec gets no timeout_sec.
	defaultExecTimeout = 30 * time.Second
	// maxExecTimeout is the hard ceiling regardless of the requested timeout.
	maxExecTimeout = 120 * time.Second
)

// All returns every builtin tool, ready for bulk registration by the engine.
func All() []tool.Tool {
	return []tool.Tool{
		&fsRead{},
		&fsWrite{},
		&fsList{},
		&shellExec{},
	}
}

// ---------------------------------------------------------------------------
// shared helpers
// ---------------------------------------------------------------------------

// sessionFrom recovers the ambient *session.Session from the any-typed handle,
// tolerating nil/wrong types (returns nil) so tools degrade gracefully when run
// outside a session.
func sessionFrom(v any) *session.Session {
	if s, ok := v.(*session.Session); ok {
		return s
	}
	return nil
}

// resolvePath makes a possibly-relative path absolute. Relative paths are
// anchored at the session's Cwd when available, otherwise at the process Cwd.
// The path is cleaned to collapse "." / ".." segments.
func resolvePath(p string, s *session.Session) (string, error) {
	if strings.TrimSpace(p) == "" {
		return "", errors.New("path is required")
	}
	if filepath.IsAbs(p) {
		return filepath.Clean(p), nil
	}
	base := ""
	if s != nil {
		base = s.Cwd
	}
	if base == "" {
		// Fall back to the process working directory.
		if wd, err := os.Getwd(); err == nil {
			base = wd
		}
	}
	if base == "" {
		// Last resort: clean the relative path as-is.
		return filepath.Clean(p), nil
	}
	return filepath.Clean(filepath.Join(base, p)), nil
}

// decodeArgs unmarshals JSON args into dst, normalizing an empty/nil body to an
// empty object so "no args" doesn't error.
func decodeArgs(raw json.RawMessage, dst any) error {
	b := bytes.TrimSpace(raw)
	if len(b) == 0 {
		b = []byte("{}")
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		// Retry leniently: unknown fields shouldn't hard-fail a tool call, but
		// we prefer the strict pass to catch typos when the args are clean.
		if e2 := json.Unmarshal(b, dst); e2 != nil {
			return err
		}
	}
	return nil
}

// errResult builds a tool-level error Result (model-visible, non-fatal).
func errResult(format string, a ...any) (tool.Result, error) {
	return tool.Result{Content: fmt.Sprintf(format, a...), IsError: true}, nil
}

// ---------------------------------------------------------------------------
// fs.read
// ---------------------------------------------------------------------------

type fsRead struct{}

func (fsRead) Name() string { return "fs.read" }

func (fsRead) Description() string {
	return "Read a UTF-8 text file from the local filesystem. " +
		"Relative paths resolve against the session working directory. " +
		"Output is capped at ~256KB."
}

func (fsRead) Schema() json.RawMessage {
	return json.RawMessage(`{
  "type": "object",
  "properties": {
    "path": {
      "type": "string",
      "description": "File path to read. Absolute, or relative to the session working directory."
    }
  },
  "required": ["path"],
  "additionalProperties": false
}`)
}

func (fsRead) Invoke(ctx context.Context, in tool.Input) (tool.Result, error) {
	var args struct {
		Path string `json:"path"`
	}
	if err := decodeArgs(in.Args, &args); err != nil {
		return errResult("fs.read: invalid arguments: %v", err)
	}
	sess := sessionFrom(in.Session)
	path, err := resolvePath(args.Path, sess)
	if err != nil {
		return errResult("fs.read: %v", err)
	}

	info, err := os.Stat(path)
	if err != nil {
		return errResult("fs.read: cannot stat %q: %v", path, err)
	}
	if info.IsDir() {
		return errResult("fs.read: %q is a directory (use fs.list)", path)
	}

	f, err := os.Open(path)
	if err != nil {
		return errResult("fs.read: cannot open %q: %v", path, err)
	}
	defer f.Close()

	// Read up to the cap plus one byte so we can detect truncation. ReadFull
	// stops at EOF (short file) or when the buffer fills (large file); both are
	// success for our purposes.
	buf := make([]byte, maxReadBytes+1)
	n, err := io.ReadFull(f, buf)
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return errResult("fs.read: read error on %q: %v", path, err)
	}
	truncated := n > maxReadBytes
	if truncated {
		n = maxReadBytes
	}
	data := buf[:n]

	if !utf8.Valid(data) {
		return errResult("fs.read: %q is not valid UTF-8 (binary file?)", path)
	}

	content := string(data)
	if truncated {
		content += fmt.Sprintf("\n\n[truncated: file larger than %d bytes]", maxReadBytes)
	}
	return tool.Result{
		Content: content,
		Meta: map[string]any{
			"path":      path,
			"bytes":     n,
			"truncated": truncated,
		},
	}, nil
}

// ---------------------------------------------------------------------------
// fs.write
// ---------------------------------------------------------------------------

type fsWrite struct{}

func (fsWrite) Name() string { return "fs.write" }

func (fsWrite) Description() string {
	return "Write text content to a file, creating parent directories as needed. " +
		"Relative paths resolve against the session working directory. " +
		"Overwrites any existing file. Returns the number of bytes written."
}

func (fsWrite) Schema() json.RawMessage {
	return json.RawMessage(`{
  "type": "object",
  "properties": {
    "path": {
      "type": "string",
      "description": "Destination file path. Absolute, or relative to the session working directory."
    },
    "content": {
      "type": "string",
      "description": "UTF-8 text content to write. Overwrites the file if it exists."
    }
  },
  "required": ["path", "content"],
  "additionalProperties": false
}`)
}

func (fsWrite) Invoke(ctx context.Context, in tool.Input) (tool.Result, error) {
	var args struct {
		Path    string `json:"path"`
		Content string `json:"content"`
	}
	if err := decodeArgs(in.Args, &args); err != nil {
		return errResult("fs.write: invalid arguments: %v", err)
	}
	sess := sessionFrom(in.Session)
	path, err := resolvePath(args.Path, sess)
	if err != nil {
		return errResult("fs.write: %v", err)
	}

	if dir := filepath.Dir(path); dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return errResult("fs.write: cannot create parent dir %q: %v", dir, err)
		}
	}

	if err := os.WriteFile(path, []byte(args.Content), 0o644); err != nil {
		return errResult("fs.write: cannot write %q: %v", path, err)
	}

	n := len(args.Content)
	return tool.Result{
		Content: fmt.Sprintf("wrote %d bytes to %s", n, path),
		Meta: map[string]any{
			"path":  path,
			"bytes": n,
		},
	}, nil
}

// ---------------------------------------------------------------------------
// fs.list
// ---------------------------------------------------------------------------

type fsList struct{}

func (fsList) Name() string { return "fs.list" }

func (fsList) Description() string {
	return "List the entries of a directory. Relative paths resolve against the " +
		"session working directory. Returns one entry per line with type and size."
}

func (fsList) Schema() json.RawMessage {
	return json.RawMessage(`{
  "type": "object",
  "properties": {
    "path": {
      "type": "string",
      "description": "Directory path to list. Absolute, or relative to the session working directory. Defaults to the working directory."
    }
  },
  "required": ["path"],
  "additionalProperties": false
}`)
}

func (fsList) Invoke(ctx context.Context, in tool.Input) (tool.Result, error) {
	var args struct {
		Path string `json:"path"`
	}
	if err := decodeArgs(in.Args, &args); err != nil {
		return errResult("fs.list: invalid arguments: %v", err)
	}
	sess := sessionFrom(in.Session)

	// Default to the working directory when no path is supplied.
	if strings.TrimSpace(args.Path) == "" {
		args.Path = "."
	}
	path, err := resolvePath(args.Path, sess)
	if err != nil {
		return errResult("fs.list: %v", err)
	}

	info, err := os.Stat(path)
	if err != nil {
		return errResult("fs.list: cannot stat %q: %v", path, err)
	}
	if !info.IsDir() {
		return errResult("fs.list: %q is not a directory", path)
	}

	entries, err := os.ReadDir(path)
	if err != nil {
		return errResult("fs.list: cannot read %q: %v", path, err)
	}

	// Stable order: directories don't get special treatment beyond name sort,
	// which keeps output deterministic for tests and diffs.
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })

	truncated := false
	if len(entries) > maxListEntries {
		entries = entries[:maxListEntries]
		truncated = true
	}

	var b strings.Builder
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		kind := "file"
		var size int64
		if e.IsDir() {
			kind = "dir"
		} else if fi, ferr := e.Info(); ferr == nil {
			size = fi.Size()
		}
		if kind == "dir" {
			fmt.Fprintf(&b, "%-4s  %s/\n", kind, e.Name())
		} else {
			fmt.Fprintf(&b, "%-4s  %8d  %s\n", kind, size, e.Name())
		}
		names = append(names, e.Name())
	}
	if truncated {
		fmt.Fprintf(&b, "[truncated: more than %d entries]\n", maxListEntries)
	}
	if b.Len() == 0 {
		b.WriteString("(empty directory)\n")
	}

	return tool.Result{
		Content: b.String(),
		Meta: map[string]any{
			"path":      path,
			"count":     len(names),
			"truncated": truncated,
		},
	}, nil
}

// ---------------------------------------------------------------------------
// shell.exec
// ---------------------------------------------------------------------------

type shellExec struct{}

func (shellExec) Name() string { return "shell.exec" }

func (shellExec) Description() string {
	return "Run a shell command via 'bash -lc'. Captures combined stdout+stderr " +
		"(capped at ~256KB) and the exit code. Runs in the session working " +
		"directory with the session environment. Bounded by a timeout " +
		"(default 30s, hard cap 120s)."
}

func (shellExec) Schema() json.RawMessage {
	return json.RawMessage(`{
  "type": "object",
  "properties": {
    "cmd": {
      "type": "string",
      "description": "Shell command line, executed with 'bash -lc'."
    },
    "timeout_sec": {
      "type": "integer",
      "description": "Optional timeout in seconds. Default 30, hard-capped at 120.",
      "minimum": 1,
      "maximum": 120
    }
  },
  "required": ["cmd"],
  "additionalProperties": false
}`)
}

func (shellExec) Invoke(ctx context.Context, in tool.Input) (tool.Result, error) {
	var args struct {
		Cmd        string `json:"cmd"`
		TimeoutSec int    `json:"timeout_sec"`
	}
	if err := decodeArgs(in.Args, &args); err != nil {
		return errResult("shell.exec: invalid arguments: %v", err)
	}
	if strings.TrimSpace(args.Cmd) == "" {
		return errResult("shell.exec: cmd is required")
	}

	// Resolve the effective timeout: default when unset, clamp to the hard cap.
	timeout := defaultExecTimeout
	if args.TimeoutSec > 0 {
		timeout = time.Duration(args.TimeoutSec) * time.Second
	}
	if timeout > maxExecTimeout {
		timeout = maxExecTimeout
	}

	runCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	// "-l" runs a login shell (loads profile), "-c" reads the command string.
	cmd := exec.CommandContext(runCtx, "bash", "-lc", args.Cmd)

	// Apply ambient session context: working directory and environment.
	sess := sessionFrom(in.Session)
	if sess != nil {
		if sess.Cwd != "" {
			cmd.Dir = sess.Cwd
		}
		if len(sess.Env) > 0 {
			cmd.Env = mergedEnv(sess.Env)
		}
	}

	// Capture combined stdout+stderr into a bounded buffer.
	var out cappedBuffer
	out.limit = maxExecOutput
	cmd.Stdout = &out
	cmd.Stderr = &out

	start := time.Now()
	runErr := cmd.Run()
	elapsed := time.Since(start)

	// Determine exit status and whether we hit the timeout.
	exitCode := 0
	timedOut := errors.Is(runCtx.Err(), context.DeadlineExceeded)
	if runErr != nil {
		var ee *exec.ExitError
		switch {
		case errors.As(runErr, &ee):
			exitCode = ee.ExitCode()
		case timedOut:
			exitCode = -1
		default:
			// Failure to even start the process (e.g. bash missing).
			return errResult("shell.exec: failed to run command: %v", runErr)
		}
	}

	content := out.String()
	if out.truncated {
		content += fmt.Sprintf("\n[truncated: output exceeded %d bytes]", maxExecOutput)
	}
	if timedOut {
		content += fmt.Sprintf("\n[timed out after %s]", timeout)
	}
	// Always make the exit code legible to the model.
	content += fmt.Sprintf("\n[exit code: %d]", exitCode)

	return tool.Result{
		Content: content,
		IsError: exitCode != 0,
		Meta: map[string]any{
			"exit_code":  exitCode,
			"timed_out":  timedOut,
			"truncated":  out.truncated,
			"elapsed_ms": elapsed.Milliseconds(),
		},
	}, nil
}

// mergedEnv overlays the session env onto the current process environment so
// commands inherit PATH etc. while honoring session-specific overrides.
func mergedEnv(sessionEnv map[string]string) []string {
	base := os.Environ()
	// Index existing keys for override.
	idx := make(map[string]int, len(base))
	for i, kv := range base {
		if eq := strings.IndexByte(kv, '='); eq >= 0 {
			idx[kv[:eq]] = i
		}
	}
	for k, v := range sessionEnv {
		entry := k + "=" + v
		if i, ok := idx[k]; ok {
			base[i] = entry
		} else {
			base = append(base, entry)
		}
	}
	return base
}

// ---------------------------------------------------------------------------
// bounded IO helpers
// ---------------------------------------------------------------------------

// cappedBuffer is an io.Writer that stores at most `limit` bytes and records
// whether any write was dropped. It lets shell.exec bound captured output
// without truncating mid-stream surprises.
type cappedBuffer struct {
	buf       bytes.Buffer
	limit     int
	truncated bool
}

func (c *cappedBuffer) Write(p []byte) (int, error) {
	// Always report the full length as written so the command never sees a
	// short write / broken pipe; we simply discard the overflow.
	if c.limit <= 0 {
		c.buf.Write(p)
		return len(p), nil
	}
	remaining := c.limit - c.buf.Len()
	if remaining <= 0 {
		c.truncated = true
		return len(p), nil
	}
	if len(p) > remaining {
		c.buf.Write(p[:remaining])
		c.truncated = true
		return len(p), nil
	}
	c.buf.Write(p)
	return len(p), nil
}

func (c *cappedBuffer) String() string { return c.buf.String() }
