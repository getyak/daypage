package web

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/kubbot/agentry/internal/core/provider/retry"
	"github.com/kubbot/agentry/internal/core/tool"
)

// mkInput builds a tool.Input with JSON-encoded args from a map (no session).
func mkInput(t *testing.T, args map[string]any) tool.Input {
	t.Helper()
	return tool.Input{Args: mustJSON(t, args)}
}

// withLocalScreen relaxes the SSRF screen for the duration of a test so the web
// tools can reach a loopback httptest server (normally blocked), and restores
// both the screen and the package config afterward. It also installs a fast
// retry policy so a retry-exercising test doesn't sleep for real seconds.
func withLocalScreen(t *testing.T, fast retry.Policy) {
	t.Helper()
	prevScreen := screenIP
	prevCfg, prevClient := snapshot()

	screenIP = func(_ net.IP) bool { return false } // allow loopback in tests
	Configure(Config{RequestTimeout: 5 * time.Second, Retry: fast})

	t.Cleanup(func() {
		screenIP = prevScreen
		mu.Lock()
		cfg = prevCfg
		httpClient = prevClient
		mu.Unlock()
	})
}

// TestFetchRetriesTransient503 proves the retry layer is wired into the web
// tools' shared HTTP client: a server that 503s on the first GET and then
// succeeds yields a single successful fetch (the tool transparently retried),
// and the server observes exactly two hits.
func TestFetchRetriesTransient503(t *testing.T) {
	withLocalScreen(t, retry.Policy{MaxRetries: 3, BaseDelay: time.Millisecond, MaxDelay: 5 * time.Millisecond})

	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := atomic.AddInt32(&hits, 1)
		if n == 1 {
			http.Error(w, "overloaded", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "text/plain")
		_, _ = w.Write([]byte("recovered-body"))
	}))
	defer srv.Close()

	res, err := byName(t, "web.fetch").Invoke(context.Background(),
		mkInput(t, map[string]any{"url": srv.URL}))
	if err != nil {
		t.Fatalf("web.fetch returned transport error: %v", err)
	}
	if res.IsError {
		t.Fatalf("web.fetch reported error result after retry: %q", res.Content)
	}
	if !strings.Contains(res.Content, "recovered-body") {
		t.Fatalf("web.fetch body missing recovered content: %q", res.Content)
	}
	if got := atomic.LoadInt32(&hits); got != 2 {
		t.Fatalf("server hit %d times, want 2 (one 503 + one success)", got)
	}
}

// TestFetchDoesNotRetry4xx confirms a non-transient status (404) is returned
// after exactly one request — retries must not fire on client errors.
func TestFetchDoesNotRetry4xx(t *testing.T) {
	withLocalScreen(t, retry.Policy{MaxRetries: 3, BaseDelay: time.Millisecond, MaxDelay: 5 * time.Millisecond})

	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		http.Error(w, "nope", http.StatusNotFound)
	}))
	defer srv.Close()

	res, err := byName(t, "web.fetch").Invoke(context.Background(),
		mkInput(t, map[string]any{"url": srv.URL}))
	if err != nil {
		t.Fatalf("web.fetch transport error: %v", err)
	}
	// A 404 is a valid HTTP result the model should see, flagged IsError.
	if !res.IsError {
		t.Fatalf("expected IsError for 404, got: %q", res.Content)
	}
	if got := atomic.LoadInt32(&hits); got != 1 {
		t.Fatalf("server hit %d times, want exactly 1 (4xx not retried)", got)
	}
}

// TestConfigureMaxRedirectsCap verifies the redirect cap is honored from the
// runtime config: with MaxRedirects=1, a 2-hop redirect chain is stopped.
func TestConfigureMaxRedirectsCap(t *testing.T) {
	withLocalScreen(t, retry.DefaultPolicy())
	// Tighten just the redirect cap on top of the relaxed-screen config.
	Configure(Config{MaxRedirects: 1})

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/a":
			http.Redirect(w, r, "/b", http.StatusFound)
		case "/b":
			http.Redirect(w, r, "/c", http.StatusFound)
		default:
			_, _ = w.Write([]byte("final"))
		}
	}))
	defer srv.Close()

	res, err := byName(t, "web.fetch").Invoke(context.Background(),
		mkInput(t, map[string]any{"url": srv.URL + "/a"}))
	if err != nil {
		t.Fatalf("transport error: %v", err)
	}
	// The chain should be stopped after 1 redirect, surfaced as an error result.
	if !res.IsError {
		t.Fatalf("expected redirect-cap error result, got ok: %q", res.Content)
	}
	if !strings.Contains(res.Content, "redirect") {
		t.Fatalf("expected a redirect-stop message, got: %q", res.Content)
	}
}

// TestConfigureBodyCap verifies the configured hard byte ceiling truncates a
// large body even when the caller requests more.
func TestConfigureBodyCap(t *testing.T) {
	withLocalScreen(t, retry.DefaultPolicy())
	Configure(Config{HardMaxBytes: 16}) // tiny ceiling

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(strings.Repeat("X", 1000)))
	}))
	defer srv.Close()

	res, err := byName(t, "web.fetch").Invoke(context.Background(),
		mkInput(t, map[string]any{"url": srv.URL, "max_bytes": 1000}))
	if err != nil {
		t.Fatalf("transport error: %v", err)
	}
	if !strings.Contains(res.Content, "truncated") {
		t.Fatalf("expected truncation marker with a 16-byte cap, got: %q", res.Content)
	}
	if b, ok := res.Meta["bytes"].(int); ok && b > 16 {
		t.Fatalf("body bytes = %d, exceeds configured cap 16", b)
	}
}
