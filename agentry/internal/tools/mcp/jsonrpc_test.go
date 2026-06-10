package mcp

import (
	"encoding/json"
	"io"
	"strings"
	"testing"
)

// TestConnRoundtrip verifies that frames written by one Conn are read back
// faithfully by another over a pipe — the core framing contract both MCP
// directions rely on. It exercises a request, a notification, a success
// response, and an error response.
func TestConnRoundtrip(t *testing.T) {
	pr, pw := io.Pipe()
	// Writer Conn writes into pw; reader Conn reads from pr.
	w := NewConn(strings.NewReader(""), pw)
	r := NewConn(pr, io.Discard)

	// A request with structured params.
	req, err := NewRequest(json.RawMessage("1"), MethodToolsCall, CallToolParams{
		Name:      "echo",
		Arguments: json.RawMessage(`{"text":"hi"}`),
	})
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}
	// A notification (no id).
	note, err := NewNotification(MethodInitialized, struct{}{})
	if err != nil {
		t.Fatalf("NewNotification: %v", err)
	}
	// A success response.
	ok, err := NewResult(json.RawMessage(`"abc"`), ListToolsResult{Tools: []ToolDescriptor{{Name: "t"}}})
	if err != nil {
		t.Fatalf("NewResult: %v", err)
	}
	// An error response.
	bad := NewErrorResponse(json.RawMessage("2"), CodeInvalidParams, "boom", map[string]string{"k": "v"})

	frames := []Message{req, note, ok, bad}
	go func() {
		for _, f := range frames {
			if werr := w.Write(f); werr != nil {
				t.Errorf("write: %v", werr)
			}
		}
		_ = pw.Close()
	}()

	var got []Message
	for {
		m, rerr := r.Read()
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			t.Fatalf("read: %v", rerr)
		}
		got = append(got, m)
	}

	if len(got) != len(frames) {
		t.Fatalf("got %d frames, want %d", len(got), len(frames))
	}

	// Frame 0: request classification + params survive.
	if !got[0].IsRequest() || got[0].IsNotification() {
		t.Errorf("frame0: expected a request, got %+v", got[0])
	}
	if got[0].Method != MethodToolsCall {
		t.Errorf("frame0: method = %q, want %q", got[0].Method, MethodToolsCall)
	}
	var cp CallToolParams
	if err := json.Unmarshal(got[0].Params, &cp); err != nil {
		t.Fatalf("frame0: decode params: %v", err)
	}
	if cp.Name != "echo" || string(cp.Arguments) != `{"text":"hi"}` {
		t.Errorf("frame0: params = %+v", cp)
	}

	// Frame 1: notification classification.
	if !got[1].IsNotification() || got[1].IsRequest() {
		t.Errorf("frame1: expected a notification, got %+v", got[1])
	}
	if got[1].Method != MethodInitialized {
		t.Errorf("frame1: method = %q, want %q", got[1].Method, MethodInitialized)
	}

	// Frame 2: success response with a string id and a decodable result.
	if got[2].Method != "" || got[2].Error != nil || len(got[2].Result) == 0 {
		t.Errorf("frame2: expected a success response, got %+v", got[2])
	}
	if string(got[2].ID) != `"abc"` {
		t.Errorf("frame2: id = %s, want \"abc\"", got[2].ID)
	}
	var lr ListToolsResult
	if err := json.Unmarshal(got[2].Result, &lr); err != nil {
		t.Fatalf("frame2: decode result: %v", err)
	}
	if len(lr.Tools) != 1 || lr.Tools[0].Name != "t" {
		t.Errorf("frame2: result = %+v", lr)
	}

	// Frame 3: error response carries code/message/data.
	if got[3].Error == nil {
		t.Fatalf("frame3: expected an error response, got %+v", got[3])
	}
	if got[3].Error.Code != CodeInvalidParams || got[3].Error.Message != "boom" {
		t.Errorf("frame3: error = %+v", got[3].Error)
	}
	if string(got[3].ID) != "2" {
		t.Errorf("frame3: id = %s, want 2", got[3].ID)
	}
}

// TestConnSkipsBlankLines confirms the reader ignores blank keep-alive lines
// between frames rather than erroring on them.
func TestConnSkipsBlankLines(t *testing.T) {
	in := "\n\n" + `{"jsonrpc":"2.0","id":1,"method":"ping"}` + "\n\n"
	r := NewConn(strings.NewReader(in), io.Discard)

	m, err := r.Read()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if m.Method != "ping" || string(m.ID) != "1" {
		t.Errorf("got %+v", m)
	}
	if _, err := r.Read(); err != io.EOF {
		t.Errorf("expected EOF after the single frame, got %v", err)
	}
}

// TestConnParseError surfaces a typed parse error for non-JSON input so a server
// can answer with a JSON-RPC parse error instead of dropping the connection.
func TestConnParseError(t *testing.T) {
	r := NewConn(strings.NewReader("this is not json\n"), io.Discard)
	_, err := r.Read()
	if err == nil {
		t.Fatal("expected a parse error, got nil")
	}
	if !IsParseError(err) {
		t.Errorf("IsParseError = false for %v", err)
	}
}

// TestCallToolResultText flattens mixed content blocks, preserving text and
// noting non-text blocks rather than dropping them.
func TestCallToolResultText(t *testing.T) {
	r := CallToolResult{Content: []Content{
		TextContent("hello"),
		{Type: "image", MimeType: "image/png", Data: "..."},
		TextContent("world"),
	}}
	got := r.Text()
	want := "hello\n[image content: image/png]\nworld"
	if got != want {
		t.Errorf("Text() = %q, want %q", got, want)
	}

	if (CallToolResult{}).Text() != "" {
		t.Errorf("empty result should flatten to empty string")
	}
}
