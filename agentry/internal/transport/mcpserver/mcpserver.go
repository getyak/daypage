// Package mcpserver exposes an agentry Engine's tool registry over the Model
// Context Protocol (MCP), so any MCP-capable client — including Claude Code
// itself — can discover and invoke agentry's tools (DESIGN §6, §3).
//
// It is the mirror image of internal/tools/mcp (the MCP *client*): both speak
// JSON-RPC 2.0 over stdio with the same small method vocabulary, and this server
// reuses that package's codec and protocol types so the two directions can never
// drift apart. We implement only the subset MCP requires for tool serving:
//
//	initialize                 -> advertise protocol version + tools capability.
//	notifications/initialized  -> client readiness signal (no reply).
//	tools/list                 -> enumerate eng.Tools.List().
//	tools/call                 -> invoke a tool and return its content.
//
// No MCP SDK dependency: MCP at the wire level is just JSON-RPC with these
// methods, so a hand-written subset keeps the dependency surface at zero and the
// behavior auditable. Robustness mirrors the stdio transport: malformed lines,
// unknown methods, and bad params yield JSON-RPC errors rather than crashing,
// and tool invocation failures are returned as MCP error results (isError) so a
// misbehaving tool never tears down the connection.
package mcpserver

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/kubbot/agentry/internal/core/agent"
	"github.com/kubbot/agentry/internal/core/session"
	"github.com/kubbot/agentry/internal/core/tool"
	"github.com/kubbot/agentry/internal/tools/mcp"
)

// serverInfo identifies this MCP server to clients in the handshake.
var serverInfo = mcp.Implementation{Name: "agentry", Version: "0.1.0"}

// Serve runs the MCP server over the process stdio until stdin reaches EOF or
// ctx is cancelled. Tools are taken from eng.Tools; tool invocations are given a
// throwaway session carrying the engine's ambient model so session-aware tools
// (fs.*, shell.exec) still resolve relative paths against the process working
// directory.
func Serve(ctx context.Context, eng *agent.Engine) error {
	return serve(ctx, eng, os.Stdin, os.Stdout)
}

// serve is the testable core of Serve, parameterized over its streams so tests
// can drive it without touching process stdio.
func serve(ctx context.Context, eng *agent.Engine, in io.Reader, out io.Writer) error {
	if eng == nil {
		return errors.New("mcpserver: engine is nil")
	}
	s := &server{eng: eng, conn: mcp.NewConn(in, out)}
	return s.loop(ctx)
}

// server holds per-connection state: the engine whose tools are exposed and the
// framed JSON-RPC connection.
type server struct {
	eng  *agent.Engine
	conn *mcp.Conn
}

// loop reads and dispatches frames until EOF or cancellation.
func (s *server) loop(ctx context.Context) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		msg, err := s.conn.Read()
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil // clean shutdown: peer closed stdin
			}
			if mcp.IsParseError(err) {
				// We could not attribute the line to an id; reply with id:null per
				// the JSON-RPC spec and keep serving.
				_ = s.conn.Write(mcp.NewErrorResponse(jsonNull(), mcp.CodeParseError, "parse error", err.Error()))
				continue
			}
			if ctxErr := ctx.Err(); ctxErr != nil {
				return ctxErr
			}
			return fmt.Errorf("mcpserver: read: %w", err)
		}
		s.handle(ctx, msg)
	}
}

// handle dispatches one inbound frame. Notifications get no reply; requests get
// exactly one response (result or error).
func (s *server) handle(ctx context.Context, msg mcp.Message) {
	// Be lenient about the version field (some clients omit it) but reject a
	// present-but-wrong version to catch protocol mismatches early.
	if msg.JSONRPC != "" && msg.JSONRPC != mcp.JSONRPCVersion {
		if msg.IsRequest() {
			_ = s.conn.Write(mcp.NewErrorResponse(msg.ID, mcp.CodeInvalidRequest, "unsupported jsonrpc version", msg.JSONRPC))
		}
		return
	}
	if msg.Method == "" {
		// A frame with no method is not something we serve (it's a response, which
		// we never expect as a server). Ignore notifications; error on requests.
		if msg.IsRequest() {
			_ = s.conn.Write(mcp.NewErrorResponse(msg.ID, mcp.CodeInvalidRequest, "missing method", nil))
		}
		return
	}

	// Notifications (no id) are executed for side effects only; never answered.
	if msg.IsNotification() {
		// notifications/initialized is the only one we expect; nothing to do.
		return
	}

	result, rpcErr := s.dispatch(ctx, msg)
	if rpcErr != nil {
		_ = s.conn.Write(mcp.Message{JSONRPC: mcp.JSONRPCVersion, ID: msg.ID, Error: rpcErr})
		return
	}
	resp, err := mcp.NewResult(msg.ID, result)
	if err != nil {
		_ = s.conn.Write(mcp.NewErrorResponse(msg.ID, mcp.CodeInternalError, "encode result", err.Error()))
		return
	}
	_ = s.conn.Write(resp)
}

// dispatch routes a request method to its handler, returning either a result
// payload (to be marshaled) or a JSON-RPC error. It never panics on bad params.
func (s *server) dispatch(ctx context.Context, msg mcp.Message) (any, *mcp.RPCError) {
	switch msg.Method {
	case mcp.MethodInitialize:
		return s.handleInitialize(msg.Params), nil
	case mcp.MethodToolsList:
		return s.handleToolsList(), nil
	case mcp.MethodToolsCall:
		return s.handleToolsCall(ctx, msg.Params)
	default:
		return nil, &mcp.RPCError{Code: mcp.CodeMethodNotFound, Message: "method not found: " + msg.Method}
	}
}

// handleInitialize advertises our tools capability and the negotiated protocol
// version. Per the MCP lifecycle spec, the server echoes the client's requested
// version when it supports it, otherwise replies with its own preferred version
// so the client can decide whether to proceed. We parse the client's params
// leniently: a malformed or absent payload simply negotiates from an empty
// request (yielding the preferred version) rather than failing the handshake.
func (s *server) handleInitialize(params json.RawMessage) mcp.InitializeResult {
	var p mcp.InitializeParams
	_ = unmarshalParams(params, &p) // tolerate absent/garbled params; p stays zero
	return mcp.InitializeResult{
		ProtocolVersion: mcp.NegotiateProtocolVersion(p.ProtocolVersion),
		Capabilities:    mcp.Capabilities{Tools: &mcp.ToolsCapability{}},
		ServerInfo:      serverInfo,
	}
}

// handleToolsList enumerates the engine's registry as MCP tool descriptors,
// mapping each tool's JSON Schema to the MCP inputSchema field.
func (s *server) handleToolsList() mcp.ListToolsResult {
	out := mcp.ListToolsResult{Tools: []mcp.ToolDescriptor{}} // non-nil => [] not null
	if s.eng.Tools == nil {
		return out
	}
	for _, t := range s.eng.Tools.List() {
		out.Tools = append(out.Tools, mcp.ToolDescriptor{
			Name:        t.Name(),
			Description: t.Description(),
			InputSchema: schemaOrEmpty(t.Schema()),
		})
	}
	return out
}

// handleToolsCall invokes the named tool and returns its content. A missing
// registry or unknown tool is a JSON-RPC method error; a tool that runs but
// fails is returned as a successful response carrying an MCP error result
// (isError:true), matching how MCP surfaces tool-level failures to the model.
func (s *server) handleToolsCall(ctx context.Context, params json.RawMessage) (any, *mcp.RPCError) {
	var p mcp.CallToolParams
	if err := unmarshalParams(params, &p); err != nil {
		return nil, &mcp.RPCError{Code: mcp.CodeInvalidParams, Message: "invalid params", Data: rawJSON(err.Error())}
	}
	if p.Name == "" {
		return nil, &mcp.RPCError{Code: mcp.CodeInvalidParams, Message: "tool name is required"}
	}
	if s.eng.Tools == nil {
		return nil, &mcp.RPCError{Code: mcp.CodeMethodNotFound, Message: "no tools available"}
	}
	t, ok := s.eng.Tools.Get(p.Name)
	if !ok {
		return nil, &mcp.RPCError{Code: mcp.CodeMethodNotFound, Message: "tool not found: " + p.Name}
	}

	// Validate the caller-supplied arguments against the tool's advertised input
	// schema before invoking, mirroring the agent loop's own pre-invocation check
	// (engine.dispatch). A third-party MCP client drives this path directly, so
	// catching a malformed call here returns a clear, field-anchored MCP error
	// result (isError:true) the client's model can read and correct — instead of
	// the tool's ad-hoc decoding surfacing an opaque message, or an advertised
	// constraint (minimum/maximum/required/enum) being silently ignored. The
	// validator is permissive: schema features it does not model never reject, so
	// tools with exotic schemas are unaffected.
	args := normalizeArgs(p.Arguments)
	if problems := tool.ValidateArgs(t.Schema(), args); len(problems) > 0 {
		return mcp.CallToolResult{
			Content: []mcp.Content{mcp.TextContent(tool.FormatValidationProblems(p.Name, problems))},
			IsError: true,
		}, nil
	}

	// Provide an ambient session so session-aware tools behave sensibly. It is
	// throwaway (one per call); we seed its model from the engine. We do not run
	// the policy gate here: serving a tool over MCP is an explicit, operator-
	// initiated exposure, and the gate is the agent loop's concern.
	sess := session.New("mcp")
	sess.Model = s.eng.Model

	res, err := safeInvoke(ctx, t, tool.Input{Args: args, Session: sess})
	if err != nil {
		// An invocation that returned a Go error is reported as an MCP error
		// result rather than a transport error, so the client's model can react.
		return mcp.CallToolResult{
			Content: []mcp.Content{mcp.TextContent(fmt.Sprintf("tool %q failed: %v", p.Name, err))},
			IsError: true,
		}, nil
	}
	return mcp.CallToolResult{
		Content: []mcp.Content{mcp.TextContent(res.Content)},
		IsError: res.IsError,
	}, nil
}

// safeInvoke calls a tool's Invoke, converting a panic into an error so a buggy
// tool can never crash the server process.
func safeInvoke(ctx context.Context, t tool.Tool, in tool.Input) (res tool.Result, err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("panic: %v", r)
		}
	}()
	return t.Invoke(ctx, in)
}

// ---------------------------------------------------------------------------
// helpers

// jsonNull is the literal JSON null used as the id of error responses whose
// originating id could not be recovered.
func jsonNull() json.RawMessage { return json.RawMessage("null") }

// unmarshalParams decodes JSON-RPC params into dst, tolerating absent/null
// params (leaving dst at its zero value) since methods may take no params.
func unmarshalParams(raw json.RawMessage, dst any) error {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	return json.Unmarshal(raw, dst)
}

// normalizeArgs maps an absent/null arguments payload to nil so a tool's decoder
// sees "no args" rather than a stray empty slice.
func normalizeArgs(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	return raw
}

// schemaOrEmpty returns a tool's schema, substituting a permissive empty-object
// schema when the tool advertised none (MCP requires inputSchema to be present).
func schemaOrEmpty(s json.RawMessage) json.RawMessage {
	if len(s) == 0 || string(s) == "null" {
		return json.RawMessage(`{"type":"object"}`)
	}
	return s
}

// rawJSON marshals v into a json.RawMessage for use as error Data, dropping the
// value on the (unlikely) marshal failure.
func rawJSON(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		return nil
	}
	return b
}
