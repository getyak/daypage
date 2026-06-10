// Package web is the embedded single-page Web UI for agentry. The entire UI is a
// single self-contained index.html (inline CSS + vanilla JS, no build step),
// compiled into the binary via go:embed so the server can serve a usable chat
// client at "/" with zero external assets and no runtime filesystem dependency.
//
// It is a thin client of the HTTP transport (DESIGN §6 / §11): it POSTs to
// /v1/sessions to create a session, then POSTs /v1/sessions/{id}/messages and
// reads the resulting Server-Sent Events stream (assistant text + tool events),
// rendering them into a chat transcript. No business logic lives here.
//
// The HTTP transport mounts this at "/" by calling Handler() from its
// rootHandler seam; when this package is absent the transport falls back to a
// built-in status page, so the UI is strictly additive.
package web

import (
	"embed"
	"io/fs"
	"net/http"
)

// dist holds the built UI assets embedded into the binary. Today that is a
// single index.html, but the pattern (dist/*) admits additional static files
// (e.g. an icon) without changing the embed directive or the handler.
//
//go:embed dist/*
var dist embed.FS

// Handler returns an http.Handler that serves the embedded SPA: index.html at
// "/" and any other embedded files under their dist-relative paths (e.g.
// "/favicon.ico"). It never returns nil, so the HTTP transport can wire it in
// unconditionally:
//
//	if h := web.Handler(); h != nil { return h }
//
// Unknown paths fall through to the standard library's file server, which
// responds 404 — the transport's mux only routes non-API paths here, so this
// will not shadow the JSON API.
func Handler() http.Handler {
	// Re-root the embedded FS at "dist" so the UI is addressed by its public
	// paths ("/" -> dist/index.html) rather than leaking the "dist/" prefix.
	// fs.Sub failing would mean a broken embed (a build-time guarantee), so the
	// fallback to the raw FS is purely defensive and never expected to run.
	sub, err := fs.Sub(dist, "dist")
	if err != nil {
		return http.FileServer(http.FS(dist))
	}
	return http.FileServer(http.FS(sub))
}
