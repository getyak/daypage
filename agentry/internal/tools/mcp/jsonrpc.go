// Package mcp implements the Model Context Protocol (MCP) — both the client side
// (Agentry connecting out to a third-party MCP server to borrow its tools) and
// the shared JSON-RPC 2.0 framing used by the matching server transport.
//
// We deliberately do NOT depend on any MCP SDK. MCP is, at the wire level, just
// JSON-RPC 2.0 with a small, well-known method vocabulary
// (initialize / tools/list / tools/call). Implementing exactly the subset we
// need keeps the dependency surface at zero and the behavior auditable.
//
// This file holds the codec — the JSON-RPC 2.0 message types plus a Conn that
// frames those messages over an io.Reader/io.Writer pair (one JSON object per
// line). It is consumed by the MCP client in this package and re-exported for
// the MCP server transport, so both directions speak an identical framing.
package mcp

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"sync"
)

// JSON-RPC 2.0 standard error codes (spec §5.1). Using the documented values
// lets any conformant peer classify failures.
const (
	CodeParseError     = -32700 // invalid JSON was received
	CodeInvalidRequest = -32600 // the JSON sent is not a valid Request object
	CodeMethodNotFound = -32601 // the method does not exist / is not available
	CodeInvalidParams  = -32602 // invalid method parameter(s)
	CodeInternalError  = -32603 // internal error while handling the request
)

// JSONRPCVersion is the only protocol version this codec speaks.
const JSONRPCVersion = "2.0"

// maxLineBytes caps a single inbound line so a hostile or buggy peer cannot make
// us buffer unbounded memory while scanning for a newline. 16 MiB is far larger
// than any realistic tool payload yet still bounded.
const maxLineBytes = 16 << 20

// Message is a single JSON-RPC 2.0 frame. It is intentionally permissive: the
// same struct models a request, a response, and a notification, so one Conn can
// read whichever the peer sent and a handler can pick fields by presence.
//
//   - Request:      ID present, Method set, Result/Error absent.
//   - Notification: ID absent, Method set.
//   - Response:     ID present, exactly one of Result/Error set, Method empty.
//
// ID is kept as a raw message so it round-trips verbatim (number, string, or
// null) and so an absent id (notification) is distinguishable from id:null.
type Message struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *RPCError       `json:"error,omitempty"`
}

// IsNotification reports whether m is a notification (a request with no id).
func (m *Message) IsNotification() bool { return len(m.ID) == 0 && m.Method != "" }

// IsRequest reports whether m is a request expecting a response (has both an id
// and a method).
func (m *Message) IsRequest() bool { return len(m.ID) != 0 && m.Method != "" }

// RPCError is the JSON-RPC 2.0 error object.
type RPCError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

// Error implements the error interface so an RPCError can be returned directly.
func (e *RPCError) Error() string {
	if e == nil {
		return "<nil rpc error>"
	}
	return fmt.Sprintf("jsonrpc error %d: %s", e.Code, e.Message)
}

// NewRequest builds a request frame with the given id, method, and params.
// params may be nil for parameterless methods.
func NewRequest(id json.RawMessage, method string, params any) (Message, error) {
	raw, err := marshalParams(params)
	if err != nil {
		return Message{}, err
	}
	return Message{JSONRPC: JSONRPCVersion, ID: id, Method: method, Params: raw}, nil
}

// NewNotification builds a notification frame (no id) for the given method.
func NewNotification(method string, params any) (Message, error) {
	raw, err := marshalParams(params)
	if err != nil {
		return Message{}, err
	}
	return Message{JSONRPC: JSONRPCVersion, Method: method, Params: raw}, nil
}

// NewResult builds a success response echoing id and carrying result.
func NewResult(id json.RawMessage, result any) (Message, error) {
	raw, err := json.Marshal(result)
	if err != nil {
		return Message{}, err
	}
	return Message{JSONRPC: JSONRPCVersion, ID: id, Result: raw}, nil
}

// NewErrorResponse builds an error response echoing id and carrying err.
func NewErrorResponse(id json.RawMessage, code int, message string, data any) Message {
	e := &RPCError{Code: code, Message: message}
	if data != nil {
		if raw, err := json.Marshal(data); err == nil {
			e.Data = raw
		}
	}
	return Message{JSONRPC: JSONRPCVersion, ID: id, Error: e}
}

// marshalParams encodes params to a raw JSON message, mapping nil to an omitted
// (nil) payload rather than the literal "null".
func marshalParams(params any) (json.RawMessage, error) {
	if params == nil {
		return nil, nil
	}
	return json.Marshal(params)
}

// Conn frames JSON-RPC 2.0 Messages over a reader/writer pair as one JSON object
// per line (newline-delimited, the framing MCP stdio servers use). It is safe
// for one reader goroutine and concurrent writers: writes are serialized so two
// frames never interleave mid-line.
type Conn struct {
	r   *bufio.Scanner
	w   io.Writer
	enc *json.Encoder
	mu  sync.Mutex // serializes writes
}

// NewConn wraps r/w in a Conn. The reader is scanned line by line with a bounded
// buffer; the writer receives newline-terminated JSON (json.Encoder appends the
// newline, satisfying the framing).
func NewConn(r io.Reader, w io.Writer) *Conn {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), maxLineBytes)
	return &Conn{r: sc, w: w, enc: json.NewEncoder(w)}
}

// Read returns the next framed Message, skipping blank keep-alive lines. It
// returns io.EOF when the peer closes the stream. A line that is not valid JSON
// yields an error (the caller decides whether to surface a parse-error response
// or terminate).
func (c *Conn) Read() (Message, error) {
	for c.r.Scan() {
		line := c.r.Bytes()
		if len(trimSpaceBytes(line)) == 0 {
			continue // ignore blank lines
		}
		// Copy: the scanner reuses its buffer on the next Scan, but the decoded
		// Message holds sub-slices (Params/Result) into this memory.
		buf := make([]byte, len(line))
		copy(buf, line)
		var m Message
		if err := json.Unmarshal(buf, &m); err != nil {
			return Message{}, &parseError{err: err}
		}
		return m, nil
	}
	if err := c.r.Err(); err != nil {
		return Message{}, err
	}
	return Message{}, io.EOF
}

// Write encodes m as a single line under the write mutex so concurrent writes
// never tear a frame.
func (c *Conn) Write(m Message) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.enc.Encode(m)
}

// parseError marks a line that could not be decoded as JSON, so a server can
// answer with a JSON-RPC parse error rather than dropping the connection.
type parseError struct{ err error }

func (e *parseError) Error() string { return "jsonrpc: parse error: " + e.err.Error() }

// IsParseError reports whether err is a codec-level JSON parse failure.
func IsParseError(err error) bool {
	_, ok := err.(*parseError)
	return ok
}

// trimSpaceBytes reports b with leading/trailing ASCII whitespace removed,
// used only to detect blank lines without allocating a string.
func trimSpaceBytes(b []byte) []byte {
	start := 0
	for start < len(b) && isASCIISpace(b[start]) {
		start++
	}
	end := len(b)
	for end > start && isASCIISpace(b[end-1]) {
		end--
	}
	return b[start:end]
}

func isASCIISpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f'
}
