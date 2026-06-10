package mcp

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/kubbot/agentry/internal/core/tool"
)

// toolInput builds a tool.Input carrying the given raw JSON args (no session).
func toolInput(args string) tool.Input {
	return tool.Input{Args: json.RawMessage(args)}
}

// This file end-to-end tests the MCP client against a real subprocess. The test
// binary re-execs itself in a "fake MCP server" mode (selected by an env var)
// that speaks just enough of the protocol — initialize, tools/list, tools/call —
// to validate Connect, AsTools, and proxied Invoke over actual stdio pipes.

const fakeServerEnv = "AGENTRY_MCP_FAKE_SERVER"

// TestMain lets the test binary double as a fake MCP server subprocess when the
// env flag is set; otherwise it runs the normal test suite.
func TestMain(m *testing.M) {
	if os.Getenv(fakeServerEnv) != "" {
		runFakeServer()
		return
	}
	os.Exit(m.Run())
}

// runFakeServer implements a minimal MCP server over stdio: it answers
// initialize, advertises one "echo" tool, and echoes tools/call arguments back
// as text. Unknown methods get a method-not-found error. It exits at EOF.
func runFakeServer() {
	conn := NewConn(os.Stdin, os.Stdout)
	for {
		msg, err := conn.Read()
		if err != nil {
			return // EOF or parse error: stop.
		}
		if msg.IsNotification() {
			continue // e.g. notifications/initialized — nothing to answer.
		}
		switch msg.Method {
		case MethodInitialize:
			res, _ := NewResult(msg.ID, InitializeResult{
				ProtocolVersion: ProtocolVersion,
				Capabilities:    Capabilities{Tools: &ToolsCapability{}},
				ServerInfo:      Implementation{Name: "fake", Version: "1.0"},
			})
			_ = conn.Write(res)
		case MethodToolsList:
			res, _ := NewResult(msg.ID, ListToolsResult{Tools: []ToolDescriptor{{
				Name:        "echo",
				Description: "echo back the provided text",
				InputSchema: json.RawMessage(`{"type":"object","properties":{"text":{"type":"string"}}}`),
			}}})
			_ = conn.Write(res)
		case MethodToolsCall:
			var p CallToolParams
			_ = json.Unmarshal(msg.Params, &p)
			if p.Name != "echo" {
				_ = conn.Write(NewErrorResponse(msg.ID, CodeMethodNotFound, "no such tool", nil))
				continue
			}
			var args struct {
				Text string `json:"text"`
			}
			_ = json.Unmarshal(p.Arguments, &args)
			res, _ := NewResult(msg.ID, CallToolResult{
				Content: []Content{TextContent("echo: " + args.Text)},
			})
			_ = conn.Write(res)
		default:
			_ = conn.Write(NewErrorResponse(msg.ID, CodeMethodNotFound, "method not found", nil))
		}
	}
}

// TestClientConnectAndInvoke drives the full client path: spawn the fake server,
// handshake + discover tools, wrap them as local tools, and proxy an Invoke.
func TestClientConnectAndInvoke(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	// Re-exec this test binary in fake-server mode.
	self, err := os.Executable()
	if err != nil {
		t.Fatalf("os.Executable: %v", err)
	}
	c, err := connectWithEnv(ctx, self, nil, []string{fakeServerEnv + "=1"})
	if err != nil {
		t.Fatalf("Connect: %v", err)
	}
	defer c.Close()

	tools := c.AsTools()
	if len(tools) != 1 {
		t.Fatalf("AsTools returned %d tools, want 1", len(tools))
	}
	et := tools[0]
	if et.Name() != "echo" {
		t.Errorf("tool name = %q, want echo", et.Name())
	}
	if et.Description() == "" {
		t.Errorf("tool description is empty")
	}
	// Schema should be the server's, not the empty-object fallback.
	if string(et.Schema()) == `{"type":"object"}` {
		t.Errorf("expected the server's input schema, got the fallback")
	}

	res, err := et.Invoke(ctx, toolInput(`{"text":"world"}`))
	if err != nil {
		t.Fatalf("Invoke: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error result: %q", res.Content)
	}
	if res.Content != "echo: world" {
		t.Errorf("Content = %q, want %q", res.Content, "echo: world")
	}
}

// TestClientInvokeAfterCloseErrors confirms a proxied call after Close yields a
// model-visible error result rather than hanging or panicking.
func TestClientInvokeAfterCloseErrors(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	self, err := os.Executable()
	if err != nil {
		t.Fatalf("os.Executable: %v", err)
	}
	c, err := connectWithEnv(ctx, self, nil, []string{fakeServerEnv + "=1"})
	if err != nil {
		t.Fatalf("Connect: %v", err)
	}
	tools := c.AsTools()
	_ = c.Close()

	res, err := tools[0].Invoke(ctx, toolInput(`{"text":"x"}`))
	if err != nil {
		t.Fatalf("Invoke returned a Go error; expected an error Result: %v", err)
	}
	if !res.IsError {
		t.Errorf("expected IsError after Close, got %+v", res)
	}
}
