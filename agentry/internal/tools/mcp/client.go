package mcp

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"sync"
	"time"

	"github.com/kubbot/agentry/internal/core/tool"
)

// clientInfo identifies this MCP client to servers in the handshake.
var clientInfo = Implementation{Name: "agentry", Version: "0.1.0"}

// Timeouts bound every phase of the client so a wedged or hostile server can
// never block the agent indefinitely.
const (
	// initializeTimeout bounds the initialize + tools/list handshake.
	initializeTimeout = 30 * time.Second
	// defaultCallTimeout bounds a single tools/call when the caller's context has
	// no deadline of its own.
	defaultCallTimeout = 120 * time.Second
)

// Client is a live connection to one MCP server subprocess. It speaks JSON-RPC
// 2.0 over the child's stdio, owns a single reader goroutine that demultiplexes
// responses to in-flight requests by id, and exposes the server's discovered
// tools as local tool.Tool values via AsTools.
//
// A Client is safe for concurrent Invoke calls: each call registers a pending
// slot keyed by a unique id, writes the request, and waits for the reader to
// deliver the matching response.
type Client struct {
	cmd  *exec.Cmd
	conn *Conn
	stdin io.WriteCloser

	// tools is the immutable set discovered at connect time.
	tools []ToolDescriptor

	// pending maps an outstanding request id to the channel awaiting its reply.
	mu      sync.Mutex
	pending map[string]chan Message
	nextID  int64

	// closeOnce guards Close; readErr records why the reader goroutine stopped.
	closeOnce sync.Once
	closed    chan struct{}
	readErrMu sync.Mutex
	readErr   error
}

// Connect spawns the MCP server given by command+args, performs the JSON-RPC
// initialize handshake, sends the initialized notification, and fetches the
// server's tool list. The returned Client owns the subprocess; call Close to
// terminate it.
//
// ctx bounds the spawn and handshake. After Connect returns, the subprocess
// keeps running until Close (or until it exits on its own, which surfaces as an
// error on subsequent Invoke calls).
func Connect(ctx context.Context, command string, args []string) (*Client, error) {
	return connectWithEnv(ctx, command, args, nil)
}

// connectWithEnv is Connect with an optional set of extra environment variables
// ("KEY=value") layered onto the inherited process environment for the child.
// It is the testable core (a test re-execs the test binary as a fake server,
// selected via such an env var). extraEnv may be nil for the common case.
func connectWithEnv(ctx context.Context, command string, args, extraEnv []string) (*Client, error) {
	if command == "" {
		return nil, errors.New("mcp: command is required")
	}

	// We do not bind the long-lived subprocess to ctx: ctx bounds only the
	// handshake. Lifetime is controlled explicitly via Close so the discovered
	// tools remain usable across many agent turns.
	cmd := exec.Command(command, args...)
	if len(extraEnv) > 0 {
		cmd.Env = append(os.Environ(), extraEnv...)
	}

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("mcp: stdin pipe: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("mcp: stdout pipe: %w", err)
	}
	// Inherit stderr to nowhere by default would hide server diagnostics; we
	// drain it to avoid the child blocking on a full pipe, discarding the bytes.
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, fmt.Errorf("mcp: stderr pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("mcp: start %q: %w", command, err)
	}

	c := &Client{
		cmd:     cmd,
		conn:    NewConn(stdout, stdin),
		stdin:   stdin,
		pending: map[string]chan Message{},
		closed:  make(chan struct{}),
	}

	// Drain stderr so a chatty server never deadlocks on a full stderr pipe.
	go drain(stderr)

	// Start the reader loop: it demultiplexes responses to waiters.
	go c.readLoop()

	// Perform the handshake under a bounded context derived from ctx.
	hctx, cancel := context.WithTimeout(ctx, initializeTimeout)
	defer cancel()

	if err := c.initialize(hctx); err != nil {
		_ = c.Close()
		return nil, err
	}
	if err := c.listTools(hctx); err != nil {
		_ = c.Close()
		return nil, err
	}

	return c, nil
}

// initialize runs the MCP initialize request and the initialized notification.
func (c *Client) initialize(ctx context.Context) error {
	params := InitializeParams{
		ProtocolVersion: ProtocolVersion,
		Capabilities:    Capabilities{Tools: &ToolsCapability{}},
		ClientInfo:      clientInfo,
	}
	var res InitializeResult
	if err := c.call(ctx, MethodInitialize, params, &res); err != nil {
		return fmt.Errorf("mcp: initialize: %w", err)
	}
	// Per the spec, the client signals readiness with a notification (no reply).
	note, err := NewNotification(MethodInitialized, struct{}{})
	if err != nil {
		return fmt.Errorf("mcp: build initialized notification: %w", err)
	}
	if err := c.conn.Write(note); err != nil {
		return fmt.Errorf("mcp: send initialized: %w", err)
	}
	return nil
}

// listTools fetches and stores the server's tool descriptors.
func (c *Client) listTools(ctx context.Context) error {
	var res ListToolsResult
	if err := c.call(ctx, MethodToolsList, struct{}{}, &res); err != nil {
		return fmt.Errorf("mcp: tools/list: %w", err)
	}
	c.tools = res.Tools
	return nil
}

// Tools returns the raw descriptors discovered from the server (read-only).
func (c *Client) Tools() []ToolDescriptor {
	out := make([]ToolDescriptor, len(c.tools))
	copy(out, c.tools)
	return out
}

// AsTools wraps each discovered remote tool as a local tool.Tool whose Invoke
// proxies a tools/call to the server. Names are passed through unchanged so the
// agent and policy see the server's own tool names.
func (c *Client) AsTools() []tool.Tool {
	out := make([]tool.Tool, 0, len(c.tools))
	for _, d := range c.tools {
		out = append(out, &remoteTool{client: c, desc: d})
	}
	return out
}

// Close terminates the subprocess and unblocks any waiters. It is idempotent.
func (c *Client) Close() error {
	c.closeOnce.Do(func() {
		close(c.closed)
		// Closing stdin signals EOF to a well-behaved server so it can exit.
		_ = c.stdin.Close()
		if c.cmd.Process != nil {
			_ = c.cmd.Process.Kill()
		}
		// Reap the process so it does not linger as a zombie.
		_ = c.cmd.Wait()
	})
	return nil
}

// call performs one request/response round trip: it allocates an id, registers a
// waiter, writes the request, and blocks until the matching response arrives, the
// context expires, or the connection closes. On success it unmarshals the result
// into out (which may be nil to discard it).
func (c *Client) call(ctx context.Context, method string, params, out any) error {
	id := c.allocID()
	rawID := json.RawMessage(strconv.FormatInt(id, 10))

	req, err := NewRequest(rawID, method, params)
	if err != nil {
		return fmt.Errorf("encode request: %w", err)
	}

	ch := make(chan Message, 1)
	c.mu.Lock()
	c.pending[string(rawID)] = ch
	c.mu.Unlock()

	// Ensure the waiter is always removed, even on error paths.
	defer func() {
		c.mu.Lock()
		delete(c.pending, string(rawID))
		c.mu.Unlock()
	}()

	if err := c.conn.Write(req); err != nil {
		return fmt.Errorf("write request: %w", err)
	}

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-c.closed:
		return c.closedErr()
	case msg := <-ch:
		if msg.Error != nil {
			return msg.Error
		}
		if out == nil {
			return nil
		}
		if len(msg.Result) == 0 {
			// A response with neither result nor error is malformed; treat the
			// absent result as an empty object so out keeps its zero value.
			return nil
		}
		if err := json.Unmarshal(msg.Result, out); err != nil {
			return fmt.Errorf("decode result: %w", err)
		}
		return nil
	}
}

// readLoop reads frames until EOF/error and routes each response to its waiter
// by id. Notifications and requests from the server (none expected for our
// subset) are ignored. When the loop ends it records the cause and wakes all
// waiters via the closed channel (through Close-like semantics on readErr).
func (c *Client) readLoop() {
	for {
		msg, err := c.conn.Read()
		if err != nil {
			c.setReadErr(err)
			// Wake everyone: mark closed so pending calls fail fast.
			c.closeOnce.Do(func() {
				close(c.closed)
				_ = c.stdin.Close()
				if c.cmd.Process != nil {
					_ = c.cmd.Process.Kill()
				}
				_ = c.cmd.Wait()
			})
			return
		}
		// Only responses (id + result/error, no method) are routed. Anything else
		// (server-initiated notification/request) is outside our subset; ignore it
		// rather than erroring, to stay liberal in what we accept.
		if msg.Method != "" || len(msg.ID) == 0 {
			continue
		}
		c.mu.Lock()
		ch, ok := c.pending[string(msg.ID)]
		c.mu.Unlock()
		if ok {
			// Non-blocking: the buffer is size 1 and each id is delivered once.
			select {
			case ch <- msg:
			default:
			}
		}
	}
}

// allocID returns a fresh monotonic request id.
func (c *Client) allocID() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.nextID++
	return c.nextID
}

func (c *Client) setReadErr(err error) {
	c.readErrMu.Lock()
	if c.readErr == nil {
		c.readErr = err
	}
	c.readErrMu.Unlock()
}

// closedErr explains why a call could not complete: the recorded read error if
// any, else a generic closed-connection error.
func (c *Client) closedErr() error {
	c.readErrMu.Lock()
	defer c.readErrMu.Unlock()
	if c.readErr != nil && !errors.Is(c.readErr, io.EOF) {
		return fmt.Errorf("mcp: connection closed: %w", c.readErr)
	}
	return errors.New("mcp: connection closed")
}

// callTool issues a tools/call for the named tool with raw JSON arguments,
// applying a default timeout when ctx has no deadline.
func (c *Client) callTool(ctx context.Context, name string, args json.RawMessage) (CallToolResult, error) {
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, defaultCallTimeout)
		defer cancel()
	}
	params := CallToolParams{Name: name, Arguments: args}
	var res CallToolResult
	if err := c.call(ctx, MethodToolsCall, params, &res); err != nil {
		return CallToolResult{}, err
	}
	return res, nil
}

// drain discards everything from r (used for the child's stderr) so a chatty
// server never blocks on a full pipe. It stops at EOF/close.
func drain(r io.Reader) {
	br := bufio.NewReader(r)
	buf := make([]byte, 4096)
	for {
		if _, err := br.Read(buf); err != nil {
			return
		}
	}
}

// ---------------------------------------------------------------------------
// remoteTool: a discovered MCP tool exposed as a local tool.Tool.

// remoteTool adapts one server-side MCP tool to the local Tool interface. Its
// Invoke proxies a tools/call to the originating Client.
type remoteTool struct {
	client *Client
	desc   ToolDescriptor
}

func (t *remoteTool) Name() string { return t.desc.Name }

func (t *remoteTool) Description() string { return t.desc.Description }

// Schema returns the remote tool's input schema, defaulting to a permissive
// empty-object schema when the server omitted one (some servers send null).
func (t *remoteTool) Schema() json.RawMessage {
	if len(t.desc.InputSchema) == 0 || string(t.desc.InputSchema) == "null" {
		return json.RawMessage(`{"type":"object"}`)
	}
	return t.desc.InputSchema
}

// Invoke proxies the call to the MCP server and maps the result back into a
// tool.Result. A transport/protocol failure becomes an error tool.Result
// (model-visible, non-fatal) rather than a Go error, so one flaky remote tool
// never aborts the agent loop. The server's isError flag is honored.
func (t *remoteTool) Invoke(ctx context.Context, in tool.Input) (tool.Result, error) {
	res, err := t.client.callTool(ctx, t.desc.Name, in.Args)
	if err != nil {
		return tool.Result{
			Content: fmt.Sprintf("mcp tool %q failed: %v", t.desc.Name, err),
			IsError: true,
		}, nil
	}
	return tool.Result{
		Content: res.Text(),
		IsError: res.IsError,
		Meta:    map[string]any{"mcp_tool": t.desc.Name},
	}, nil
}
