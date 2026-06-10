package http

import (
	"net/http"

	"github.com/kubbot/agentry/internal/ui/web"
)

// rootHandler returns the handler mounted at "/": the embedded Web UI when one
// is available, otherwise a tiny built-in status page.
//
// The embedded UI lives in internal/ui/web (DESIGN §4.7 / §11) and exposes
// `func Handler() http.Handler` serving a self-contained SPA. This is the
// single, intentional seam wiring it in. The status-page fallback is retained
// for the (defensive) case where the UI handler is unavailable, so the
// transport is always useful — a human hitting the root in a browser either
// gets the SPA or at least sees that the server is alive.
func rootHandler() http.Handler {
	if h := web.Handler(); h != nil {
		return h
	}
	return http.HandlerFunc(statusPage)
}

// statusPage renders a minimal HTML page confirming the server is running and
// pointing at the JSON API. It only answers the exact root path; any other path
// routed here (the mux uses "/" as a catch-all) gets a 404 so unknown routes are
// not masked by the status page.
func statusPage(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(statusHTML))
}

// statusHTML is the static body of the fallback status page. Kept deliberately
// dependency-free (no template, no external assets) so it works with zero build
// steps.
const statusHTML = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>agentry</title>
  <style>
    body { font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
           background: #0b0b0c; color: #e6e6e6; margin: 0;
           display: flex; min-height: 100vh; align-items: center;
           justify-content: center; }
    .card { max-width: 32rem; padding: 2rem; }
    h1 { font-size: 1.4rem; margin: 0 0 0.25rem; }
    .dot { color: #43d17a; }
    code { background: #1a1a1d; padding: 0.1rem 0.35rem; border-radius: 4px; }
    ul { line-height: 1.9; padding-left: 1.1rem; }
    a { color: #7aa2f7; }
  </style>
</head>
<body>
  <div class="card">
    <h1><span class="dot">&#9679;</span> agentry</h1>
    <p>The HTTP transport is running. No embedded Web UI is mounted; this is the
    built-in status page.</p>
    <p>JSON API:</p>
    <ul>
      <li><code>GET /healthz</code></li>
      <li><code>GET /v1/tools</code></li>
      <li><code>POST /v1/sessions</code></li>
      <li><code>POST /v1/sessions/{id}/messages</code> (SSE)</li>
    </ul>
  </div>
</body>
</html>
`
