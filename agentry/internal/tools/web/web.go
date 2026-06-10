// Package web implements the web-fusion tool family: HTTP fetch, HTML→Markdown
// extraction, and a pluggable search backend. Each is an ordinary tool.Tool, so
// the agent engine registers them and the policy gate mediates them exactly like
// any other capability (filesystem, shell, MCP-proxied, or sub-agent).
//
// Safety is non-negotiable. Every Invoke validates its arguments, bounds its
// work (request timeouts, redirect caps, response-size caps), and never panics
// on bad input — malformed args and remote failures surface as a tool-level
// error (Result.IsError) rather than the error return value, which is reserved
// for genuinely exceptional/transport conditions. Outbound requests are screened
// against obvious SSRF targets (loopback, link-local, and RFC1918 private ranges)
// before any connection is made.
//
// Browser automation (browser.*) is a separate tool family and deliberately not
// implemented here.
package web

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"

	"github.com/kubbot/agentry/internal/core/provider/retry"
	"github.com/kubbot/agentry/internal/core/tool"
)

// Built-in default bounds for the web tools. They are the fallback values for
// the package-level Config; a deployment can override any of them via Configure
// (driven by config/AGENTRY_* env in the CLI) without recompiling.
const (
	// defaultRequestTimeout caps the whole HTTP round trip (connect + headers +
	// body read) for web.fetch / web.extract.
	defaultRequestTimeout = 15 * time.Second

	// defaultMaxRedirectsConst is the largest redirect chain web.fetch will
	// follow before giving up. Each hop is re-screened for SSRF.
	defaultMaxRedirectsConst = 5

	// softMaxBytes caps a fetched response body when the caller doesn't ask for a
	// specific size (1 MiB). Prevents a huge page from blowing up memory/context.
	softMaxBytes = 1 << 20 // 1 MiB
	// defaultHardMaxBytes is the absolute ceiling regardless of the requested
	// max_bytes, unless overridden via Configure.
	defaultHardMaxBytes = 8 << 20 // 8 MiB

	// searchURLEnv names the environment variable holding the search backend URL
	// template. The literal "{q}" in the template is replaced with the
	// URL-encoded query. Kept vendor-neutral on purpose: no default endpoint.
	searchURLEnv = "AGENTRY_SEARCH_URL"
	// userAgent identifies agentry's web tools to remote servers.
	userAgent = "agentry-web/1.0 (+https://github.com/kubbot/agentry)"
)

// Config holds the runtime-tunable bounds for the web tool family. The zero
// value is not used directly; the package initializes its live config from the
// defaults above and Configure merges operator overrides onto it.
type Config struct {
	// RequestTimeout bounds the whole HTTP round trip for a single fetch.
	RequestTimeout time.Duration
	// MaxRedirects caps the redirect chain web.fetch follows (each hop re-screened).
	MaxRedirects int
	// HardMaxBytes is the absolute response-body ceiling, regardless of a
	// caller-supplied max_bytes.
	HardMaxBytes int64
	// Retry governs transient-failure retry/backoff on each outbound hop.
	Retry retry.Policy
}

// defaultConfig returns the built-in web config (matching the historical fixed
// constants), with retry's own default policy.
func defaultConfig() Config {
	return Config{
		RequestTimeout: defaultRequestTimeout,
		MaxRedirects:   defaultMaxRedirectsConst,
		HardMaxBytes:   defaultHardMaxBytes,
		Retry:          retry.DefaultPolicy(),
	}
}

// live is the package-level effective config plus the shared HTTP client built
// from it. Guarded by mu so Configure (called once at startup) and concurrent
// tool Invokes never race. The client is built lazily/eagerly here and reused
// across calls, which both adds connection-pooling (previously a fresh transport
// was created per request) and lets the retry layer wrap one stable transport.
var (
	mu         sync.RWMutex
	cfg        = defaultConfig()
	httpClient = buildClient(cfg)
)

// Configure overrides the web tools' operational bounds. A zero/negative field
// in c leaves the corresponding setting at its current value, so a caller can
// set just the knobs it cares about. It rebuilds the shared HTTP client so the
// new timeout/redirect/retry settings take effect. Safe to call once at startup;
// it is concurrency-safe but intended for the wiring phase, not per-request.
func Configure(c Config) {
	mu.Lock()
	defer mu.Unlock()
	if c.RequestTimeout > 0 {
		cfg.RequestTimeout = c.RequestTimeout
	}
	if c.MaxRedirects > 0 {
		cfg.MaxRedirects = c.MaxRedirects
	}
	if c.HardMaxBytes > 0 {
		cfg.HardMaxBytes = c.HardMaxBytes
	}
	// Retry: adopt the supplied policy (retry.New normalizes non-positive fields
	// to its own defaults, so a partially-filled policy is still well-formed).
	cfg.Retry = c.Retry
	httpClient = buildClient(cfg)
}

// snapshot returns the current effective config and shared client under the read
// lock so an in-flight Invoke sees a consistent pair even if Configure races.
func snapshot() (Config, *http.Client) {
	mu.RLock()
	defer mu.RUnlock()
	return cfg, httpClient
}

// extractByteCap returns the configured absolute body ceiling used to bound both
// fetched and inline HTML in web.extract.
func extractByteCap() int64 {
	c, _ := snapshot()
	if c.HardMaxBytes > 0 {
		return c.HardMaxBytes
	}
	return defaultHardMaxBytes
}

// All returns every web tool, ready for bulk registration by the engine.
func All() []tool.Tool {
	return []tool.Tool{
		&fetchTool{},
		&extractTool{},
		&searchTool{},
	}
}

// ---------------------------------------------------------------------------
// shared helpers
// ---------------------------------------------------------------------------

// decodeArgs unmarshals JSON args into dst, normalizing an empty/nil body to an
// empty object so "no args" doesn't error. Unknown fields are tolerated (a
// strict pass is attempted first to surface obvious typos, then a lenient one).
func decodeArgs(raw json.RawMessage, dst any) error {
	b := bytes.TrimSpace(raw)
	if len(b) == 0 {
		b = []byte("{}")
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		if e2 := json.Unmarshal(b, dst); e2 != nil {
			return err
		}
	}
	return nil
}

// errResult builds a tool-level error Result (model-visible, non-fatal).
func errResult(format string, a ...any) (tool.Result, error) {
	return tool.Result{Content: fmt.Sprintf(format, a...), IsError: true}, nil
}

// ---------------------------------------------------------------------------
// SSRF screening + safe HTTP client
// ---------------------------------------------------------------------------

// errBlockedTarget marks a host/IP rejected by the SSRF screen. It is detected
// via errors.Is on the redirect/dial paths to produce a clear tool error.
var errBlockedTarget = errors.New("blocked target")

// validateURL parses raw and enforces the scheme/host policy: only http(s),
// host must be present, and the host (if a literal IP) must not be a blocked
// SSRF target. Hostnames that resolve to blocked IPs are caught later at dial
// time by safeDialControl, so DNS-rebinding still hits the same guard.
func validateURL(raw string) (*url.URL, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, errors.New("url is required")
	}
	u, err := url.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("invalid url: %w", err)
	}
	switch strings.ToLower(u.Scheme) {
	case "http", "https":
	default:
		return nil, fmt.Errorf("unsupported scheme %q (only http/https allowed)", u.Scheme)
	}
	host := u.Hostname()
	if host == "" {
		return nil, errors.New("url has no host")
	}
	// If the host is a literal IP, screen it up front for a fast, clear error.
	if ip := net.ParseIP(host); ip != nil {
		if screenIP(ip) {
			return nil, fmt.Errorf("%w: address %s is not allowed", errBlockedTarget, ip)
		}
	}
	return u, nil
}

// screenIP reports whether an IP must be refused. It defaults to isBlockedIP and
// is a package var solely so tests can point the web tools at a local httptest
// server (which binds loopback, normally blocked) to exercise the retry/redirect
// machinery end-to-end. Production never reassigns it.
var screenIP = isBlockedIP

// isBlockedIP reports whether an IP is an obvious SSRF target we refuse to
// reach: loopback, link-local (incl. the 169.254.169.254 cloud metadata
// endpoint), unspecified, multicast, and RFC1918 / RFC4193 private ranges.
func isBlockedIP(ip net.IP) bool {
	if ip == nil {
		return true
	}
	if ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsUnspecified() || ip.IsMulticast() || ip.IsInterfaceLocalMulticast() {
		return true
	}
	// Private ranges (10/8, 172.16/12, 192.168/16, fc00::/7).
	if ip.IsPrivate() {
		return true
	}
	// Carrier-grade NAT 100.64.0.0/10 — commonly used for internal infra.
	if ip4 := ip.To4(); ip4 != nil {
		if ip4[0] == 100 && ip4[1]&0xC0 == 0x40 {
			return true
		}
	}
	return false
}

// safeDialControl is installed on the transport's DialContext via net.Dialer's
// Control hook. It runs after DNS resolution with the concrete address being
// dialed, so a hostname that resolves to a private/loopback IP is still blocked
// (defense against DNS rebinding and hostname aliases like "localhost").
func safeDialControl(network, address string, _ syscall.RawConn) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		host = address
	}
	ip := net.ParseIP(host)
	if ip == nil {
		// Address wasn't a literal IP (shouldn't happen post-resolution); refuse
		// rather than risk reaching something we couldn't screen.
		return fmt.Errorf("%w: unresolvable dial address %q", errBlockedTarget, address)
	}
	if screenIP(ip) {
		return fmt.Errorf("%w: address %s is not allowed", errBlockedTarget, ip)
	}
	return nil
}

// buildClient builds an *http.Client whose dialer screens every connection for
// SSRF targets, whose transport is wrapped in the shared retry layer so a
// transient 429/5xx/network blip on any single hop is retried with backoff, and
// whose redirect policy re-validates each hop and caps the chain length. The
// overall deadline is enforced by the caller's context plus the client Timeout.
//
// The retry RoundTripper sits below the redirect-following http.Client: each
// individual request (the original GET and each redirect hop) is retried on a
// transient failure, while multi-hop redirects remain the client's job. GET has
// no body, so it is always safely replayable.
func buildClient(c Config) *http.Client {
	dialer := &net.Dialer{
		Timeout:   10 * time.Second,
		KeepAlive: 10 * time.Second,
		// Control runs with the post-resolution address; reject blocked IPs here.
		Control: safeDialControl,
	}
	base := &http.Transport{
		DialContext:           dialer.DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          10,
		IdleConnTimeout:       30 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		DisableCompression:    false,
	}
	maxRedirects := c.MaxRedirects
	if maxRedirects <= 0 {
		maxRedirects = defaultMaxRedirectsConst
	}
	return &http.Client{
		Timeout:   c.RequestTimeout,
		Transport: retry.New(base, c.Retry),
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= maxRedirects {
				return fmt.Errorf("stopped after %d redirects", maxRedirects)
			}
			// Re-screen each redirect target's scheme/host before following.
			if _, err := validateURL(req.URL.String()); err != nil {
				return err
			}
			return nil
		},
	}
}

// fetchResult is the outcome of a screened HTTP GET.
type fetchResult struct {
	status     int
	statusText string
	finalURL   string
	header     http.Header
	body       []byte
	truncated  bool
}

// doFetch performs a screened, bounded HTTP GET of rawURL, reading at most
// maxBytes of the body. It returns a fetchResult on any HTTP response (including
// 4xx/5xx — those are valid results, not errors); the error return is reserved
// for request construction, transport, and SSRF-block failures.
func doFetch(ctx context.Context, rawURL string, maxBytes int64) (*fetchResult, error) {
	u, err := validateURL(rawURL)
	if err != nil {
		return nil, err
	}

	// Read the effective bounds + shared client once, atomically, so a concurrent
	// Configure can never split the timeout from the client we actually use.
	c, client := snapshot()
	hardMax := c.HardMaxBytes
	if hardMax <= 0 {
		hardMax = defaultHardMaxBytes
	}
	if maxBytes <= 0 {
		maxBytes = softMaxBytes
	}
	if maxBytes > hardMax {
		maxBytes = hardMax
	}

	// Bound the request by both the client Timeout and the caller context.
	reqCtx, cancel := context.WithTimeout(ctx, c.RequestTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.5")

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	// Read up to maxBytes+1 so we can detect (and flag) truncation.
	limited := io.LimitReader(resp.Body, maxBytes+1)
	data, rerr := io.ReadAll(limited)
	if rerr != nil && !errors.Is(rerr, io.EOF) {
		return nil, fmt.Errorf("read body: %w", rerr)
	}
	truncated := int64(len(data)) > maxBytes
	if truncated {
		data = data[:maxBytes]
	}

	return &fetchResult{
		status:     resp.StatusCode,
		statusText: resp.Status,
		finalURL:   resp.Request.URL.String(),
		header:     resp.Header,
		body:       data,
		truncated:  truncated,
	}, nil
}

// describeFetchError converts a transport/SSRF error into a clear tool-level
// message, distinguishing blocked targets and timeouts from generic failures.
func describeFetchError(prefix string, err error) (tool.Result, error) {
	switch {
	case errors.Is(err, errBlockedTarget):
		return errResult("%s: refused (SSRF guard): %v", prefix, err)
	case errors.Is(err, context.DeadlineExceeded):
		c, _ := snapshot()
		return errResult("%s: timed out after %s", prefix, c.RequestTimeout)
	case errors.Is(err, context.Canceled):
		return errResult("%s: canceled", prefix)
	default:
		return errResult("%s: %v", prefix, err)
	}
}

// ---------------------------------------------------------------------------
// web.fetch
// ---------------------------------------------------------------------------

type fetchTool struct{}

func (fetchTool) Name() string { return "web.fetch" }

func (fetchTool) Description() string {
	return "HTTP GET a URL and return its status, response headers, and body. " +
		"Only http/https URLs are allowed; loopback, link-local (incl. cloud " +
		"metadata 169.254.169.254), and private network targets are blocked. " +
		"Follows up to 5 redirects, 15s timeout, body capped (default 1MB, " +
		"override with max_bytes up to 8MB)."
}

func (fetchTool) Schema() json.RawMessage {
	return json.RawMessage(`{
  "type": "object",
  "properties": {
    "url": {
      "type": "string",
      "description": "Absolute http(s) URL to fetch."
    },
    "max_bytes": {
      "type": "integer",
      "description": "Optional cap on body bytes read. Default 1048576 (1MB), hard-capped at 8388608 (8MB).",
      "minimum": 1,
      "maximum": 8388608
    }
  },
  "required": ["url"],
  "additionalProperties": false
}`)
}

func (fetchTool) Invoke(ctx context.Context, in tool.Input) (tool.Result, error) {
	var args struct {
		URL      string `json:"url"`
		MaxBytes int64  `json:"max_bytes"`
	}
	if err := decodeArgs(in.Args, &args); err != nil {
		return errResult("web.fetch: invalid arguments: %v", err)
	}
	if strings.TrimSpace(args.URL) == "" {
		return errResult("web.fetch: url is required")
	}

	res, err := doFetch(ctx, args.URL, args.MaxBytes)
	if err != nil {
		return describeFetchError("web.fetch", err)
	}

	// Render a compact, model-legible view: status line, key headers, then body.
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n", res.statusText)
	fmt.Fprintf(&b, "URL: %s\n", res.finalURL)
	// Emit headers in a stable, readable order.
	writeHeaders(&b, res.header)
	b.WriteString("\n")
	b.Write(res.body)
	if res.truncated {
		fmt.Fprintf(&b, "\n\n[truncated: body larger than the byte cap]")
	}

	return tool.Result{
		Content: b.String(),
		// A 4xx/5xx is a valid result the model should see and reason about; flag
		// it as an error so the loop/policy can treat it as a failed fetch.
		IsError: res.status >= 400,
		Meta: map[string]any{
			"status":       res.status,
			"final_url":    res.finalURL,
			"content_type": res.header.Get("Content-Type"),
			"bytes":        len(res.body),
			"truncated":    res.truncated,
		},
	}, nil
}

// writeHeaders renders a small, stable subset of response headers (the ones a
// model actually reasons about) to keep output bounded and deterministic.
func writeHeaders(b *strings.Builder, h http.Header) {
	for _, key := range []string{
		"Content-Type", "Content-Length", "Location", "Last-Modified",
		"Etag", "Server", "Date", "Cache-Control",
	} {
		if v := h.Get(key); v != "" {
			fmt.Fprintf(b, "%s: %s\n", key, v)
		}
	}
}

// ---------------------------------------------------------------------------
// web.extract
// ---------------------------------------------------------------------------

type extractTool struct{}

func (extractTool) Name() string { return "web.extract" }

func (extractTool) Description() string {
	return "Extract the readable main content of a web page as Markdown-ish " +
		"plain text. Provide either 'url' (fetched with the same safety policy " +
		"as web.fetch) or inline 'html'. Strips script/style/nav/header/footer, " +
		"collapses whitespace, keeps headings as '#', links as [text](href), and " +
		"list items as '- '."
}

func (extractTool) Schema() json.RawMessage {
	return json.RawMessage(`{
  "type": "object",
  "properties": {
    "url": {
      "type": "string",
      "description": "Absolute http(s) URL to fetch and extract. Mutually exclusive with 'html'."
    },
    "html": {
      "type": "string",
      "description": "Raw HTML to extract from directly (offline). Mutually exclusive with 'url'."
    }
  },
  "additionalProperties": false
}`)
}

func (extractTool) Invoke(ctx context.Context, in tool.Input) (tool.Result, error) {
	var args struct {
		URL  string `json:"url"`
		HTML string `json:"html"`
	}
	if err := decodeArgs(in.Args, &args); err != nil {
		return errResult("web.extract: invalid arguments: %v", err)
	}

	hasURL := strings.TrimSpace(args.URL) != ""
	hasHTML := strings.TrimSpace(args.HTML) != ""
	switch {
	case hasURL && hasHTML:
		return errResult("web.extract: provide exactly one of 'url' or 'html', not both")
	case !hasURL && !hasHTML:
		return errResult("web.extract: one of 'url' or 'html' is required")
	}

	var (
		htmlSrc   string
		finalURL  string
		meta      = map[string]any{}
		truncated bool
	)
	if hasURL {
		res, err := doFetch(ctx, args.URL, softMaxBytes)
		if err != nil {
			return describeFetchError("web.extract", err)
		}
		if res.status >= 400 {
			return errResult("web.extract: fetch returned %s", res.statusText)
		}
		htmlSrc = string(res.body)
		finalURL = res.finalURL
		truncated = res.truncated
		meta["status"] = res.status
		meta["final_url"] = res.finalURL
	} else {
		htmlSrc = args.HTML
		// Cap inline HTML at the same configured ceiling fetch uses, so both paths
		// are bounded identically.
		if cap := extractByteCap(); int64(len(htmlSrc)) > cap {
			htmlSrc = htmlSrc[:cap]
			truncated = true
		}
	}

	text, title, err := htmlToText(htmlSrc)
	if err != nil {
		return errResult("web.extract: parse failed: %v", err)
	}
	if title != "" {
		meta["title"] = title
	}
	meta["chars"] = len(text)
	meta["truncated"] = truncated

	out := text
	if title != "" {
		// Lead with the page title as an H1 for readability.
		out = "# " + title + "\n\n" + text
	}
	if truncated {
		out += "\n\n[truncated: source larger than the byte cap]"
	}
	_ = finalURL
	return tool.Result{Content: out, Meta: meta}, nil
}

// ---------------------------------------------------------------------------
// HTML → readable text extractor (dependency-free beyond x/net/html)
// ---------------------------------------------------------------------------

// skipElements are dropped wholesale (element + all descendants) because they
// never carry readable main content.
var skipElements = map[atom.Atom]bool{
	atom.Script:   true,
	atom.Style:    true,
	atom.Noscript: true,
	atom.Nav:      true,
	atom.Header:   true,
	atom.Footer:   true,
	atom.Aside:    true,
	atom.Form:     true,
	atom.Svg:      true,
	atom.Iframe:   true,
	atom.Template: true,
	atom.Button:   true,
}

// htmlToText parses HTML and renders a compact, Markdown-flavored plain-text
// rendering of the main content. It returns the rendered text and the document
// title (if any). The renderer is intentionally small: block elements force
// paragraph breaks, headings get '#' prefixes, list items get '- ', and anchors
// are kept as [text](href). Whitespace is collapsed so the output is readable.
func htmlToText(src string) (text string, title string, err error) {
	doc, err := html.Parse(strings.NewReader(src))
	if err != nil {
		return "", "", err
	}

	var r renderer
	r.walk(doc)
	return r.finish(), strings.TrimSpace(collapseWS(r.title)), nil
}

// renderer accumulates extracted text with lightweight block/inline awareness.
//
// Whitespace model: emission of visible content is deferred through two flags so
// that inter-token spacing and block breaks are correct regardless of how the
// source splits text across nodes/elements.
//   - pendNL (0/1/2): newlines to emit before the next visible token (1 = line
//     break, 2 = paragraph break). Suppressed at the very start of the document.
//   - needSpace: a single separating space is pending (from trailing/leading or
//     pure-whitespace text between inline tokens). Emitted only when mid-line.
//
// lineHas tracks whether the current line already holds visible text, so a
// pending space is dropped at the start of a line.
type renderer struct {
	out       strings.Builder
	title     string
	inTitle   bool
	pendNL    int  // pending newlines before next visible token (0,1,2)
	needSpace bool // a separating space is pending before next visible token
	lineHas   bool // current line already has visible text
}

// headingLevel maps a heading atom to its '#' count, or 0 if not a heading.
func headingLevel(a atom.Atom) int {
	switch a {
	case atom.H1:
		return 1
	case atom.H2:
		return 2
	case atom.H3:
		return 3
	case atom.H4:
		return 4
	case atom.H5:
		return 5
	case atom.H6:
		return 6
	}
	return 0
}

// isBlock reports whether an element should force a paragraph/line break around
// its content.
func isBlock(a atom.Atom) bool {
	switch a {
	case atom.P, atom.Div, atom.Section, atom.Article, atom.Main,
		atom.Ul, atom.Ol, atom.Li, atom.Table, atom.Tr, atom.Blockquote,
		atom.Pre, atom.Figure, atom.Figcaption, atom.Hr,
		atom.H1, atom.H2, atom.H3, atom.H4, atom.H5, atom.H6:
		return true
	}
	return false
}

// walk recursively renders an HTML node tree.
func (r *renderer) walk(n *html.Node) {
	switch n.Type {
	case html.TextNode:
		if r.inTitle {
			r.title += n.Data
			return
		}
		r.writeText(n.Data)
		return

	case html.ElementNode:
		// Drop entire subtrees that never hold main content.
		if skipElements[n.DataAtom] {
			return
		}

		switch n.DataAtom {
		case atom.Title:
			r.inTitle = true
			for c := n.FirstChild; c != nil; c = c.NextSibling {
				r.walk(c)
			}
			r.inTitle = false
			return

		case atom.Br:
			r.lineBreak()
			return

		case atom.Hr:
			r.blockBreak()
			r.writeText("---")
			r.blockBreak()
			return

		case atom.A:
			r.renderAnchor(n)
			return

		case atom.Li:
			// A single newline between items keeps lists tight; the enclosing
			// <ul>/<ol> (a block element) supplies the blank lines around the
			// whole list.
			r.lineBreak()
			r.writeRaw("- ")
			for c := n.FirstChild; c != nil; c = c.NextSibling {
				r.walk(c)
			}
			r.lineBreak()
			return
		}

		if lvl := headingLevel(n.DataAtom); lvl > 0 {
			r.blockBreak()
			r.writeRaw(strings.Repeat("#", lvl) + " ")
			for c := n.FirstChild; c != nil; c = c.NextSibling {
				r.walk(c)
			}
			r.blockBreak()
			return
		}

		block := isBlock(n.DataAtom)
		if block {
			r.blockBreak()
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			r.walk(c)
		}
		if block {
			r.blockBreak()
		}
		return

	default:
		// Document / comment / doctype: descend into children.
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			r.walk(c)
		}
	}
}

// renderAnchor emits an anchor as [text](href), falling back to bare text when
// there's no usable href, and to the href when there's no text.
func (r *renderer) renderAnchor(n *html.Node) {
	href := ""
	for _, a := range n.Attr {
		if strings.EqualFold(a.Key, "href") {
			href = strings.TrimSpace(a.Val)
			break
		}
	}
	// Collect the anchor's inner text via a nested renderer so links never
	// introduce spurious block breaks.
	var inner renderer
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		inner.walk(c)
	}
	label := strings.TrimSpace(collapseWS(inner.out.String()))

	switch {
	case href == "" && label == "":
		return
	case href == "" || strings.HasPrefix(href, "#") || strings.HasPrefix(href, "javascript:"):
		// No meaningful destination — keep just the label as a plain token.
		r.emit(label)
	case label == "":
		r.emit(href)
	default:
		r.emit(fmt.Sprintf("[%s](%s)", label, href))
	}
}

// writeText appends a text node, collapsing internal whitespace. Leading or
// trailing whitespace (and a pure-whitespace node between inline tokens) is
// folded into a single pending separating space rather than emitted directly, so
// spacing stays correct across element boundaries.
func (r *renderer) writeText(s string) {
	if s == "" {
		return
	}
	leadSpace := isSpace(rune(s[0]))
	trailSpace := isSpace(rune(s[len(s)-1]))
	trimmed := strings.TrimSpace(collapseWS(s))
	if trimmed == "" {
		// Pure-whitespace node: remember a separator for the next visible token.
		r.needSpace = true
		return
	}
	if leadSpace {
		r.needSpace = true
	}
	r.emit(trimmed)
	if trailSpace {
		r.needSpace = true
	}
}

// emit writes a visible token, first materializing any pending newlines and a
// pending separating space. It updates line state accordingly.
func (r *renderer) emit(s string) {
	r.flushBreaks()
	if r.needSpace && r.lineHas {
		r.out.WriteByte(' ')
	}
	r.needSpace = false
	r.out.WriteString(s)
	r.lineHas = true
}

// writeRaw appends a literal inline token (e.g. a "- " marker or a formatted
// link) through the same break/space machinery as text.
func (r *renderer) writeRaw(s string) { r.emit(s) }

// lineBreak forces a single newline (used for <br>).
func (r *renderer) lineBreak() {
	if r.pendNL < 1 {
		r.pendNL = 1
	}
	r.needSpace = false
	r.lineHas = false
}

// blockBreak requests a paragraph break (blank line) before the next content.
func (r *renderer) blockBreak() {
	if r.pendNL < 2 {
		r.pendNL = 2
	}
	r.needSpace = false
	r.lineHas = false
}

// flushBreaks materializes any pending newlines, but never at the very start of
// the document (so output doesn't begin with blank lines).
func (r *renderer) flushBreaks() {
	if r.pendNL == 0 {
		return
	}
	if r.out.Len() == 0 {
		// Don't lead the document with blank lines.
		r.pendNL = 0
		return
	}
	for i := 0; i < r.pendNL; i++ {
		r.out.WriteByte('\n')
	}
	r.pendNL = 0
	r.lineHas = false
}

// finish returns the accumulated text with trailing whitespace trimmed and runs
// of >2 blank lines collapsed to exactly one blank line.
func (r *renderer) finish() string {
	s := r.out.String()
	// Collapse any accidental >2 consecutive newlines to a paragraph break.
	for strings.Contains(s, "\n\n\n") {
		s = strings.ReplaceAll(s, "\n\n\n", "\n\n")
	}
	// Trim trailing spaces on each line.
	lines := strings.Split(s, "\n")
	for i, ln := range lines {
		lines[i] = strings.TrimRight(ln, " \t")
	}
	return strings.TrimSpace(strings.Join(lines, "\n"))
}

// collapseWS replaces every run of whitespace (incl. newlines/tabs) with a
// single space. Leading/trailing spaces are preserved as a single space so the
// caller can decide whether they matter.
func collapseWS(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	prevSpace := false
	for _, ru := range s {
		if isSpace(ru) {
			if !prevSpace {
				b.WriteByte(' ')
				prevSpace = true
			}
			continue
		}
		b.WriteRune(ru)
		prevSpace = false
	}
	return b.String()
}

// isSpace reports whether r is ASCII/Unicode whitespace we collapse.
func isSpace(r rune) bool {
	switch r {
	case ' ', '\t', '\n', '\r', '\f', '\v', 0x00A0:
		return true
	}
	return false
}

// ---------------------------------------------------------------------------
// web.search
// ---------------------------------------------------------------------------

type searchTool struct{}

func (searchTool) Name() string { return "web.search" }

func (searchTool) Description() string {
	return "Search the web via a configurable backend. The backend is read from " +
		"the AGENTRY_SEARCH_URL environment variable, a URL template containing " +
		"the literal '{q}' which is replaced with the URL-encoded query. If unset, " +
		"this tool reports that no search backend is configured. No vendor is " +
		"hardcoded."
}

func (searchTool) Schema() json.RawMessage {
	return json.RawMessage(`{
  "type": "object",
  "properties": {
    "query": {
      "type": "string",
      "description": "The search query."
    },
    "limit": {
      "type": "integer",
      "description": "Optional maximum number of results to request/return. Default 5, capped at 20.",
      "minimum": 1,
      "maximum": 20
    }
  },
  "required": ["query"],
  "additionalProperties": false
}`)
}

func (searchTool) Invoke(ctx context.Context, in tool.Input) (tool.Result, error) {
	var args struct {
		Query string `json:"query"`
		Limit int    `json:"limit"`
	}
	if err := decodeArgs(in.Args, &args); err != nil {
		return errResult("web.search: invalid arguments: %v", err)
	}
	query := strings.TrimSpace(args.Query)
	if query == "" {
		return errResult("web.search: query is required")
	}
	limit := args.Limit
	if limit <= 0 {
		limit = 5
	}
	if limit > 20 {
		limit = 20
	}

	tmpl := strings.TrimSpace(getSearchURLTemplate())
	if tmpl == "" {
		// Explicit, clear, vendor-neutral failure — the agent should know it
		// needs configuration rather than silently getting nothing.
		return errResult("web.search: no search backend configured. "+
			"Set the %s environment variable to a URL template containing '{q}' "+
			"(e.g. https://example.com/search?q={q}&format=json) to enable search.",
			searchURLEnv)
	}

	// Build the request URL from the template by substituting the encoded query.
	target := strings.ReplaceAll(tmpl, "{q}", url.QueryEscape(query))
	// Also support an optional {limit} placeholder for backends that take it.
	target = strings.ReplaceAll(target, "{limit}", fmt.Sprintf("%d", limit))

	res, err := doFetch(ctx, target, softMaxBytes)
	if err != nil {
		return describeFetchError("web.search", err)
	}
	if res.status >= 400 {
		return errResult("web.search: backend returned %s", res.statusText)
	}

	// The backend's response shape is unknown (it's pluggable), so return the
	// raw body and let the model parse it. Backends typically return JSON.
	body := string(res.body)
	if res.truncated {
		body += "\n\n[truncated: response larger than the byte cap]"
	}
	return tool.Result{
		Content: body,
		Meta: map[string]any{
			"backend":      hostOf(target),
			"status":       res.status,
			"content_type": res.header.Get("Content-Type"),
			"query":        query,
			"limit":        limit,
			"truncated":    res.truncated,
		},
	}, nil
}

// getSearchURLTemplate reads the search backend template from the environment.
// Split out so tests can stub it without touching process env globally.
var getSearchURLTemplate = func() string {
	return os.Getenv(searchURLEnv)
}

// hostOf returns the host of a URL for metadata, tolerating parse failures.
func hostOf(raw string) string {
	if u, err := url.Parse(raw); err == nil {
		return u.Host
	}
	return ""
}
