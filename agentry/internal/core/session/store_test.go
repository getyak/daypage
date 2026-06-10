package session

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// newPopulatedSession builds a session with one of every event type so the
// round-trip tests exercise the full record vocabulary.
func newPopulatedSession(id string) *Session {
	s := New(id)
	s.Title = "do the thing"
	s.Model = "test-model"
	s.Cwd = "/tmp/work"
	s.Env["FOO"] = "bar"

	s.Append(Event{Type: EvUser, Text: "hello"})
	s.Append(Event{Type: EvAssistant, Text: "hi there"})
	s.Append(Event{Type: EvToolCall, Tool: "fs.read", CallID: "call-1", Args: json.RawMessage(`{"path":"x"}`)})
	s.Append(Event{Type: EvToolResult, Tool: "fs.read", CallID: "call-1", Text: "file contents", IsError: false})
	s.Append(Event{Type: EvMeta, Meta: map[string]any{"input_tokens": float64(10), "output_tokens": float64(20)}})
	s.Append(Event{Type: EvError, Text: "something went wrong"})
	return s
}

func TestJSONLStore_SaveLoadRoundTrip(t *testing.T) {
	dir := t.TempDir()
	st := NewJSONLStore(dir)
	orig := newPopulatedSession("run-roundtrip")

	if err := st.Save(orig); err != nil {
		t.Fatalf("Save: %v", err)
	}

	// The file must exist with the expected name.
	path := filepath.Join(dir, "run-roundtrip.jsonl")
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("expected session file at %s: %v", path, err)
	}

	loaded, err := st.Load("run-roundtrip")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	if loaded.ID != orig.ID || loaded.Title != orig.Title || loaded.Model != orig.Model || loaded.Cwd != orig.Cwd {
		t.Fatalf("metadata mismatch: got %+v want id/title/model/cwd of %+v", loaded, orig)
	}
	if loaded.Env["FOO"] != "bar" {
		t.Fatalf("env not restored: %+v", loaded.Env)
	}

	got, want := loaded.Events(), orig.Events()
	if len(got) != len(want) {
		t.Fatalf("event count: got %d want %d", len(got), len(want))
	}
	for i := range want {
		if got[i].Type != want[i].Type || got[i].Seq != want[i].Seq ||
			got[i].Text != want[i].Text || got[i].Tool != want[i].Tool ||
			got[i].CallID != want[i].CallID || got[i].IsError != want[i].IsError {
			t.Fatalf("event %d mismatch:\n got=%+v\nwant=%+v", i, got[i], want[i])
		}
	}

	// History reconstruction must survive the round trip too.
	if len(loaded.History()) != len(orig.History()) {
		t.Fatalf("history length differs after reload: got %d want %d",
			len(loaded.History()), len(orig.History()))
	}
}

func TestJSONLStore_LoadResumesSequence(t *testing.T) {
	dir := t.TempDir()
	st := NewJSONLStore(dir)
	orig := newPopulatedSession("run-resume")
	lastSeq := orig.Events()[len(orig.Events())-1].Seq

	if err := st.Save(orig); err != nil {
		t.Fatalf("Save: %v", err)
	}
	loaded, err := st.Load("run-resume")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	// Appending to a resumed session must continue numbering, not restart at 1.
	ev := loaded.Append(Event{Type: EvUser, Text: "again"})
	if ev.Seq != lastSeq+1 {
		t.Fatalf("resumed seq: got %d want %d", ev.Seq, lastSeq+1)
	}
}

func TestJSONLStore_LoadNotFound(t *testing.T) {
	st := NewJSONLStore(t.TempDir())
	_, err := st.Load("does-not-exist")
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
}

func TestJSONLStore_List(t *testing.T) {
	dir := t.TempDir()
	st := NewJSONLStore(dir)

	// Empty / missing dir lists nothing without error.
	ids, err := st.List()
	if err != nil {
		t.Fatalf("List on empty: %v", err)
	}
	if len(ids) != 0 {
		t.Fatalf("expected no ids, got %v", ids)
	}

	for _, id := range []string{"b-session", "a-session", "c-session"} {
		if err := st.Save(New(id)); err != nil {
			t.Fatalf("Save %s: %v", id, err)
		}
	}
	// A stray non-session file must be ignored.
	if err := os.WriteFile(filepath.Join(dir, "notes.txt"), []byte("x"), 0o600); err != nil {
		t.Fatalf("write stray: %v", err)
	}

	ids, err = st.List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	want := []string{"a-session", "b-session", "c-session"}
	if strings.Join(ids, ",") != strings.Join(want, ",") {
		t.Fatalf("List ids: got %v want %v (sorted)", ids, want)
	}
}

func TestJSONLStore_RejectsTraversalIDs(t *testing.T) {
	st := NewJSONLStore(t.TempDir())
	bad := []string{"", "../escape", "a/b", `a\b`, "..", ".", "x\x00y"}
	for _, id := range bad {
		if err := st.Save(New(id)); err == nil {
			t.Errorf("Save(%q) should have been rejected", id)
		}
		if _, err := st.Load(id); err == nil {
			t.Errorf("Load(%q) should have been rejected", id)
		}
	}
}

func TestJSONLStore_SaveIsAtomicOverwrite(t *testing.T) {
	dir := t.TempDir()
	st := NewJSONLStore(dir)
	id := "run-overwrite"

	s1 := New(id)
	s1.Append(Event{Type: EvUser, Text: "first"})
	if err := st.Save(s1); err != nil {
		t.Fatalf("Save first: %v", err)
	}

	// Saving the same id again replaces the file and leaves no temp files behind.
	s2 := New(id)
	s2.Append(Event{Type: EvUser, Text: "first"})
	s2.Append(Event{Type: EvAssistant, Text: "second"})
	if err := st.Save(s2); err != nil {
		t.Fatalf("Save second: %v", err)
	}

	loaded, err := st.Load(id)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(loaded.Events()) != 2 {
		t.Fatalf("overwrite event count: got %d want 2", len(loaded.Events()))
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".session-") || strings.HasSuffix(e.Name(), ".tmp") {
			t.Fatalf("leftover temp file after Save: %s", e.Name())
		}
	}
}

func TestJSONLStore_ToleratesTornFinalLine(t *testing.T) {
	dir := t.TempDir()
	st := NewJSONLStore(dir)
	s := newPopulatedSession("run-torn")
	if err := st.Save(s); err != nil {
		t.Fatalf("Save: %v", err)
	}

	// Simulate a crash mid-append: a partial JSON line glued onto the end.
	path := filepath.Join(dir, "run-torn.jsonl")
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatalf("open for append: %v", err)
	}
	if _, err := f.WriteString(`{"kind":"event","event":{"type":"user","te`); err != nil {
		t.Fatalf("write torn line: %v", err)
	}
	_ = f.Close()

	// Load must succeed and return the intact events, dropping only the torn tail.
	loaded, err := st.Load("run-torn")
	if err != nil {
		t.Fatalf("Load with torn tail: %v", err)
	}
	if len(loaded.Events()) != len(s.Events()) {
		t.Fatalf("torn-tail event count: got %d want %d", len(loaded.Events()), len(s.Events()))
	}
}
