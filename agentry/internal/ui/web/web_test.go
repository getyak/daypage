package web

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestHandlerServesSPA verifies the embedded handler serves the self-contained
// index.html at "/" with the expected title, the POST-SSE client (fetch +
// ReadableStream, NOT EventSource which cannot POST), and the event handlers the
// transport's stream relies on.
func TestHandlerServesSPA(t *testing.T) {
	srv := httptest.NewServer(Handler())
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatalf("GET /: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
		t.Fatalf("Content-Type = %q, want text/html", ct)
	}

	body, _ := io.ReadAll(resp.Body)
	html := string(body)

	// Required ingredients of the SPA contract.
	for _, needle := range []string{
		"<title>Agentry</title>", // title
		"/v1/sessions",           // create-session endpoint
		"/messages",              // message endpoint
		"getReader()",            // streaming POST body read
		"parseFrame",             // manual SSE frame parsing
		`"assistant"`,            // renders assistant text
		"tool_call",              // renders tool calls
		"tool_result",            // renders tool results
		`"done"`,                 // honors terminal done event
	} {
		if !strings.Contains(html, needle) {
			t.Errorf("SPA missing expected content: %q", needle)
		}
	}

	// EventSource cannot issue a POST, so the SPA must NOT use it for the
	// message stream — it must use fetch() + ReadableStream.
	if strings.Contains(html, "new EventSource(") {
		t.Error("SPA uses EventSource; POST SSE requires fetch + ReadableStream")
	}
}

// TestHandlerUnknownPath404 ensures non-existent assets 404 (so the file server
// never shadows the JSON API when mounted as the transport's catch-all).
func TestHandlerUnknownPath404(t *testing.T) {
	srv := httptest.NewServer(Handler())
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/no-such-asset.js")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", resp.StatusCode)
	}
}
