package mcpserver

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/kubbot/agentry/internal/core/agent"
	"github.com/kubbot/agentry/internal/core/provider/mock"
	"github.com/kubbot/agentry/internal/core/tool"
	"github.com/kubbot/agentry/internal/tools/mcp"
)

// echoTool is a tiny in-test tool used to exercise tools/call without depending
// on the builtin package's filesystem/shell behavior.
type echoTool struct{}

func (echoTool) Name() string        { return "echo" }
func (echoTool) Description() string { return "echo back the provided text" }
func (echoTool) Schema() json.RawMessage {
	return json.RawMessage(`{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}`)
}
func (echoTool) Invoke(_ context.Context, in tool.Input) (tool.Result, error) {
	var args struct {
		Text string `json:"text"`
	}
	_ = json.Unmarshal(in.Args, &args)
	return tool.Result{Content: "echo: " + args.Text}, nil
}

// failTool always returns an error result, to verify isError propagation.
type failTool struct{}

func (failTool) Name() string            { return "fail" }
func (failTool) Description() string     { return "always fails" }
func (failTool) Schema() json.RawMessage { return json.RawMessage(`{"type":"object"}`) }
func (failTool) Invoke(context.Context, tool.Input) (tool.Result, error) {
	return tool.Result{Content: "kaboom", IsError: true}, nil
}

// newTestEngine builds an Engine with a mock provider and a registry holding the
// echo + fail tools.
func newTestEngine(t *testing.T) *agent.Engine {
	t.Helper()
	reg := tool.NewRegistry()
	reg.MustRegister(echoTool{})
	reg.MustRegister(failTool{})
	return agent.New(mock.New(), reg, nil, "test-model")
}

// runServer feeds the newline-delimited input through serve and returns the
// decoded response frames (in order).
func runServer(t *testing.T, eng *agent.Engine, input string) []mcp.Message {
	t.Helper()
	var out bytes.Buffer
	if err := serve(context.Background(), eng, strings.NewReader(input), &out); err != nil {
		t.Fatalf("serve: %v", err)
	}
	var msgs []mcp.Message
	dec := json.NewDecoder(&out)
	for dec.More() {
		var m mcp.Message
		if err := dec.Decode(&m); err != nil {
			t.Fatalf("decode response: %v", err)
		}
		msgs = append(msgs, m)
	}
	return msgs
}

// line marshals a JSON-RPC request to a single wire line.
func line(t *testing.T, id any, method string, params any) string {
	t.Helper()
	m := map[string]any{"jsonrpc": "2.0", "method": method}
	if id != nil {
		m["id"] = id
	}
	if params != nil {
		m["params"] = params
	}
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	return string(b) + "\n"
}

// TestInitializeHandshake checks the initialize reply advertises our protocol
// version and a tools capability, and that the initialized notification draws no
// response.
func TestInitializeHandshake(t *testing.T) {
	eng := newTestEngine(t)
	in := line(t, 1, mcp.MethodInitialize, mcp.InitializeParams{ProtocolVersion: mcp.ProtocolVersion}) +
		line(t, nil, mcp.MethodInitialized, nil) // notification: no reply expected

	msgs := runServer(t, eng, in)
	if len(msgs) != 1 {
		t.Fatalf("got %d responses, want 1 (notification must not be answered)", len(msgs))
	}
	var res mcp.InitializeResult
	if err := json.Unmarshal(msgs[0].Result, &res); err != nil {
		t.Fatalf("decode initialize result: %v", err)
	}
	if res.ProtocolVersion != mcp.ProtocolVersion {
		t.Errorf("protocolVersion = %q, want %q", res.ProtocolVersion, mcp.ProtocolVersion)
	}
	if res.Capabilities.Tools == nil {
		t.Errorf("expected a tools capability in the handshake")
	}
	if res.ServerInfo.Name == "" {
		t.Errorf("expected serverInfo.name to be set")
	}
}

// TestInitializeNegotiatesVersion checks the server honors the MCP lifecycle
// rule: a supported client version is echoed back verbatim, an unknown one is
// answered with the server's preferred version, and an initialize with no params
// still produces a valid handshake (the preferred version) rather than erroring.
func TestInitializeNegotiatesVersion(t *testing.T) {
	cases := []struct {
		name      string
		params    any // nil => omit params entirely
		requested string
		want      string
	}{
		{
			name:      "supported newer version echoed",
			params:    mcp.InitializeParams{ProtocolVersion: "2025-03-26"},
			requested: "2025-03-26",
			want:      "2025-03-26",
		},
		{
			name:      "newest supported version echoed",
			params:    mcp.InitializeParams{ProtocolVersion: "2025-06-18"},
			requested: "2025-06-18",
			want:      "2025-06-18",
		},
		{
			name:      "unknown version falls back to preferred",
			params:    mcp.InitializeParams{ProtocolVersion: "2099-12-31"},
			requested: "2099-12-31",
			want:      mcp.ProtocolVersion,
		},
		{
			name:      "absent params still handshake at preferred",
			params:    nil,
			requested: "(none)",
			want:      mcp.ProtocolVersion,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			eng := newTestEngine(t)
			msgs := runServer(t, eng, line(t, 1, mcp.MethodInitialize, tc.params))
			if len(msgs) != 1 {
				t.Fatalf("got %d responses, want 1", len(msgs))
			}
			if msgs[0].Error != nil {
				t.Fatalf("initialize errored: %+v", msgs[0].Error)
			}
			var res mcp.InitializeResult
			if err := json.Unmarshal(msgs[0].Result, &res); err != nil {
				t.Fatalf("decode initialize result: %v", err)
			}
			if res.ProtocolVersion != tc.want {
				t.Errorf("requested %s: protocolVersion = %q, want %q", tc.requested, res.ProtocolVersion, tc.want)
			}
			// Capabilities must remain advertised regardless of negotiated version.
			if res.Capabilities.Tools == nil {
				t.Errorf("requested %s: tools capability missing from handshake", tc.requested)
			}
		})
	}
}

// TestToolsList enumerates the registry, mapping schema to inputSchema.
func TestToolsList(t *testing.T) {
	eng := newTestEngine(t)
	msgs := runServer(t, eng, line(t, 2, mcp.MethodToolsList, nil))
	if len(msgs) != 1 {
		t.Fatalf("got %d responses, want 1", len(msgs))
	}
	var res mcp.ListToolsResult
	if err := json.Unmarshal(msgs[0].Result, &res); err != nil {
		t.Fatalf("decode tools/list: %v", err)
	}
	// Registry.List() is name-sorted: echo, fail.
	if len(res.Tools) != 2 {
		t.Fatalf("got %d tools, want 2: %+v", len(res.Tools), res.Tools)
	}
	if res.Tools[0].Name != "echo" || res.Tools[1].Name != "fail" {
		t.Errorf("tool order = [%s,%s], want [echo,fail]", res.Tools[0].Name, res.Tools[1].Name)
	}
	if len(res.Tools[0].InputSchema) == 0 {
		t.Errorf("echo inputSchema is empty")
	}
}

// TestToolsCallSuccess invokes echo and checks the text content comes back.
func TestToolsCallSuccess(t *testing.T) {
	eng := newTestEngine(t)
	params := mcp.CallToolParams{Name: "echo", Arguments: json.RawMessage(`{"text":"hi"}`)}
	msgs := runServer(t, eng, line(t, 3, mcp.MethodToolsCall, params))
	if len(msgs) != 1 {
		t.Fatalf("got %d responses, want 1", len(msgs))
	}
	var res mcp.CallToolResult
	if err := json.Unmarshal(msgs[0].Result, &res); err != nil {
		t.Fatalf("decode tools/call: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected isError: %+v", res)
	}
	if got := res.Text(); got != "echo: hi" {
		t.Errorf("content = %q, want %q", got, "echo: hi")
	}
}

// TestToolsCallErrorResult confirms a tool-level error surfaces as a successful
// JSON-RPC response carrying isError:true (not a transport error).
func TestToolsCallErrorResult(t *testing.T) {
	eng := newTestEngine(t)
	msgs := runServer(t, eng, line(t, 4, mcp.MethodToolsCall, mcp.CallToolParams{Name: "fail"}))
	if len(msgs) != 1 {
		t.Fatalf("got %d responses, want 1", len(msgs))
	}
	if msgs[0].Error != nil {
		t.Fatalf("expected a result, got JSON-RPC error %+v", msgs[0].Error)
	}
	var res mcp.CallToolResult
	if err := json.Unmarshal(msgs[0].Result, &res); err != nil {
		t.Fatalf("decode tools/call: %v", err)
	}
	if !res.IsError {
		t.Errorf("expected isError:true, got %+v", res)
	}
}

// TestToolsCallSchemaValidation confirms the server validates a tools/call's
// arguments against the tool's advertised input schema before invoking: a call
// missing a required field (and carrying a disallowed extra one) comes back as a
// successful JSON-RPC response with isError:true and a field-anchored message,
// and the tool's own output ("echo: ...") never appears (it was not invoked).
func TestToolsCallSchemaValidation(t *testing.T) {
	eng := newTestEngine(t)
	// echo's schema requires "text"; omit it.
	params := mcp.CallToolParams{Name: "echo", Arguments: json.RawMessage(`{"nope":1}`)}
	msgs := runServer(t, eng, line(t, 8, mcp.MethodToolsCall, params))
	if len(msgs) != 1 {
		t.Fatalf("got %d responses, want 1", len(msgs))
	}
	if msgs[0].Error != nil {
		t.Fatalf("expected a result (isError), got JSON-RPC error %+v", msgs[0].Error)
	}
	var res mcp.CallToolResult
	if err := json.Unmarshal(msgs[0].Result, &res); err != nil {
		t.Fatalf("decode tools/call: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected isError:true for a schema-invalid call, got %+v", res)
	}
	txt := res.Text()
	if !strings.Contains(txt, "invalid arguments") || !strings.Contains(txt, `missing required property "text"`) {
		t.Fatalf("validation message missing expected detail; got:\n%s", txt)
	}
	if strings.Contains(txt, "echo:") {
		t.Fatalf("tool appears to have run despite invalid args; got:\n%s", txt)
	}
}

// TestUnknownToolIsMethodError checks an unknown tool name yields a JSON-RPC
// method-not-found error.
func TestUnknownToolIsMethodError(t *testing.T) {
	eng := newTestEngine(t)
	msgs := runServer(t, eng, line(t, 5, mcp.MethodToolsCall, mcp.CallToolParams{Name: "nope"}))
	if len(msgs) != 1 {
		t.Fatalf("got %d responses, want 1", len(msgs))
	}
	if msgs[0].Error == nil || msgs[0].Error.Code != mcp.CodeMethodNotFound {
		t.Errorf("expected method-not-found error, got %+v", msgs[0])
	}
}

// TestUnknownMethod and a malformed line both yield errors without crashing.
func TestUnknownMethodAndParseError(t *testing.T) {
	eng := newTestEngine(t)
	in := line(t, 6, "bogus/method", nil) +
		"this is not json\n" +
		line(t, 7, mcp.MethodToolsList, nil) // still served after the bad line

	msgs := runServer(t, eng, in)
	if len(msgs) != 3 {
		t.Fatalf("got %d responses, want 3", len(msgs))
	}
	if msgs[0].Error == nil || msgs[0].Error.Code != mcp.CodeMethodNotFound {
		t.Errorf("response0: expected method-not-found, got %+v", msgs[0])
	}
	if msgs[1].Error == nil || msgs[1].Error.Code != mcp.CodeParseError {
		t.Errorf("response1: expected parse error, got %+v", msgs[1])
	}
	if string(msgs[1].ID) != "null" {
		t.Errorf("response1: parse-error id = %s, want null", msgs[1].ID)
	}
	// The third request still succeeds: a bad line does not kill the server.
	if msgs[2].Error != nil || len(msgs[2].Result) == 0 {
		t.Errorf("response2: expected a tools/list result, got %+v", msgs[2])
	}
}
