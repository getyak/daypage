// Package http is the REST + SSE transport: it exposes the agent Engine over
// plain HTTP so users, third-party programs, and other agents can drive agentry
// without speaking stdio or MCP. It is one of the three transports from
// DESIGN §6, all of which wrap the same *agent.Engine.
//
// Routes (std net/http mux, Go 1.22+ method+pattern matching):
//
//	GET  /healthz                       -> {"status":"ok"}
//	GET  /v1/tools                       -> [{"name","description"}, ...]
//	GET  /v1/sessions                    -> [{"id","title","model","events","created"}, ...]
//	                                        (discoverable resumable sessions)
//	POST /v1/sessions                    -> {"id": "<new session id>", "resumed": false}
//	                                        body {"resume":"<id>"} rehydrates a
//	                                        persisted session (-> "resumed": true).
//	POST /v1/sessions/{id}/messages      -> Server-Sent Events stream of the run,
//	                                        terminated by a final "done" event
//	                                        carrying the assistant's final text.
//	GET  /                               -> embedded Web UI if present, else a
//	                                        tiny HTML status page.
//
// The server is headless-first: it holds no business logic, it only marshals
// requests onto the Engine and streams the resulting session events back out.
// By default sessions live for the process lifetime in an in-memory map; when a
// durable store is wired (ServeWithStore / NewHandlerWithStore) they are
// persisted on create and after each run and can be resumed across a process
// restart (DESIGN §4.4).
package http

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/kubbot/agentry/internal/core/agent"
	"github.com/kubbot/agentry/internal/core/session"
)

// SessionStore is the narrow persistence seam this transport needs: save a
// session's current state, load a previously persisted one by id, and list the
// ids of all persisted sessions (so a client can discover what is resumable via
// GET /v1/sessions). It is satisfied by *session.JSONLStore (DESIGN §4.4) and by
// any in-memory test double; nil disables persistence (sessions then live only
// in memory for the process lifetime).
type SessionStore interface {
	Save(s *session.Session) error
	Load(id string) (*session.Session, error)
	List() ([]string, error)
}

// maxMessageBody caps the size of a POST /messages request body so a client
// cannot stream an unbounded prompt into memory. 1 MiB is comfortably larger
// than any reasonable single user turn.
const maxMessageBody = 1 << 20

// maxSessionBody caps the optional POST /v1/sessions request body (which may
// carry a {"resume":"<id>"} directive). It is small because the only field is a
// session id; a larger body is almost certainly a client mistake.
const maxSessionBody = 4 << 10

// shutdownGrace bounds how long graceful shutdown waits for in-flight requests
// (notably long-lived SSE streams, which are detached on ctx cancellation).
const shutdownGrace = 5 * time.Second

// Serve runs the HTTP transport until ctx is cancelled, then shuts the server
// down gracefully. It binds addr (e.g. ":8080" or "127.0.0.1:0"), wires the
// routes against eng, and blocks until the server stops.
//
// Sessions created here are in-memory only; use ServeWithStore to persist and
// resume them across process restarts (DESIGN §4.4).
//
// The returned error is nil on a clean ctx-triggered shutdown; otherwise it is
// the underlying ListenAndServe / Shutdown failure. A nil engine is rejected up
// front rather than panicking on the first request.
func Serve(ctx context.Context, eng *agent.Engine, addr string) error {
	return ServeWithStore(ctx, eng, addr, nil)
}

// ServeWithStore is Serve plus durable session persistence: every session is
// saved to store when created and after each message run completes, and a prior
// session can be resumed via POST /v1/sessions {"resume":"<id>"} or simply by
// posting a message to its id (the handler rehydrates it from store on a miss).
// A nil store behaves exactly like Serve.
func ServeWithStore(ctx context.Context, eng *agent.Engine, addr string, store SessionStore) error {
	if eng == nil {
		return errors.New("http: engine is nil")
	}

	srv := &http.Server{
		Addr:    addr,
		Handler: NewHandlerWithStore(eng, store),
		// BaseContext threads the caller's ctx into every request so handlers
		// (and the Engine runs they kick off) are cancelled when the server is
		// asked to stop, per DESIGN's "ctx cancellation bounds every run".
		BaseContext: func(net.Listener) context.Context { return ctx },
		// Defensive timeouts. WriteTimeout is intentionally left at 0: SSE
		// responses are long-lived and a write deadline would sever live
		// streams. Read paths are bounded by ReadHeaderTimeout + body caps.
		ReadHeaderTimeout: 10 * time.Second,
	}

	// Shut the server down when ctx is cancelled. We run ListenAndServe in a
	// goroutine so this function can select between "server stopped on its own"
	// and "ctx asked us to stop".
	serveErr := make(chan error, 1)
	go func() {
		err := srv.ListenAndServe()
		// ErrServerClosed is the expected outcome of a graceful Shutdown; treat
		// it as success so a clean stop is not reported as a failure.
		if errors.Is(err, http.ErrServerClosed) {
			err = nil
		}
		serveErr <- err
	}()

	select {
	case err := <-serveErr:
		// Server stopped without us asking (e.g. bind failure). Return as-is.
		return err
	case <-ctx.Done():
		// Graceful shutdown: stop accepting new connections and let in-flight
		// requests drain up to shutdownGrace. SSE streams observe the cancelled
		// BaseContext and detach promptly, so this rarely needs the full grace.
		shutCtx, cancel := context.WithTimeout(context.Background(), shutdownGrace)
		defer cancel()
		if err := srv.Shutdown(shutCtx); err != nil {
			return err
		}
		// Surface any ListenAndServe error that raced with shutdown.
		return <-serveErr
	}
}

// server holds the transport's shared state: the Engine every request drives,
// the in-memory session map, and an optional durable store. It is the receiver
// for the route handlers.
type server struct {
	eng   *agent.Engine
	store SessionStore // optional; nil => sessions live only in memory

	mu       sync.Mutex
	sessions map[string]*session.Session
	idSeq    atomic.Uint64
}

// NewHandler builds the transport's http.Handler (routes wired against eng)
// without binding a socket. Exposed so tests can hit it via httptest and so the
// handler can be embedded in a larger mux if desired. Sessions are in-memory
// only; use NewHandlerWithStore for durable persistence/resume.
func NewHandler(eng *agent.Engine) http.Handler {
	return NewHandlerWithStore(eng, nil)
}

// NewHandlerWithStore is NewHandler plus a durable session store: sessions are
// persisted on create and after each message run, and can be resumed. A nil
// store behaves exactly like NewHandler.
func NewHandlerWithStore(eng *agent.Engine, store SessionStore) http.Handler {
	s := &server{
		eng:      eng,
		store:    store,
		sessions: make(map[string]*session.Session),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.handleHealthz)
	mux.HandleFunc("GET /v1/tools", s.handleListTools)
	mux.HandleFunc("GET /v1/sessions", s.handleListSessions)
	mux.HandleFunc("POST /v1/sessions", s.handleCreateSession)
	mux.HandleFunc("POST /v1/sessions/{id}/messages", s.handlePostMessage)
	// Root: embedded UI if one is wired, else a status page. Registered as the
	// catch-all so it also serves unknown paths with the status page rather
	// than a bare 404.
	mux.Handle("/", rootHandler())
	return mux
}

// handleHealthz is a liveness probe: always 200 with a fixed body.
func (s *server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// toolInfo is the public shape of a tool in the /v1/tools listing: just what a
// client needs to know it exists and what it does, never the Go type.
type toolInfo struct {
	Name        string `json:"name"`
	Description string `json:"description"`
}

// handleListTools returns the registered tools as a JSON array, in the
// registry's stable name-sorted order.
func (s *server) handleListTools(w http.ResponseWriter, _ *http.Request) {
	// Always emit a JSON array (never null) even when no registry is wired.
	out := []toolInfo{}
	if s.eng.Tools != nil {
		for _, t := range s.eng.Tools.List() {
			out = append(out, toolInfo{Name: t.Name(), Description: t.Description()})
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// sessionSummary is one entry in the GET /v1/sessions listing: enough metadata
// for a client to recognize a session and decide whether to resume it, without
// shipping the whole event log. Events is the recorded event count; Created is
// the session's creation time.
type sessionSummary struct {
	ID      string    `json:"id"`
	Title   string    `json:"title,omitempty"`
	Model   string    `json:"model,omitempty"`
	Events  int       `json:"events"`
	Created time.Time `json:"created,omitempty"`
}

// handleListSessions returns the sessions a client could resume, as a JSON array
// sorted by id. It reports the union of the durable store (when wired) and the
// in-memory map, deduplicated, so a caller can DISCOVER resumable conversations
// instead of having to already know an id — the gap left after resume was added
// (R6). Each entry carries lightweight metadata; a persisted session that cannot
// be loaded degrades to an id-only summary rather than failing the whole call.
func (s *server) handleListSessions(w http.ResponseWriter, _ *http.Request) {
	// Snapshot the in-memory sessions under the lock.
	s.mu.Lock()
	live := make(map[string]*session.Session, len(s.sessions))
	for id, sess := range s.sessions {
		live[id] = sess
	}
	s.mu.Unlock()

	idSet := map[string]struct{}{}
	if s.store != nil {
		if ids, err := s.store.List(); err == nil {
			for _, id := range ids {
				idSet[id] = struct{}{}
			}
		}
		// A List error is non-fatal: still report the in-memory sessions.
	}
	for id := range live {
		idSet[id] = struct{}{}
	}

	ids := make([]string, 0, len(idSet))
	for id := range idSet {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	// Always emit a JSON array (never null), even when there are no sessions.
	out := make([]sessionSummary, 0, len(ids))
	for _, id := range ids {
		out = append(out, s.summarize(id, live[id]))
	}
	writeJSON(w, http.StatusOK, out)
}

// summarize builds a sessionSummary for id, preferring the live in-memory copy
// (most up to date) and otherwise loading it from the store. A store load
// failure yields an id-only summary so one unreadable file never sinks the list.
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

// createSessionRequest is the (optional) POST /v1/sessions body. Resume, when
// set, rehydrates a previously persisted session (by id) instead of minting a
// new one, so a conversation can continue across a process restart. An empty or
// absent body creates a fresh session.
type createSessionRequest struct {
	Resume string `json:"resume"`
}

// handleCreateSession allocates a fresh session (monotonic id "s1", "s2", ...)
// or, when the body carries {"resume":"<id>"} and a store is wired, rehydrates a
// persisted session under its original id. New sessions are persisted
// immediately (best-effort) so they are visible to `agentry session ls`.
func (s *server) handleCreateSession(w http.ResponseWriter, r *http.Request) {
	// The body is optional. Parse it leniently (size-capped) so a plain
	// create-with-no-body keeps working exactly as before.
	var req createSessionRequest
	if r.Body != nil {
		body := http.MaxBytesReader(w, r.Body, maxSessionBody)
		dec := json.NewDecoder(body)
		if err := dec.Decode(&req); err != nil && !errors.Is(err, io.EOF) {
			writeError(w, http.StatusBadRequest, "invalid JSON body: "+err.Error())
			return
		}
	}

	// Resume path: load the named session from the store (or reuse an in-memory
	// copy if one is already registered).
	if id := strings.TrimSpace(req.Resume); id != "" {
		sess, ok := s.resume(id)
		if !ok {
			writeError(w, http.StatusNotFound, fmt.Sprintf("cannot resume unknown session %q", id))
			return
		}
		writeJSON(w, http.StatusCreated, map[string]any{"id": sess.ID, "resumed": true})
		return
	}

	id := "s" + strconv.FormatUint(s.idSeq.Add(1), 10)
	sess := session.New(id)
	// Stamp the engine's model onto the session so it is persisted and a later
	// listing (even from a fresh process reading only the store) reports it.
	sess.Model = s.eng.Model

	s.mu.Lock()
	s.sessions[id] = sess
	s.mu.Unlock()

	s.persist(sess)

	writeJSON(w, http.StatusCreated, map[string]any{"id": id, "resumed": false})
}

// resume returns the session for id, preferring an in-memory copy and otherwise
// rehydrating it from the durable store and registering it. It returns false
// when there is no store or no persisted session under id. If a concurrent
// request already registered the id, that copy wins so two requests never drive
// divergent sessions.
func (s *server) resume(id string) (*session.Session, bool) {
	s.mu.Lock()
	if sess, ok := s.sessions[id]; ok {
		s.mu.Unlock()
		return sess, true
	}
	s.mu.Unlock()

	if s.store == nil {
		return nil, false
	}
	loaded, err := s.store.Load(id)
	if err != nil {
		return nil, false
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if sess, ok := s.sessions[id]; ok {
		return sess, true // lost a race; use the already-registered copy
	}
	s.sessions[id] = loaded
	return loaded, true
}

// persist saves a session to the durable store, best-effort. A nil store is a
// no-op (in-memory mode). A save failure is swallowed (logged to the server's
// stderr) so persistence never turns a successful run into a transport error.
func (s *server) persist(sess *session.Session) {
	if s.store == nil || sess == nil {
		return
	}
	if err := s.store.Save(sess); err != nil {
		log.Printf("http: warning: could not persist session %s: %v", sess.ID, err)
	}
}

// messageRequest is the POST /messages body: a single user turn.
type messageRequest struct {
	Input string `json:"input"`
}

// handlePostMessage runs one user turn against an existing session and streams
// the unfolding run back as Server-Sent Events.
//
// Wire protocol: each session Event becomes one SSE message whose `event:` field
// is the event type (user/assistant/tool_call/tool_result/meta/error) and whose
// `data:` field is the JSON-encoded session.Event. When the Engine run returns,
// a terminal `event: done` message carries {"text": "<final assistant text>"}
// (or {"error": "..."} if the run failed). Clients read until they see "done".
func (s *server) handlePostMessage(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")

	s.mu.Lock()
	sess, ok := s.sessions[id]
	s.mu.Unlock()
	if !ok {
		// Not held in memory: try rehydrating it from the durable store so a
		// session created before a restart can still be messaged. Only if that
		// also misses do we 404.
		if rehydrated, found := s.resume(id); found {
			sess = rehydrated
		} else {
			writeError(w, http.StatusNotFound, fmt.Sprintf("session %q not found", id))
			return
		}
	}

	// Parse the (size-capped) body.
	var req messageRequest
	body := http.MaxBytesReader(w, r.Body, maxMessageBody)
	if err := json.NewDecoder(body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body: "+err.Error())
		return
	}
	if req.Input == "" {
		writeError(w, http.StatusBadRequest, "input must not be empty")
		return
	}

	// SSE requires a flushable writer; without it we cannot deliver events
	// incrementally and would just buffer the whole run.
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}

	// SSE response headers. Must be set before the first write/flush.
	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache")
	h.Set("Connection", "keep-alive")
	// Defeat proxy buffering (nginx) so events arrive promptly.
	h.Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	// The client may disconnect; the request context (derived from the server's
	// BaseContext) is cancelled on either client hang-up or server shutdown.
	ctx := r.Context()

	// Subscribe BEFORE starting the run so we cannot miss the first events the
	// Engine appends. Subscribe only delivers *future* events, and Run appends
	// the user event first, so we subscribe, then run.
	events, unsubscribe := sess.Subscribe()
	defer unsubscribe()

	// Run the Engine in a goroutine; it appends events to the session as it
	// progresses, which arrive on `events`. We stream until the run reports its
	// outcome on `result`.
	type runOutcome struct {
		text string
		err  error
	}
	result := make(chan runOutcome, 1)
	go func() {
		text, err := s.eng.Run(ctx, sess, req.Input)
		result <- runOutcome{text: text, err: err}
	}()

	// Stream loop: forward session events as they arrive, and finish when the
	// run completes (draining any straggler events first) or ctx is cancelled.
	for {
		select {
		case ev := <-events:
			writeSSEEvent(w, flusher, string(ev.Type), ev)

		case out := <-result:
			// Drain any events the Engine appended right before returning but
			// that we have not yet forwarded, so the stream is complete.
			drainEvents(w, flusher, events)
			// Persist the updated session (best-effort) so the conversation
			// survives a restart and is visible to `agentry session ls|show`.
			// Done before the terminal event so a client that immediately
			// resumes after seeing "done" finds the latest history on disk.
			s.persist(sess)
			writeDone(w, flusher, out.text, out.err)
			return

		case <-ctx.Done():
			// Client gone or server shutting down. The Engine run observes the
			// same cancelled ctx and unwinds; nothing more to send.
			return
		}
	}
}

// drainEvents forwards any session events currently buffered in the subscription
// channel without blocking. Called once the run has returned to flush events the
// Engine appended just before finishing (e.g. the final assistant message).
func drainEvents(w io.Writer, flusher http.Flusher, events <-chan session.Event) {
	for {
		select {
		case ev := <-events:
			writeSSEEvent(w, flusher, string(ev.Type), ev)
		default:
			return
		}
	}
}

// writeDone emits the terminal SSE "done" event. On success the payload carries
// the final assistant text; on failure it carries the error string so the
// client learns the run did not complete normally.
func writeDone(w io.Writer, flusher http.Flusher, text string, runErr error) {
	payload := map[string]string{"text": text}
	if runErr != nil {
		payload["error"] = runErr.Error()
	}
	writeSSEEvent(w, flusher, "done", payload)
}

// writeSSEEvent serializes one Server-Sent Event: a named `event:` line, the
// JSON `data:` line, and the blank line that terminates the event, then flushes
// so the client receives it immediately. Marshal failures are reported inline as
// an `error` event rather than silently dropping the message.
func writeSSEEvent(w io.Writer, flusher http.Flusher, event string, data any) {
	b, err := json.Marshal(data)
	if err != nil {
		// Fall back to a minimal, always-marshalable error payload.
		b, _ = json.Marshal(map[string]string{"error": "marshal failed: " + err.Error()})
		event = "error"
	}
	// SSE frame: "event: <name>\n" then "data: <json>\n" then a blank line.
	// data must not contain a raw newline; our JSON payloads are single-line.
	fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, b)
	flusher.Flush()
}

// writeJSON writes a JSON response with the given status code. Used for the
// non-streaming endpoints.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	// Best-effort encode; if it fails the status line is already sent, so there
	// is nothing actionable to do but stop.
	_ = json.NewEncoder(w).Encode(v)
}

// writeError writes a {"error": msg} JSON body with the given status code.
func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
