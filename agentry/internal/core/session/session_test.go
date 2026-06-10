package session

import (
	"testing"
	"time"
)

// TestLenTracksAppends verifies Len reports the running event count without a
// full Events() copy, and stays in sync as events are appended.
func TestLenTracksAppends(t *testing.T) {
	s := New("len-test")
	if got := s.Len(); got != 0 {
		t.Fatalf("Len() of fresh session = %d, want 0", got)
	}
	s.Append(Event{Type: EvUser, Text: "one"})
	s.Append(Event{Type: EvAssistant, Text: "two"})
	if got := s.Len(); got != 2 {
		t.Fatalf("Len() = %d, want 2", got)
	}
	if got, want := s.Len(), len(s.Events()); got != want {
		t.Fatalf("Len() = %d but len(Events()) = %d; they must agree", got, want)
	}
}

// TestCreatedIsSetAndSurvivesRoundTrip verifies Created reports a non-zero time
// for a fresh session and that the original creation time is preserved across a
// Save/Load round trip (so a listing can order/display sessions by age).
func TestCreatedIsSetAndSurvivesRoundTrip(t *testing.T) {
	s := New("created-test")
	created := s.Created()
	if created.IsZero() {
		t.Fatal("Created() of a fresh session is zero")
	}

	store := NewJSONLStore(t.TempDir())
	if err := store.Save(s); err != nil {
		t.Fatalf("Save: %v", err)
	}
	loaded, err := store.Load("created-test")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	// The persisted header records Created; the reloaded session must echo it
	// (allowing for sub-second JSON time encoding equality via Equal).
	if !loaded.Created().Equal(created) {
		t.Errorf("reloaded Created() = %v, want %v", loaded.Created(), created)
	}
	// And it must remain a sane, non-future timestamp.
	if loaded.Created().After(time.Now().Add(time.Minute)) {
		t.Errorf("reloaded Created() %v is implausibly in the future", loaded.Created())
	}
}
