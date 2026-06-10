// Package stdio implements a newline-delimited JSON-RPC 2.0 transport over
// stdin/stdout, the lowest-common-denominator way for other programs and agents
// to drive an agentry Engine (DESIGN §6).
//
// # Wire format
//
// One JSON value per line. Each inbound line is a JSON-RPC 2.0 *request*:
//
//	{"jsonrpc":"2.0","id":1,"method":"session.prompt","params":{"input":"hi"}}
//
// For every request bearing an id, exactly one *response* line is written:
//
//	{"jsonrpc":"2.0","id":1,"result":{...}}            // success
//	{"jsonrpc":"2.0","id":1,"error":{"code":...}}      // failure
//
// While a session.prompt runs, the live session event stream is forwarded as
// JSON-RPC *notifications* (no id) so the caller observes the run as it unfolds:
//
//	{"jsonrpc":"2.0","method":"session.event","params":{<session.Event>}}
//
// Methods
//
//	session.create  {resume?}                    -> {"id": "<session-id>", "resumed": bool}
//	session.list    {}                           -> [{"id","title","model","events","created"}, ...]
//	session.prompt  {session_id?, input}         -> {"text": "<final assistant text>"}
//	                (streams session.event notifications while running)
//	tools.list      {}                           -> [{"name","description"}, ...]
//	agents.list     {}                           -> []   (no named agents in v1)
//
// When a durable store is wired (ServeWithStore), sessions are persisted on
// create and after each prompt, and session.create {"resume":"<id>"} (or a
// session.prompt naming a not-in-memory id) rehydrates a prior conversation —
// so resume survives a process restart (DESIGN §4.4).
//
// Robustness: malformed lines, unknown methods, and bad params never crash the
// server — they yield a JSON-RPC error response (or are skipped when no id is
// recoverable). Writes are serialized so streamed notifications and responses
// never interleave mid-line.
package stdio

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"sync"
	"time"

	"github.com/kubbot/agentry/internal/core/agent"
	"github.com/kubbot/agentry/internal/core/session"
)

// SessionStore is the narrow persistence seam this transport needs: save a
// session's current state, load a previously persisted one by id, and list the
// ids of all persisted sessions (so a client can discover what is resumable). It
// is satisfied by *session.JSONLStore (the on-disk store from DESIGN §4.4) and by
// any in-memory test double; nil disables persistence entirely (sessions then
// live only in the in-memory map for the process lifetime).
type SessionStore interface {
	Save(s *session.Session) error
	Load(id string) (*session.Session, error)
	List() ([]string, error)
}

// JSON-RPC 2.0 standard error codes (see the spec's §5.1). We use the documented
// values so generic JSON-RPC clients can classify failures.
const (
	codeParseError     = -32700 // invalid JSON was received
	codeInvalidRequest = -32600 // the JSON sent is not a valid Request object
	codeMethodNotFound = -32601 // the method does not exist
	codeInvalidParams  = -32602 // invalid method parameter(s)
	codeInternalError  = -32603 // internal JSON-RPC error (e.g. engine failure)
)

// jsonrpcVersion is the only protocol version this transport speaks.
const jsonrpcVersion = "2.0"

// maxLineBytes caps a single inbound line so a hostile or buggy peer cannot make
// the server buffer unbounded memory while scanning for a newline. 8 MiB is far
// larger than any realistic prompt yet still bounded.
const maxLineBytes = 8 << 20

// request is an inbound JSON-RPC 2.0 request. ID is kept as a raw message so we
// can echo it back verbatim (it may be a number, string, or null) without
// committing to a Go type, and so a notification (absent id) is distinguishable
// from id:null.
type request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

// response is an outbound JSON-RPC 2.0 response. Exactly one of Result/Error is
// populated. ID echoes the request id (null when it could not be recovered).
type response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

// notification is an outbound JSON-RPC 2.0 notification (a request with no id).
type notification struct {
	JSONRPC string `json:"jsonrpc"`
	Method  string `json:"method"`
	Params  any    `json:"params,omitempty"`
}

// rpcError is the JSON-RPC 2.0 error object.
type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

// nullID is the literal JSON null, used as the id of error responses for
// requests whose own id could not be parsed.
var nullID = json.RawMessage("null")

// server holds the per-connection state: the engine being driven, the in-memory
// session map, an optional durable store, and a serialized writer so concurrent
// notifications/responses never tear a line.
type server struct {
	eng   *agent.Engine
	store SessionStore // optional; nil => sessions live only in memory

	enc   *json.Encoder
	encMu sync.Mutex // serializes all writes to the underlying stream

	mu       sync.Mutex // guards sessions
	sessions map[string]*session.Session
	nextID   int // monotonic source for generated session ids
}

// Serve reads JSON-RPC requests line by line from os.Stdin and writes
// responses/notifications to os.Stdout until stdin reaches EOF or ctx is
// cancelled. It maintains an in-memory map of sessions for the lifetime of the
// call. It returns nil on a clean EOF, ctx.Err() on cancellation, or a non-EOF
// read error.
//
// Sessions created here are in-memory only; use ServeWithStore to persist and
// resume them across process restarts (DESIGN §4.4).
func Serve(ctx context.Context, eng *agent.Engine) error {
	return serve(ctx, eng, os.Stdin, os.Stdout, nil)
}

// ServeWithStore is Serve plus durable session persistence: every session is
// saved to store after it is created and after each session.prompt completes,
// and a session.create with {"resume":"<id>"} (or a session.prompt naming an id
// not held in memory) loads the prior session from store so a conversation
// survives a process restart. A nil store behaves exactly like Serve.
func ServeWithStore(ctx context.Context, eng *agent.Engine, store SessionStore) error {
	return serve(ctx, eng, os.Stdin, os.Stdout, store)
}

// serve is the testable core of Serve, parameterized over its streams (so a test
// can feed canned input and capture output without touching the process stdio)
// and its store (so persistence/resume can be exercised against a temp dir).
func serve(ctx context.Context, eng *agent.Engine, in io.Reader, out io.Writer, store SessionStore) error {
	if eng == nil {
		return errors.New("stdio: engine is nil")
	}

	s := &server{
		eng:      eng,
		store:    store,
		enc:      json.NewEncoder(out),
		sessions: map[string]*session.Session{},
	}

	scanner := bufio.NewScanner(in)
	// Grow the scanner's buffer up to maxLineBytes so long-but-legal prompts are
	// accepted while still bounding memory per line.
	scanner.Buffer(make([]byte, 0, 64*1024), maxLineBytes)

	for scanner.Scan() {
		// Stop promptly if the caller cancelled; an in-flight prompt also observes
		// ctx via the engine.
		if err := ctx.Err(); err != nil {
			return err
		}

		line := scanner.Bytes()
		if len(trimSpace(line)) == 0 {
			continue // ignore blank keep-alive lines
		}
		// Copy the line: handleLine may outlive the scanner's internal buffer reuse
		// on the next Scan, and Params is referenced during dispatch.
		buf := make([]byte, len(line))
		copy(buf, line)
		s.handleLine(ctx, buf)
	}

	if err := scanner.Err(); err != nil {
		// A line exceeding maxLineBytes surfaces here as bufio.ErrTooLong. Treat
		// any scan error as a terminal transport failure.
		if ctxErr := ctx.Err(); ctxErr != nil {
			return ctxErr
		}
		return fmt.Errorf("stdio: read: %w", err)
	}
	return nil
}

// handleLine parses one line and dispatches it. Parse and protocol errors are
// reported as JSON-RPC error responses; a line we cannot attribute to any id
// (unparseable JSON) is answered with a null-id error per the spec.
func (s *server) handleLine(ctx context.Context, line []byte) {
	var req request
	if err := json.Unmarshal(line, &req); err != nil {
		// Invalid JSON: we have no id to echo, so respond with id:null.
		s.writeError(nullID, codeParseError, "parse error", err.Error())
		return
	}

	// Validate the envelope. A missing/blank method is an invalid request. We are
	// lenient about the jsonrpc version field (some clients omit it) but reject a
	// present-but-wrong version to catch protocol mismatches early.
	id := normalizeID(req.ID)
	if req.JSONRPC != "" && req.JSONRPC != jsonrpcVersion {
		s.writeError(id, codeInvalidRequest, "unsupported jsonrpc version", req.JSONRPC)
		return
	}
	if req.Method == "" {
		s.writeError(id, codeInvalidRequest, "missing method", nil)
		return
	}

	// A request without an id is a notification: we execute it but emit no
	// response. None of our methods have side effects worth running fire-and-forget
	// except prompt; to keep semantics simple and avoid orphaned streams, we only
	// honor methods that have no required response when called as notifications.
	isNotification := len(req.ID) == 0

	result, rpcErr := s.dispatch(ctx, req)

	if isNotification {
		// Per JSON-RPC 2.0, notifications get no reply — not even on error.
		return
	}
	if rpcErr != nil {
		s.writeErrorObj(id, rpcErr)
		return
	}
	s.writeResult(id, result)
}

// dispatch routes a parsed request to its handler, returning either a result
// payload or a JSON-RPC error. It never panics on bad params.
func (s *server) dispatch(ctx context.Context, req request) (any, *rpcError) {
	switch req.Method {
	case "session.create":
		return s.handleSessionCreate(req)
	case "session.list":
		return s.handleSessionList()
	case "session.prompt":
		return s.handleSessionPrompt(ctx, req)
	case "tools.list":
		return s.handleToolsList()
	case "agents.list":
		// No named agent profiles in v1 (DESIGN §14); advertise an empty list so
		// callers can probe without special-casing.
		return []any{}, nil
	default:
		return nil, &rpcError{Code: codeMethodNotFound, Message: "method not found: " + req.Method}
	}
}

// ---------------------------------------------------------------------------
// Method handlers

// createParams are the accepted parameters for session.create. Resume, when set,
// rehydrates a previously persisted session (by id) instead of minting a new one,
// so a caller can continue a conversation across a process restart. All fields
// are optional; an empty/absent payload creates a fresh session as before.
type createParams struct {
	Resume string `json:"resume"`
}

// sessionCreateResult is the reply to session.create. Resumed reports whether the
// session was rehydrated from the store (true) or freshly created (false), so a
// caller can tell whether prior history is present.
type sessionCreateResult struct {
	ID      string `json:"id"`
	Resumed bool   `json:"resumed"`
}

func (s *server) handleSessionCreate(req request) (any, *rpcError) {
	var p createParams
	if err := unmarshalParams(req.Params, &p); err != nil {
		return nil, &rpcError{Code: codeInvalidParams, Message: "invalid params", Data: err.Error()}
	}

	// Resume path: rehydrate the named session from memory or the durable store.
	if id := p.Resume; id != "" {
		if sess := s.lookupSession(id); sess != nil {
			return sessionCreateResult{ID: sess.ID, Resumed: true}, nil
		}
		if sess, ok := s.loadFromStore(id); ok {
			return sessionCreateResult{ID: sess.ID, Resumed: true}, nil
		}
		// Asked to resume an id we cannot find anywhere: surface it rather than
		// silently creating an empty session under that id, so the caller is not
		// misled into thinking history was restored.
		return nil, &rpcError{Code: codeInvalidParams, Message: "cannot resume unknown session", Data: id}
	}

	sess := s.newSession()
	s.persist(sess) // make the new session visible to `session ls` immediately
	return sessionCreateResult{ID: sess.ID}, nil
}

// sessionSummary is one entry in the session.list reply: enough metadata for a
// client to recognize a session and decide whether to resume it, without
// shipping the whole event log. Events is the number of recorded events;
// Created is the session's creation time (RFC 3339 via time.Time's JSON form).
type sessionSummary struct {
	ID      string    `json:"id"`
	Title   string    `json:"title,omitempty"`
	Model   string    `json:"model,omitempty"`
	Events  int       `json:"events"`
	Created time.Time `json:"created,omitempty"`
}

// handleSessionList enumerates the sessions a client could resume. It returns the
// union of the durable store (when wired) and the in-memory map, deduplicated and
// sorted by id, so a caller can discover resumable conversations instead of
// having to already know an id (the gap left after resume was added). Each entry
// carries lightweight metadata; a store entry that cannot be loaded degrades to
// an id-only summary rather than failing the whole listing.
func (s *server) handleSessionList() (any, *rpcError) {
	// Snapshot the in-memory sessions under the lock.
	s.mu.Lock()
	live := make(map[string]*session.Session, len(s.sessions))
	for id, sess := range s.sessions {
		live[id] = sess
	}
	s.mu.Unlock()

	// Gather the set of ids: persisted (if a store is wired) ∪ in-memory.
	idSet := map[string]struct{}{}
	if s.store != nil {
		if ids, err := s.store.List(); err == nil {
			for _, id := range ids {
				idSet[id] = struct{}{}
			}
		}
		// A List error is non-fatal: we still report the in-memory sessions below
		// rather than failing the whole call.
	}
	for id := range live {
		idSet[id] = struct{}{}
	}

	ids := make([]string, 0, len(idSet))
	for id := range idSet {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	out := make([]sessionSummary, 0, len(ids))
	for _, id := range ids {
		out = append(out, s.summarize(id, live[id]))
	}
	return out, nil
}

// summarize builds a sessionSummary for id, preferring the live in-memory copy
// (most up to date) and otherwise loading from the store. A store load failure
// yields an id-only summary so one unreadable file never sinks the listing.
func (s *server) summarize(id string, live *session.Session) sessionSummary {
	sess := live
	if sess == nil && s.store != nil {
		if loaded, err := s.store.Load(id); err == nil {
			sess = loaded
		}
	}
	if sess == nil {
		return sessionSummary{ID: id}
	}
	return sessionSummary{
		ID:      sess.ID,
		Title:   sess.Title,
		Model:   sess.Model,
		Events:  sess.Len(),
		Created: sess.Created(),
	}
}

// promptParams are the accepted parameters for session.prompt. SessionID is
// optional: when absent or unknown, a fresh session is created so a caller can
// fire a one-shot prompt without an explicit create.
type promptParams struct {
	SessionID string `json:"session_id"`
	Input     string `json:"input"`
}

// promptResult is the reply to session.prompt: the final assistant text.
type promptResult struct {
	Text      string `json:"text"`
	SessionID string `json:"session_id"`
}

func (s *server) handleSessionPrompt(ctx context.Context, req request) (any, *rpcError) {
	var p promptParams
	if err := unmarshalParams(req.Params, &p); err != nil {
		return nil, &rpcError{Code: codeInvalidParams, Message: "invalid params", Data: err.Error()}
	}
	if p.Input == "" {
		return nil, &rpcError{Code: codeInvalidParams, Message: "input is required"}
	}

	// Resolve (or lazily create) the target session.
	sess := s.resolveSession(p.SessionID)

	// Forward every event appended during this run as a session.event
	// notification. We subscribe before calling Run so no event is missed, and we
	// drain on a goroutine so a burst of events never blocks the engine (the
	// session's own fan-out is non-blocking, but our writer is not).
	events, unsubscribe := sess.Subscribe()
	defer unsubscribe()

	var (
		done  = make(chan struct{})
		relay sync.WaitGroup
	)
	relay.Add(1)
	go func() {
		defer relay.Done()
		for {
			select {
			case ev, ok := <-events:
				if !ok {
					return
				}
				s.writeNotification("session.event", ev)
			case <-done:
				// Run finished. Drain any events already queued before the
				// subscription is torn down, then exit.
				for {
					select {
					case ev, ok := <-events:
						if !ok {
							return
						}
						s.writeNotification("session.event", ev)
					default:
						return
					}
				}
			}
		}
	}()

	text, err := s.eng.Run(ctx, sess, p.Input)

	close(done)
	relay.Wait()

	// Persist the updated session so the conversation survives a restart and is
	// visible to `agentry session ls|show`. Best-effort: a save failure must not
	// turn a successful run into an error, so it only warns on stderr. We persist
	// even when the run errored, to capture whatever partial history was recorded.
	s.persist(sess)

	if err != nil {
		// An engine failure (provider error, MaxSteps, cancellation) is reported as
		// a JSON-RPC error, but we still include whatever partial text and the
		// session id in Data so the caller can recover context.
		return nil, &rpcError{
			Code:    codeInternalError,
			Message: "engine run failed: " + err.Error(),
			Data:    promptResult{Text: text, SessionID: sess.ID},
		}
	}
	return promptResult{Text: text, SessionID: sess.ID}, nil
}

// toolInfo is one entry in the tools.list reply.
type toolInfo struct {
	Name        string `json:"name"`
	Description string `json:"description"`
}

func (s *server) handleToolsList() (any, *rpcError) {
	out := []toolInfo{} // non-nil so an empty registry marshals as [] not null
	if s.eng.Tools != nil {
		for _, t := range s.eng.Tools.List() {
			out = append(out, toolInfo{Name: t.Name(), Description: t.Description()})
		}
	}
	return out, nil
}

// ---------------------------------------------------------------------------
// Session map

// newSession creates, registers, and returns a fresh session with a generated
// id, seeding its model from the engine so the run uses a sensible default.
func (s *server) newSession() *session.Session {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.nextID++
	id := fmt.Sprintf("s%d", s.nextID)
	sess := session.New(id)
	sess.Model = s.eng.Model
	s.sessions[id] = sess
	return sess
}

// lookupSession returns the in-memory session for id, or nil if none is held.
func (s *server) lookupSession(id string) *session.Session {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.sessions[id]
}

// loadFromStore attempts to rehydrate a session from the durable store and
// register it in memory. It returns the (registered) session and true on
// success, or nil/false when there is no store or no such persisted session. If
// a concurrent request already registered the id, the existing in-memory session
// wins so two callers never drive divergent copies.
func (s *server) loadFromStore(id string) (*session.Session, bool) {
	if s.store == nil {
		return nil, false
	}
	loaded, err := s.store.Load(id)
	if err != nil {
		return nil, false
	}
	if loaded.Model == "" {
		loaded.Model = s.eng.Model
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if existing, ok := s.sessions[id]; ok {
		return existing, true
	}
	s.sessions[id] = loaded
	return loaded, true
}

// resolveSession returns the session named by id, preferring the in-memory copy,
// then the durable store (so a prompt can resume a persisted conversation), and
// finally creating a fresh session under that id. An empty id always mints a new
// session so prompts are never dropped for a missing session.
func (s *server) resolveSession(id string) *session.Session {
	if id == "" {
		return s.newSession()
	}
	if sess := s.lookupSession(id); sess != nil {
		return sess
	}
	if sess, ok := s.loadFromStore(id); ok {
		return sess
	}
	// Unknown id: honor the caller's chosen id rather than inventing one, so a
	// peer that tracks ids client-side stays consistent.
	s.mu.Lock()
	defer s.mu.Unlock()
	// Re-check under the lock in case a concurrent prompt created it.
	if sess, ok := s.sessions[id]; ok {
		return sess
	}
	sess := session.New(id)
	sess.Model = s.eng.Model
	s.sessions[id] = sess
	return sess
}

// persist saves a session to the durable store, best-effort. A nil store is a
// no-op (in-memory mode). A save failure warns on stderr and is otherwise
// swallowed so persistence never turns a successful run into a transport error.
func (s *server) persist(sess *session.Session) {
	if s.store == nil || sess == nil {
		return
	}
	if err := s.store.Save(sess); err != nil {
		fmt.Fprintf(os.Stderr, "stdio: warning: could not persist session %s: %v\n", sess.ID, err)
	}
}

// ---------------------------------------------------------------------------
// Writing (serialized)

// writeResult emits a success response.
func (s *server) writeResult(id json.RawMessage, result any) {
	s.write(response{JSONRPC: jsonrpcVersion, ID: id, Result: result})
}

// writeError emits an error response built from parts.
func (s *server) writeError(id json.RawMessage, code int, message string, data any) {
	s.writeErrorObj(id, &rpcError{Code: code, Message: message, Data: data})
}

// writeErrorObj emits an error response from a prepared rpcError.
func (s *server) writeErrorObj(id json.RawMessage, e *rpcError) {
	s.write(response{JSONRPC: jsonrpcVersion, ID: id, Error: e})
}

// writeNotification emits a notification (no id).
func (s *server) writeNotification(method string, params any) {
	s.write(notification{JSONRPC: jsonrpcVersion, Method: method, Params: params})
}

// write encodes v as a single line under the writer mutex so concurrent
// notifications and responses never interleave mid-line. json.Encoder appends a
// newline, satisfying the newline-delimited framing. Encode failures are
// dropped: stdout is the only sink, so there is nowhere else to report them.
func (s *server) write(v any) {
	s.encMu.Lock()
	defer s.encMu.Unlock()
	_ = s.enc.Encode(v)
}

// ---------------------------------------------------------------------------
// Helpers

// unmarshalParams decodes JSON-RPC params into dst, tolerating absent params
// (an omitted or null params field leaves dst at its zero value rather than
// erroring, since several methods take no params).
func unmarshalParams(raw json.RawMessage, dst any) error {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	return json.Unmarshal(raw, dst)
}

// normalizeID returns a JSON id suitable for echoing in a response: the request
// id verbatim when present, else the literal null.
func normalizeID(id json.RawMessage) json.RawMessage {
	if len(id) == 0 {
		return nullID
	}
	return id
}

// trimSpace reports the input with leading/trailing ASCII whitespace removed,
// used only to detect blank lines without allocating a string.
func trimSpace(b []byte) []byte {
	start := 0
	for start < len(b) && isSpace(b[start]) {
		start++
	}
	end := len(b)
	for end > start && isSpace(b[end-1]) {
		end--
	}
	return b[start:end]
}

func isSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f'
}
