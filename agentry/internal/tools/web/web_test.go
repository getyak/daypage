package web

import (
	"context"
	"encoding/json"
	"net"
	"strings"
	"testing"

	"github.com/kubbot/agentry/internal/core/tool"
)

// byName finds a web tool by its registered name.
func byName(t *testing.T, name string) tool.Tool {
	t.Helper()
	for _, tl := range All() {
		if tl.Name() == name {
			return tl
		}
	}
	t.Fatalf("web tool %q not found in All()", name)
	return nil
}

func mustJSON(t *testing.T, v any) json.RawMessage {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal args: %v", err)
	}
	return b
}

// TestAllRegistersExpectedTools guards the public surface: the three web tools
// are present with stable names and valid JSON schemas.
func TestAllRegistersExpectedTools(t *testing.T) {
	want := map[string]bool{"web.fetch": false, "web.extract": false, "web.search": false}
	for _, tl := range All() {
		if _, ok := want[tl.Name()]; !ok {
			t.Errorf("unexpected tool %q", tl.Name())
			continue
		}
		want[tl.Name()] = true
		if !json.Valid(tl.Schema()) {
			t.Errorf("tool %q has invalid JSON schema", tl.Name())
		}
		if tl.Description() == "" {
			t.Errorf("tool %q has empty description", tl.Name())
		}
	}
	for name, seen := range want {
		if !seen {
			t.Errorf("tool %q missing from All()", name)
		}
	}
}

// TestHTMLToText drives the offline HTML→text extractor over a representative
// sample: title, headings, paragraphs, links, lists, and content that must be
// stripped (script/style/nav). This is the core of web.extract and runs with no
// network.
func TestHTMLToText(t *testing.T) {
	const sample = `<!DOCTYPE html>
<html>
<head>
  <title>  Sample  Page  </title>
  <style>.x{color:red}</style>
  <script>console.log("nope")</script>
</head>
<body>
  <nav><a href="/skip">menu link should be dropped</a></nav>
  <header>banner</header>
  <main>
    <h1>Hello World</h1>
    <p>This is   a   paragraph with
       wrapped whitespace.</p>
    <p>Visit <a href="https://example.com/page">the example</a> for more.</p>
    <ul>
      <li>First item</li>
      <li>Second item</li>
    </ul>
    <h2>Section Two</h2>
    <p>Closing line.</p>
  </main>
  <footer>copyright</footer>
</body>
</html>`

	text, title, err := htmlToText(sample)
	if err != nil {
		t.Fatalf("htmlToText error: %v", err)
	}

	if title != "Sample Page" {
		t.Errorf("title = %q, want %q", title, "Sample Page")
	}

	// Stripped content must not appear.
	for _, banned := range []string{
		"console.log", "color:red", "menu link", "banner", "copyright", "/skip",
	} {
		if strings.Contains(text, banned) {
			t.Errorf("extracted text unexpectedly contains %q:\n%s", banned, text)
		}
	}

	// Headings rendered with '#'.
	if !strings.Contains(text, "# Hello World") {
		t.Errorf("missing H1 heading marker:\n%s", text)
	}
	if !strings.Contains(text, "## Section Two") {
		t.Errorf("missing H2 heading marker:\n%s", text)
	}

	// Whitespace collapsed within a paragraph.
	if !strings.Contains(text, "This is a paragraph with wrapped whitespace.") {
		t.Errorf("paragraph whitespace not collapsed:\n%s", text)
	}

	// Link preserved as Markdown.
	if !strings.Contains(text, "[the example](https://example.com/page)") {
		t.Errorf("link not rendered as markdown:\n%s", text)
	}

	// List items rendered as "- ".
	if !strings.Contains(text, "- First item") || !strings.Contains(text, "- Second item") {
		t.Errorf("list items not rendered:\n%s", text)
	}

	// Closing content present.
	if !strings.Contains(text, "Closing line.") {
		t.Errorf("missing closing paragraph:\n%s", text)
	}
}

// TestHTMLToTextEmptyAndPlain checks degenerate inputs don't panic and produce
// sane output.
func TestHTMLToTextEmptyAndPlain(t *testing.T) {
	cases := map[string]string{
		"":                      "",
		"   ":                   "",
		"plain text no tags":    "plain text no tags",
		"<p></p><p></p>":        "",
		"<b>bold</b> <i>it</i>": "bold it",
		"<a href=''>x</a>":      "x",
		"<a href='#frag'>y</a>": "y",
	}
	for in, want := range cases {
		got, _, err := htmlToText(in)
		if err != nil {
			t.Errorf("htmlToText(%q) error: %v", in, err)
			continue
		}
		if got != want {
			t.Errorf("htmlToText(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestExtractInlineHTML exercises web.extract end-to-end on inline HTML (no
// network), verifying it leads with the title as an H1 and includes body text.
func TestExtractInlineHTML(t *testing.T) {
	tl := byName(t, "web.extract")
	args := mustJSON(t, map[string]any{
		"html": `<html><head><title>Doc</title></head><body><h1>Heading</h1><p>Body text.</p></body></html>`,
	})
	res, err := tl.Invoke(context.Background(), tool.Input{Args: args})
	if err != nil {
		t.Fatalf("invoke error: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected tool error: %s", res.Content)
	}
	if !strings.HasPrefix(res.Content, "# Doc") {
		t.Errorf("expected content to lead with '# Doc', got:\n%s", res.Content)
	}
	if !strings.Contains(res.Content, "Body text.") {
		t.Errorf("expected body text in output:\n%s", res.Content)
	}
	if title, _ := res.Meta["title"].(string); title != "Doc" {
		t.Errorf("meta title = %v, want Doc", res.Meta["title"])
	}
}

// TestExtractArgValidation covers the mutually-exclusive url/html contract.
func TestExtractArgValidation(t *testing.T) {
	tl := byName(t, "web.extract")
	ctx := context.Background()

	// Neither provided.
	res, _ := tl.Invoke(ctx, tool.Input{Args: mustJSON(t, map[string]any{})})
	if !res.IsError {
		t.Errorf("expected error when neither url nor html provided")
	}

	// Both provided.
	res, _ = tl.Invoke(ctx, tool.Input{Args: mustJSON(t, map[string]any{
		"url": "https://example.com", "html": "<p>x</p>",
	})})
	if !res.IsError {
		t.Errorf("expected error when both url and html provided")
	}
}

// TestSearchNoBackend verifies the vendor-neutral "not configured" behavior when
// AGENTRY_SEARCH_URL is unset: a clear, error-flagged Result (not a crash, not a
// silent empty success).
func TestSearchNoBackend(t *testing.T) {
	// Stub the template source to empty regardless of the real environment.
	orig := getSearchURLTemplate
	getSearchURLTemplate = func() string { return "" }
	defer func() { getSearchURLTemplate = orig }()

	tl := byName(t, "web.search")
	res, err := tl.Invoke(context.Background(), tool.Input{
		Args: mustJSON(t, map[string]any{"query": "anything"}),
	})
	if err != nil {
		t.Fatalf("invoke error: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected IsError when no backend configured, got: %s", res.Content)
	}
	if !strings.Contains(res.Content, searchURLEnv) {
		t.Errorf("expected message to mention %s, got: %s", searchURLEnv, res.Content)
	}
}

// TestSearchEmptyQuery rejects a blank query before touching any backend.
func TestSearchEmptyQuery(t *testing.T) {
	tl := byName(t, "web.search")
	res, _ := tl.Invoke(context.Background(), tool.Input{
		Args: mustJSON(t, map[string]any{"query": "   "}),
	})
	if !res.IsError {
		t.Errorf("expected error for empty query")
	}
}

// TestFetchSSRFGuard verifies the URL/scheme/host policy without any network:
// non-http schemes and literal private/loopback/metadata IPs are rejected up
// front by validateURL, and the fetch tool surfaces a tool-level error.
func TestFetchSSRFGuard(t *testing.T) {
	tl := byName(t, "web.fetch")
	ctx := context.Background()

	blocked := []string{
		"file:///etc/passwd",
		"ftp://example.com/x",
		"http://127.0.0.1/",
		"http://localhost/", // resolves to loopback; blocked at dial if not literal
		"http://169.254.169.254/latest/meta-data/",
		"http://10.0.0.5/",
		"http://192.168.1.1/",
		"http://172.16.0.1/",
		"http://[::1]/",
		"https://[fd00::1]/",
		"not-a-url",
		"",
	}
	for _, raw := range blocked {
		res, err := tl.Invoke(ctx, tool.Input{Args: mustJSON(t, map[string]any{"url": raw})})
		if err != nil {
			t.Errorf("fetch(%q) returned hard error: %v", raw, err)
			continue
		}
		if !res.IsError {
			t.Errorf("fetch(%q) should be blocked/error, got success:\n%s", raw, res.Content)
		}
	}
}

// TestIsBlockedIP unit-tests the SSRF IP classifier directly.
func TestIsBlockedIP(t *testing.T) {
	cases := map[string]bool{
		"127.0.0.1":       true,
		"::1":             true,
		"169.254.169.254": true, // cloud metadata
		"169.254.0.1":     true, // link-local
		"10.1.2.3":        true,
		"172.16.5.4":      true,
		"172.31.255.255":  true,
		"192.168.0.1":     true,
		"100.64.0.1":      true, // CGNAT
		"0.0.0.0":         true, // unspecified
		"224.0.0.1":       true, // multicast
		"fd00::1":         true, // ULA private
		"8.8.8.8":         false,
		"1.1.1.1":         false,
		"172.32.0.1":      false, // just outside 172.16/12
		"100.128.0.1":     false, // just outside CGNAT 100.64/10
		"93.184.216.34":   false, // example.com
	}
	for s, want := range cases {
		ip := net.ParseIP(s)
		if ip == nil {
			t.Fatalf("bad test IP %q", s)
		}
		if got := isBlockedIP(ip); got != want {
			t.Errorf("isBlockedIP(%s) = %v, want %v", s, got, want)
		}
	}
}

// TestValidateURL checks scheme/host enforcement directly.
func TestValidateURL(t *testing.T) {
	ok := []string{"http://example.com", "https://example.com/path?q=1", "https://1.1.1.1/"}
	for _, raw := range ok {
		if _, err := validateURL(raw); err != nil {
			t.Errorf("validateURL(%q) unexpected error: %v", raw, err)
		}
	}
	bad := []string{"", "  ", "ftp://x", "file:///x", "http://127.0.0.1", "javascript:alert(1)", "://nohost"}
	for _, raw := range bad {
		if _, err := validateURL(raw); err == nil {
			t.Errorf("validateURL(%q) expected error, got nil", raw)
		}
	}
}
