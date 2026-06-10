// Package browser provides real browser-automation tools driven over the Chrome
// DevTools Protocol via chromedp. Each action — navigate, read, click, type,
// screenshot — is an ordinary tool.Tool so the agent engine registers them and
// the policy gate mediates them exactly like any other capability.
//
// Design: all tools share one lazily-started, headless chromedp allocator +
// browser context, guarded by a mutex and reused across calls for the lifetime
// of the process (a Manager). The first tool call that needs a browser starts
// it; subsequent calls reuse the same tab so navigation state (cookies, current
// URL) persists, mirroring how a human keeps one window open.
//
// Chrome may be ABSENT. Nothing here requires a browser binary at build time,
// and at runtime any failure to launch or drive Chrome (no binary on PATH, a
// crashed process, a navigation error) is reported as a tool-level error
// (Result.IsError) with a helpful message — never a panic and never a returned
// transport error for the common "no browser installed" case. Every Invoke is
// bounded by a timeout and caps the size of any data it returns.
package browser

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/chromedp/chromedp"

	"github.com/kubbot/agentry/internal/core/tool"
)

// Bounds shared across the browser tools.
const (
	// maxReadBytes caps the visible-text payload browser.read returns so a huge
	// page can't blow up context or memory. ~256 KiB of UTF-8 text.
	maxReadBytes = 256 * 1024

	// navTimeout bounds a single navigation (DNS + load + our follow-up reads).
	navTimeout = 45 * time.Second
	// actionTimeout bounds a single click / type / read / screenshot action.
	actionTimeout = 30 * time.Second
	// startupTimeout bounds the very first browser launch + connection. Chrome
	// can be slow to spawn on a cold machine; keep this generous but finite.
	startupTimeout = 30 * time.Second

	// screenshotQuality is the JPEG quality chromedp's FullScreenshot uses when
	// the page is captured as JPEG; 90 is a good size/clarity trade-off. (PNG
	// outputs ignore it.)
	screenshotQuality = 90
)

// ---------------------------------------------------------------------------
// Manager: the shared, lazily-started headless browser
// ---------------------------------------------------------------------------

// Manager owns the process-wide chromedp allocator and a single browser tab,
// created on first use and reused thereafter. It is safe for concurrent use:
// callers serialize through ensure() and the per-action helpers, since a single
// chromedp browser context is not safe for truly concurrent Run calls.
type Manager struct {
	mu sync.Mutex

	allocCtx    context.Context
	allocCancel context.CancelFunc
	browserCtx  context.Context
	browserCanc context.CancelFunc

	// started records whether the browser context has been brought up. We keep
	// it explicit (rather than testing the context for nil) so a failed start
	// can be retried on the next call.
	started bool
}

// defaultManager is the process-wide browser shared by All()'s tools.
var defaultManager = &Manager{}

// ensure lazily starts the allocator + browser context, then verifies the
// browser actually launched by running a trivial action. Chrome being absent or
// unstartable surfaces here as an error, which each tool converts into a
// model-visible Result rather than crashing.
//
// The returned context is the live browser context to run actions against; it
// is owned by the Manager and must NOT be cancelled by callers.
func (m *Manager) ensure(parent context.Context) (context.Context, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.started && m.browserCtx != nil && m.browserCtx.Err() == nil {
		return m.browserCtx, nil
	}

	// A previous attempt may have half-initialized; tear it down before retry so
	// we never leak the old allocator/context.
	m.teardownLocked()

	// Build the allocator. We detach from the request context on purpose: the
	// allocator and browser are process-lived and shared, so binding their
	// lifetime to one tool call's ctx would kill the browser when that call
	// returns. Per-call deadlines are applied to the action contexts instead.
	opts := append([]chromedp.ExecAllocatorOption{}, chromedp.DefaultExecAllocatorOptions[:]...)
	opts = append(opts,
		chromedp.Headless,
		chromedp.DisableGPU,
		// Containers/CI commonly lack the sandbox's required privileges; running
		// without it keeps the tool usable in those environments. Browser content
		// here is agent-driven, not a multi-tenant surface.
		chromedp.NoSandbox,
	)
	// Allow an explicit Chrome path override for unusual installs.
	if p := strings.TrimSpace(os.Getenv("AGENTRY_CHROME_PATH")); p != "" {
		opts = append(opts, chromedp.ExecPath(p))
	}

	allocCtx, allocCancel := chromedp.NewExecAllocator(context.Background(), opts...)
	browserCtx, browserCancel := chromedp.NewContext(allocCtx)

	// Probe with a bounded context so a missing/broken Chrome fails fast instead
	// of hanging. chromedp starts the browser lazily on the first action, so this
	// no-op Run is what actually launches and connects to it.
	probeCtx, probeCancel := context.WithTimeout(browserCtx, startupTimeout)
	defer probeCancel()
	if err := chromedp.Run(probeCtx); err != nil {
		browserCancel()
		allocCancel()
		return nil, fmt.Errorf("could not start headless Chrome (is a Chrome/Chromium binary installed and on PATH? set AGENTRY_CHROME_PATH to override): %w", err)
	}

	m.allocCtx = allocCtx
	m.allocCancel = allocCancel
	m.browserCtx = browserCtx
	m.browserCanc = browserCancel
	m.started = true
	return m.browserCtx, nil
}

// run executes the given chromedp actions against the shared browser under a
// bounded timeout. The Manager mutex is held for the duration so concurrent
// tool calls don't interleave on a single tab.
func (m *Manager) run(parent context.Context, timeout time.Duration, actions ...chromedp.Action) error {
	browserCtx, err := m.ensure(parent)
	if err != nil {
		return err
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	// Re-check liveness under the lock: ensure() released the lock before we
	// reacquired it, so the context could in principle have died meanwhile.
	if browserCtx.Err() != nil {
		m.teardownLocked()
		return fmt.Errorf("browser context closed unexpectedly: %w", browserCtx.Err())
	}

	// Bound the action by the smaller of our timeout and any deadline the caller
	// (the engine) put on parent, by deriving from parent for cancellation while
	// still applying our own timeout.
	runCtx, cancel := context.WithTimeout(browserCtx, timeout)
	defer cancel()
	// Propagate parent cancellation (e.g. the engine aborting the turn) without
	// tying the browser's lifetime to it.
	stop := context.AfterFunc(parent, cancel)
	defer stop()

	if err := chromedp.Run(runCtx, actions...); err != nil {
		// If the whole browser died (not just this action), drop it so the next
		// call starts a fresh one.
		if browserCtx.Err() != nil {
			m.teardownLocked()
		}
		return err
	}
	return nil
}

// teardownLocked cancels and clears the browser/allocator. Caller must hold mu.
func (m *Manager) teardownLocked() {
	if m.browserCanc != nil {
		m.browserCanc()
	}
	if m.allocCancel != nil {
		m.allocCancel()
	}
	m.browserCtx, m.browserCanc = nil, nil
	m.allocCtx, m.allocCancel = nil, nil
	m.started = false
}

// Close shuts down the shared browser and frees Chrome. Safe to call multiple
// times; provided for graceful process shutdown.
func (m *Manager) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.teardownLocked()
}

// ---------------------------------------------------------------------------
// All / shared helpers
// ---------------------------------------------------------------------------

// All returns every browser tool bound to the shared process-wide Manager,
// ready for bulk registration by the engine.
func All() []tool.Tool {
	return AllWith(defaultManager)
}

// AllWith returns the browser tools bound to a specific Manager. Useful for
// tests that want an isolated browser lifecycle.
func AllWith(m *Manager) []tool.Tool {
	return []tool.Tool{
		&navigate{m: m},
		&read{m: m},
		&click{m: m},
		&typeText{m: m},
		&screenshot{m: m},
	}
}

// decodeArgs unmarshals JSON args into dst, normalizing an empty/nil body to an
// empty object so "no args" tools (read, screenshot) don't error.
func decodeArgs(raw json.RawMessage, dst any) error {
	b := bytes.TrimSpace(raw)
	if len(b) == 0 {
		b = []byte("{}")
	}
	// Be lenient with unknown fields: a model occasionally over-specifies args,
	// and that shouldn't hard-fail an otherwise valid call.
	return json.Unmarshal(b, dst)
}

// errResult builds a tool-level error Result (model-visible, non-fatal).
func errResult(format string, a ...any) (tool.Result, error) {
	return tool.Result{Content: fmt.Sprintf(format, a...), IsError: true}, nil
}

// ---------------------------------------------------------------------------
// browser.navigate
// ---------------------------------------------------------------------------

type navigate struct{ m *Manager }

func (navigate) Name() string { return "browser.navigate" }

func (navigate) Description() string {
	return "Open a URL in the shared headless browser and wait for it to load. " +
		"Returns the final URL (after redirects) and the page title. The browser " +
		"tab persists across calls, so subsequent browser.read/click/type act on " +
		"this page."
}

func (navigate) Schema() json.RawMessage {
	return json.RawMessage(`{
  "type": "object",
  "properties": {
    "url": {
      "type": "string",
      "description": "Absolute URL to open (e.g. https://example.com). An http(s):// scheme is added if omitted."
    }
  },
  "required": ["url"],
  "additionalProperties": false
}`)
}

func (n navigate) Invoke(ctx context.Context, in tool.Input) (tool.Result, error) {
	var args struct {
		URL string `json:"url"`
	}
	if err := decodeArgs(in.Args, &args); err != nil {
		return errResult("browser.navigate: invalid arguments: %v", err)
	}
	url := strings.TrimSpace(args.URL)
	if url == "" {
		return errResult("browser.navigate: url is required")
	}
	// Default the scheme so "example.com" works like a browser address bar.
	if !strings.Contains(url, "://") {
		url = "https://" + url
	}

	var finalURL, title string
	err := n.m.run(ctx, navTimeout,
		chromedp.Navigate(url),
		chromedp.Location(&finalURL),
		chromedp.Title(&title),
	)
	if err != nil {
		return errResult("browser.navigate: failed to open %q: %v", url, friendly(err))
	}

	content := fmt.Sprintf("Navigated to %s\nTitle: %s", finalURL, title)
	return tool.Result{
		Content: content,
		Meta: map[string]any{
			"url":   finalURL,
			"title": title,
		},
	}, nil
}

// ---------------------------------------------------------------------------
// browser.read
// ---------------------------------------------------------------------------

type read struct{ m *Manager }

func (read) Name() string { return "browser.read" }

func (read) Description() string {
	return "Return the visible text content of the current page in the headless " +
		"browser (the rendered text of <body>). Output is capped at ~256KB. Call " +
		"browser.navigate first to load a page."
}

func (read) Schema() json.RawMessage {
	return json.RawMessage(`{
  "type": "object",
  "properties": {},
  "additionalProperties": false
}`)
}

func (r read) Invoke(ctx context.Context, in tool.Input) (tool.Result, error) {
	// No args; still validate to reject malformed bodies cleanly.
	var args struct{}
	if err := decodeArgs(in.Args, &args); err != nil {
		return errResult("browser.read: invalid arguments: %v", err)
	}

	var text string
	// chromedp.Text on the body's innerText yields the rendered, visible text.
	err := r.m.run(ctx, actionTimeout,
		chromedp.Text("body", &text, chromedp.ByQuery, chromedp.NodeReady),
	)
	if err != nil {
		return errResult("browser.read: failed to read page text: %v", friendly(err))
	}

	truncated := false
	if len(text) > maxReadBytes {
		// Trim on a UTF-8 boundary so we never split a rune.
		text = safeTruncate(text, maxReadBytes)
		truncated = true
	}
	content := text
	if strings.TrimSpace(content) == "" {
		content = "(no visible text on the current page)"
	}
	if truncated {
		content += fmt.Sprintf("\n\n[truncated: page text larger than %d bytes]", maxReadBytes)
	}

	return tool.Result{
		Content: content,
		Meta: map[string]any{
			"bytes":     len(text),
			"truncated": truncated,
		},
	}, nil
}

// ---------------------------------------------------------------------------
// browser.click
// ---------------------------------------------------------------------------

type click struct{ m *Manager }

func (click) Name() string { return "browser.click" }

func (click) Description() string {
	return "Click the first element matching a CSS selector on the current page. " +
		"Waits for the element to be visible first. Call browser.navigate to load " +
		"a page before clicking."
}

func (click) Schema() json.RawMessage {
	return json.RawMessage(`{
  "type": "object",
  "properties": {
    "selector": {
      "type": "string",
      "description": "CSS selector of the element to click (e.g. \"button.submit\", \"#login\", \"a[href='/next']\")."
    }
  },
  "required": ["selector"],
  "additionalProperties": false
}`)
}

func (c click) Invoke(ctx context.Context, in tool.Input) (tool.Result, error) {
	var args struct {
		Selector string `json:"selector"`
	}
	if err := decodeArgs(in.Args, &args); err != nil {
		return errResult("browser.click: invalid arguments: %v", err)
	}
	sel := strings.TrimSpace(args.Selector)
	if sel == "" {
		return errResult("browser.click: selector is required")
	}

	err := c.m.run(ctx, actionTimeout,
		// WaitVisible avoids racing the click ahead of the element existing;
		// Click then targets the first matching, visible node.
		chromedp.Click(sel, chromedp.ByQuery, chromedp.NodeVisible),
	)
	if err != nil {
		return errResult("browser.click: could not click %q: %v", sel, friendly(err))
	}

	return tool.Result{
		Content: fmt.Sprintf("clicked %s", sel),
		Meta:    map[string]any{"selector": sel},
	}, nil
}

// ---------------------------------------------------------------------------
// browser.type
// ---------------------------------------------------------------------------

type typeText struct{ m *Manager }

func (typeText) Name() string { return "browser.type" }

func (typeText) Description() string {
	return "Type text into the first input/textarea/editable element matching a " +
		"CSS selector on the current page. Waits for the element to be visible, " +
		"focuses it, and sends the keystrokes (appending to any existing value)."
}

func (typeText) Schema() json.RawMessage {
	return json.RawMessage(`{
  "type": "object",
  "properties": {
    "selector": {
      "type": "string",
      "description": "CSS selector of the field to type into (e.g. \"input[name='q']\", \"#search\", \"textarea\")."
    },
    "text": {
      "type": "string",
      "description": "Text to type into the field."
    }
  },
  "required": ["selector", "text"],
  "additionalProperties": false
}`)
}

func (t typeText) Invoke(ctx context.Context, in tool.Input) (tool.Result, error) {
	var args struct {
		Selector string `json:"selector"`
		Text     string `json:"text"`
	}
	if err := decodeArgs(in.Args, &args); err != nil {
		return errResult("browser.type: invalid arguments: %v", err)
	}
	sel := strings.TrimSpace(args.Selector)
	if sel == "" {
		return errResult("browser.type: selector is required")
	}
	// Empty text is a valid no-op-ish request; allow it but note nothing typed.

	err := t.m.run(ctx, actionTimeout,
		chromedp.SendKeys(sel, args.Text, chromedp.ByQuery, chromedp.NodeVisible),
	)
	if err != nil {
		return errResult("browser.type: could not type into %q: %v", sel, friendly(err))
	}

	return tool.Result{
		Content: fmt.Sprintf("typed %d character(s) into %s", len([]rune(args.Text)), sel),
		Meta: map[string]any{
			"selector": sel,
			"chars":    len([]rune(args.Text)),
		},
	}, nil
}

// ---------------------------------------------------------------------------
// browser.screenshot
// ---------------------------------------------------------------------------

type screenshot struct{ m *Manager }

func (screenshot) Name() string { return "browser.screenshot" }

func (screenshot) Description() string {
	return "Capture a full-page screenshot of the current page and save it to disk " +
		"as a PNG. If no path is given, a timestamped file under " +
		"~/.agentry/screenshots is used. Returns the saved path (also in Meta.path)."
}

func (screenshot) Schema() json.RawMessage {
	return json.RawMessage(`{
  "type": "object",
  "properties": {
    "path": {
      "type": "string",
      "description": "Optional destination file path for the PNG. Defaults to a timestamped file under ~/.agentry/screenshots."
    }
  },
  "additionalProperties": false
}`)
}

func (s screenshot) Invoke(ctx context.Context, in tool.Input) (tool.Result, error) {
	var args struct {
		Path string `json:"path"`
	}
	if err := decodeArgs(in.Args, &args); err != nil {
		return errResult("browser.screenshot: invalid arguments: %v", err)
	}

	dest, err := resolveScreenshotPath(args.Path)
	if err != nil {
		return errResult("browser.screenshot: %v", err)
	}

	var buf []byte
	if err := s.m.run(ctx, actionTimeout, chromedp.FullScreenshot(&buf, screenshotQuality)); err != nil {
		return errResult("browser.screenshot: capture failed: %v", friendly(err))
	}
	if len(buf) == 0 {
		return errResult("browser.screenshot: capture produced no image data")
	}

	if err := os.WriteFile(dest, buf, 0o644); err != nil {
		return errResult("browser.screenshot: could not write %q: %v", dest, err)
	}

	return tool.Result{
		Content: fmt.Sprintf("saved full-page screenshot (%d bytes) to %s", len(buf), dest),
		Meta: map[string]any{
			"path":  dest,
			"bytes": len(buf),
		},
	}, nil
}

// resolveScreenshotPath picks the output path: the caller's path when given
// (with parent dirs created), otherwise a timestamped PNG under
// ~/.agentry/screenshots (falling back to the OS temp dir if $HOME is unknown).
func resolveScreenshotPath(p string) (string, error) {
	p = strings.TrimSpace(p)
	if p != "" {
		abs, err := filepath.Abs(p)
		if err != nil {
			return "", fmt.Errorf("invalid path %q: %w", p, err)
		}
		if dir := filepath.Dir(abs); dir != "" {
			if err := os.MkdirAll(dir, 0o755); err != nil {
				return "", fmt.Errorf("cannot create directory %q: %w", dir, err)
			}
		}
		return abs, nil
	}

	dir := defaultScreenshotDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("cannot create screenshot directory %q: %w", dir, err)
	}
	name := fmt.Sprintf("screenshot-%s.png", time.Now().Format("20060102-150405.000"))
	return filepath.Join(dir, name), nil
}

// defaultScreenshotDir returns ~/.agentry/screenshots, falling back to a
// temp-dir location when the home directory cannot be determined.
func defaultScreenshotDir() string {
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		return filepath.Join(home, ".agentry", "screenshots")
	}
	return filepath.Join(os.TempDir(), "agentry", "screenshots")
}

// ---------------------------------------------------------------------------
// misc helpers
// ---------------------------------------------------------------------------

// safeTruncate returns at most max bytes of s without splitting a UTF-8 rune.
func safeTruncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	// Back up to a rune boundary (continuation bytes are 0b10xxxxxx).
	i := max
	for i > 0 && (s[i]&0xC0) == 0x80 {
		i--
	}
	return s[:i]
}

// friendly normalizes common chromedp/context errors into a clearer message for
// the model, while preserving the underlying error text.
func friendly(err error) error {
	if err == nil {
		return nil
	}
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return fmt.Errorf("timed out: %w", err)
	case errors.Is(err, context.Canceled):
		return fmt.Errorf("canceled before completion: %w", err)
	default:
		return err
	}
}
