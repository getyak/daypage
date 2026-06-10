package session

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Store persists sessions so a run is resumable and auditable (DESIGN §4.4, §7).
// A session is stored as a JSONL file: the first line is a header record holding
// the session's identity + ambient context, and every subsequent line is one
// Event in order. This format is append-friendly, human-greppable, and the same
// event stream every client renders.
type Store interface {
	// Save writes the session's full current state to durable storage, replacing
	// any prior copy atomically. It is safe to call repeatedly (e.g. after each
	// run on the same id).
	Save(s *Session) error
	// Load reconstructs a session previously written under id. A missing session
	// returns an error satisfying errors.Is(err, ErrNotFound).
	Load(id string) (*Session, error)
	// List returns the ids of all persisted sessions, sorted. A missing store
	// directory is not an error — it yields an empty slice.
	List() ([]string, error)
}

// ErrNotFound is returned by Store.Load when no session exists for the id.
var ErrNotFound = errors.New("session: not found")

// fileExt is the on-disk extension for a persisted session.
const fileExt = ".jsonl"

// recordKind discriminates the two line shapes in a session JSONL file.
type recordKind string

const (
	recHeader recordKind = "header" // first line: session identity + context
	recEvent  recordKind = "event"  // every other line: one Event
)

// headerRecord is the first line of a session file: everything about a session
// that is not an Event. Keeping it as its own record (rather than guessing from
// the events) makes Load able to restore id/title/model/cwd/env faithfully.
type headerRecord struct {
	Kind    recordKind        `json:"kind"`
	ID      string            `json:"id"`
	Title   string            `json:"title,omitempty"`
	Model   string            `json:"model,omitempty"`
	Cwd     string            `json:"cwd,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
	Created time.Time         `json:"created"`
}

// eventRecord wraps one Event with a kind tag so a reader can tell header and
// event lines apart without positional assumptions.
type eventRecord struct {
	Kind  recordKind `json:"kind"`
	Event Event      `json:"event"`
}

// JSONLStore is a filesystem-backed Store rooted at a directory (one file per
// session: <Dir>/<id>.jsonl). The zero value is unusable; construct it with
// NewJSONLStore.
type JSONLStore struct {
	// Dir is the directory holding session files. It is created on first Save.
	Dir string
}

// NewJSONLStore returns a JSONLStore rooted at dir. The directory is not created
// until the first Save, so constructing a store has no side effects.
func NewJSONLStore(dir string) *JSONLStore {
	return &JSONLStore{Dir: dir}
}

// validID rejects ids that would escape the store directory or collide with
// path separators, so a session id can never be coerced into a path traversal.
func validID(id string) error {
	if id == "" {
		return errors.New("session: empty id")
	}
	// Disallow anything that introduces path structure. Session ids are opaque
	// tokens; a legitimate one never contains a separator or "..".
	if strings.ContainsAny(id, `/\`) || strings.Contains(id, "..") ||
		id == "." || strings.ContainsRune(id, 0) {
		return fmt.Errorf("session: invalid id %q", id)
	}
	return nil
}

// pathFor returns the on-disk path for a session id after validating it.
func (st *JSONLStore) pathFor(id string) (string, error) {
	if err := validID(id); err != nil {
		return "", err
	}
	return filepath.Join(st.Dir, id+fileExt), nil
}

// Save writes the session to <Dir>/<id>.jsonl atomically (temp file + rename) so
// a crash mid-write can never leave a torn session log. The directory is created
// with 0700 (state may include prompts); the file with 0600.
func (st *JSONLStore) Save(s *Session) error {
	if s == nil {
		return errors.New("session: Save(nil)")
	}
	if st.Dir == "" {
		return errors.New("session: store Dir is empty")
	}
	path, err := st.pathFor(s.ID)
	if err != nil {
		return err
	}

	// Snapshot identity/context + events under the read lock so a concurrent
	// Append can't tear the written copy.
	s.mu.RLock()
	header := headerRecord{
		Kind:    recHeader,
		ID:      s.ID,
		Title:   s.Title,
		Model:   s.Model,
		Cwd:     s.Cwd,
		Env:     cloneEnv(s.Env),
		Created: s.created,
	}
	events := append([]Event(nil), s.events...)
	s.mu.RUnlock()
	if header.Created.IsZero() {
		header.Created = time.Now()
	}

	if err := os.MkdirAll(st.Dir, 0o700); err != nil {
		return fmt.Errorf("session: create store dir: %w", err)
	}

	tmp, err := os.CreateTemp(st.Dir, ".session-*.tmp")
	if err != nil {
		return fmt.Errorf("session: temp file: %w", err)
	}
	tmpName := tmp.Name()
	// Best-effort cleanup on any error path before the final rename.
	defer func() { _ = os.Remove(tmpName) }()

	w := bufio.NewWriter(tmp)
	enc := json.NewEncoder(w)
	if err := enc.Encode(header); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("session: encode header: %w", err)
	}
	for i := range events {
		if err := enc.Encode(eventRecord{Kind: recEvent, Event: events[i]}); err != nil {
			_ = tmp.Close()
			return fmt.Errorf("session: encode event: %w", err)
		}
	}
	if err := w.Flush(); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("session: flush: %w", err)
	}
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("session: chmod: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("session: close temp: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("session: rename: %w", err)
	}
	return nil
}

// Load reconstructs the session stored under id. It reads the header line for
// identity/context and replays every event line in order, restoring the next
// sequence number so a resumed session continues numbering coherently. Malformed
// trailing lines (e.g. from a truncated write) are tolerated: parsing stops at
// the first unreadable record rather than failing the whole load.
func (st *JSONLStore) Load(id string) (*Session, error) {
	path, err := st.pathFor(id)
	if err != nil {
		return nil, err
	}
	f, err := os.Open(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, fmt.Errorf("%w: %q", ErrNotFound, id)
		}
		return nil, fmt.Errorf("session: open %q: %w", id, err)
	}
	defer f.Close()

	sess := &Session{ID: id, Env: map[string]string{}}
	sc := bufio.NewScanner(f)
	// Allow large lines (a tool result or args blob can be sizable) but bound them.
	sc.Buffer(make([]byte, 0, 64<<10), 16<<20)

	first := true
	maxSeq := 0
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		if first {
			first = false
			var h headerRecord
			if err := json.Unmarshal(line, &h); err == nil && h.Kind == recHeader {
				sess.Title = h.Title
				sess.Model = h.Model
				sess.Cwd = h.Cwd
				if len(h.Env) > 0 {
					sess.Env = cloneEnv(h.Env)
				}
				sess.created = h.Created
				continue
			}
			// No header (older/foreign file): fall through and try to parse this
			// same line as an event below.
		}
		var rec eventRecord
		if err := json.Unmarshal(line, &rec); err != nil || rec.Kind != recEvent {
			// Tolerate a torn final line; stop replaying further.
			break
		}
		sess.events = append(sess.events, rec.Event)
		if rec.Event.Seq > maxSeq {
			maxSeq = rec.Event.Seq
		}
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("session: read %q: %w", id, err)
	}
	if sess.created.IsZero() {
		sess.created = time.Now()
	}
	sess.seq = maxSeq
	return sess, nil
}

// List returns the sorted ids of every persisted session in the store. A missing
// store directory yields an empty list (not an error), matching the CLI's
// best-effort listing.
func (st *JSONLStore) List() ([]string, error) {
	entries, err := os.ReadDir(st.Dir)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("session: read store dir: %w", err)
	}
	var ids []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if strings.HasSuffix(name, fileExt) {
			ids = append(ids, strings.TrimSuffix(name, fileExt))
		}
	}
	// os.ReadDir already returns entries sorted by filename; trimming a common
	// suffix preserves that order, so ids are sorted.
	return ids, nil
}

// cloneEnv copies an env map so a persisted/loaded session never shares the
// caller's map.
func cloneEnv(in map[string]string) map[string]string {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]string, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}
