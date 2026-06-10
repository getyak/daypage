package mcp

import "encoding/json"

// This file declares the small slice of the MCP application schema we use, on
// top of the JSON-RPC framing in jsonrpc.go. Only three methods matter for our
// purposes:
//
//	initialize        handshake: exchange protocol version + capabilities.
//	tools/list        enumerate the server's tools (name, description, schema).
//	tools/call        invoke a named tool with JSON arguments; get content back.
//
// Plus one notification the client sends after a successful initialize:
//
//	notifications/initialized
//
// The field shapes below mirror the MCP specification (2024-11-05 revision).
// Anything the spec defines that we don't consume is simply omitted — unknown
// JSON fields are ignored on decode, so we interoperate with richer peers.

// ProtocolVersion is the MCP revision we *prefer*: the version the client
// advertises in initialize and the server's fallback when a peer requests a
// version we don't recognize. Peers that send a different *known* version are
// honored (see NegotiateProtocolVersion); unknown versions fall back here,
// matching the spec's "be liberal in what you accept" guidance.
const ProtocolVersion = "2024-11-05"

// SupportedProtocolVersions lists every MCP protocol revision this
// implementation can speak, newest first. The wire schema we use (initialize /
// tools/list / tools/call) is stable across these revisions, so we can safely
// agree to any of them when a client asks. Ordering is informational; the
// negotiation rule only checks membership.
//
// Keeping this as a small allow-list (rather than echoing back whatever string
// the client sent) means we never claim to support a revision we've never heard
// of, while still interoperating with current clients — many of which negotiate
// 2025-03-26 or 2025-06-18 and expect that exact version echoed back.
var SupportedProtocolVersions = []string{
	"2025-06-18",
	"2025-03-26",
	"2024-11-05",
}

// NegotiateProtocolVersion implements the MCP initialize version-negotiation
// rule from the server's perspective: if the client's requested version is one
// we support, echo it back verbatim; otherwise respond with our preferred
// version (ProtocolVersion) so the client can decide whether to proceed or
// disconnect. An empty/absent request (older or minimal clients) also yields the
// preferred version.
func NegotiateProtocolVersion(requested string) string {
	if requested == "" {
		return ProtocolVersion
	}
	for _, v := range SupportedProtocolVersions {
		if v == requested {
			return requested
		}
	}
	return ProtocolVersion
}

// Method names.
const (
	MethodInitialize  = "initialize"
	MethodInitialized = "notifications/initialized"
	MethodToolsList   = "tools/list"
	MethodToolsCall   = "tools/call"
)

// Implementation identifies a party in the handshake (client or server).
type Implementation struct {
	Name    string `json:"name"`
	Version string `json:"version"`
}

// InitializeParams is the client's "initialize" request payload.
type InitializeParams struct {
	ProtocolVersion string         `json:"protocolVersion"`
	Capabilities    Capabilities   `json:"capabilities"`
	ClientInfo      Implementation `json:"clientInfo"`
}

// InitializeResult is the server's "initialize" reply.
type InitializeResult struct {
	ProtocolVersion string         `json:"protocolVersion"`
	Capabilities    Capabilities   `json:"capabilities"`
	ServerInfo      Implementation `json:"serverInfo"`
}

// Capabilities is a coarse capability bag. We only ever populate/inspect the
// tools capability; other members are accepted but ignored. Using
// json.RawMessage keeps us forward-compatible without modeling the whole tree.
type Capabilities struct {
	Tools     *ToolsCapability `json:"tools,omitempty"`
	Resources json.RawMessage  `json:"resources,omitempty"`
	Prompts   json.RawMessage  `json:"prompts,omitempty"`
}

// ToolsCapability signals tool support. listChanged indicates the server can
// notify on tool-set changes; we advertise false (our set is static per run).
type ToolsCapability struct {
	ListChanged bool `json:"listChanged,omitempty"`
}

// ToolDescriptor is one entry in a tools/list result. InputSchema is the JSON
// Schema for the tool's arguments — the MCP analogue of provider.ToolSpec.Schema
// and tool.Tool.Schema().
type ToolDescriptor struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"inputSchema"`
}

// ListToolsResult is the "tools/list" reply.
type ListToolsResult struct {
	Tools []ToolDescriptor `json:"tools"`
}

// CallToolParams is the "tools/call" request payload. Arguments is an arbitrary
// JSON object the tool defines; we pass the model's raw args straight through.
type CallToolParams struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments,omitempty"`
}

// CallToolResult is the "tools/call" reply: a list of content blocks plus an
// error flag. We only emit/consume text blocks; richer block types (image,
// resource) decode into Content with their Type preserved and are rendered as a
// best-effort string by Text().
type CallToolResult struct {
	Content []Content `json:"content"`
	IsError bool      `json:"isError,omitempty"`
}

// Content is one block of a tool result. For type=="text" the Text field holds
// the payload; other types keep whatever fields the peer sent (we surface Text
// when present and otherwise note the block type).
type Content struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
	// Data/MimeType appear on non-text blocks (e.g. images); kept so they
	// round-trip and so Text() can mention them rather than dropping silently.
	Data     string `json:"data,omitempty"`
	MimeType string `json:"mimeType,omitempty"`
}

// TextContent is a convenience constructor for a text content block.
func TextContent(s string) Content { return Content{Type: "text", Text: s} }

// Text flattens a CallToolResult's content blocks into a single string. Text
// blocks contribute their text; non-text blocks contribute a short placeholder
// so information about their presence is not lost. Blocks are joined by newlines.
func (r CallToolResult) Text() string {
	if len(r.Content) == 0 {
		return ""
	}
	var b []byte
	for i, c := range r.Content {
		if i > 0 {
			b = append(b, '\n')
		}
		switch {
		case c.Type == "text" || c.Text != "":
			b = append(b, c.Text...)
		case c.MimeType != "":
			b = append(b, "["+c.Type+" content: "+c.MimeType+"]"...)
		default:
			b = append(b, "["+c.Type+" content]"...)
		}
	}
	return string(b)
}
