"use client";

import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Bookmark, Copy, Check, Info } from "lucide-react";
import { Btn, Card, SectionLabel } from "@/components/ui";

// US-021: Browser clipping (bookmarklet). Generate a one-click "Clip to DayPage"
// bookmarklet that POSTs the current page URL + title + any selected text to
// /api/ingest (key-auth). Clipped content enters the normal compilation pipeline
// as a memo. The bookmarklet sends only the selected snippet when text is
// highlighted, otherwise it captures the whole-page reference (title + URL).

interface ApiKeyRecord {
  id: string;
  name: string;
  key_prefix: string;
  scopes: string[];
}

function useWriteKeys() {
  return useQuery<ApiKeyRecord[]>({
    queryKey: ["api-keys"],
    queryFn: async () => {
      const res = await fetch("/api/keys");
      if (!res.ok) throw new Error("Failed to fetch keys");
      return res.json() as Promise<ApiKeyRecord[]>;
    },
  });
}

// Build the bookmarklet source. The raw API key is embedded directly because a
// bookmarklet runs entirely client-side and has no server to hold a secret —
// this is the standard trade-off for clip bookmarklets. We keep the body terse
// and self-contained (no external deps) so it survives the URL-encoding.
function buildBookmarklet(origin: string, apiKey: string): string {
  // `s` = selected text (snippet-only clip when present); falls back to a
  // whole-page reference. Errors surface as an alert so the user gets feedback.
  const src = `(function(){
var s=(window.getSelection?String(window.getSelection()):'').trim();
var b={source:'web-clipper',type:'memo',payload:{title:document.title,source_url:location.href,selection:s}};
fetch('${origin}/api/ingest',{method:'POST',headers:{'Content-Type':'application/json','Authorization':'Bearer ${apiKey}'},body:JSON.stringify(b)})
.then(function(r){if(!r.ok)throw r;alert('Clipped to DayPage'+(s?' (selection)':''));})
.catch(function(){alert('DayPage clip failed — check your API key.');});
})();`;
  // Collapse whitespace so the href stays a single line, then URI-encode.
  return "javascript:" + encodeURIComponent(src.replace(/\n/g, ""));
}

export function ClipperSection() {
  const { data: keys = [], isLoading } = useWriteKeys();
  const [selectedKeyId, setSelectedKeyId] = useState<string>("");
  const [rawKey, setRawKey] = useState("");
  const [copied, setCopied] = useState(false);

  const writeKeys = useMemo(
    () =>
      keys.filter(
        (k) => k.scopes?.includes("write") || k.scopes?.includes("admin")
      ),
    [keys]
  );

  const origin =
    typeof window !== "undefined" ? window.location.origin : "https://daypage.app";

  const effectiveKey = rawKey.trim();
  const bookmarklet = effectiveKey
    ? buildBookmarklet(origin, effectiveKey)
    : "";

  async function handleCopy() {
    if (!bookmarklet) return;
    await navigator.clipboard.writeText(bookmarklet).catch(() => undefined);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  return (
    <div className="mt-32 settings-section">
      <SectionLabel
        right={<span className="settings-section-hint">one-click web clipping</span>}
      >
        <span className="settings-section-title">
          <Bookmark size={14} strokeWidth={1.8} />
          Browser Clipper
        </span>
      </SectionLabel>

      <Card>
        <div className="settings-row" style={{ flexDirection: "column", alignItems: "stretch", gap: "0.75rem" }}>
          <div className="settings-row-text">
            <div className="settings-row-label">Clip the web into DayPage</div>
            <div className="settings-row-desc">
              Paste a <strong>write</strong>-scoped API key below to generate a bookmarklet.
              Drag the button to your bookmarks bar — clicking it on any page clips the
              URL and title (or just your highlighted text) straight into your inbox,
              where it&apos;s compiled like any other memo.
            </div>
          </div>

          {isLoading ? (
            <div style={{ color: "var(--fg-subtle)", fontSize: "0.8125rem" }}>Loading keys…</div>
          ) : writeKeys.length === 0 ? (
            <div
              style={{
                display: "flex",
                gap: 8,
                alignItems: "flex-start",
                fontSize: "0.8125rem",
                color: "var(--fg-subtle)",
              }}
            >
              <Info size={14} style={{ marginTop: 2, flexShrink: 0 }} />
              <span>
                No write-scoped API key found. Create one in the <strong>API Keys</strong>{" "}
                section below (enable the <code>write</code> scope), then paste the raw key
                here. Keys are shown only once at creation.
              </span>
            </div>
          ) : (
            <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
              {writeKeys.map((k) => (
                <button
                  key={k.id}
                  type="button"
                  onClick={() => setSelectedKeyId(k.id)}
                  className={`settings-segmented-item ${selectedKeyId === k.id ? "is-active" : ""}`}
                  style={{ fontSize: "0.75rem" }}
                  title={`${k.key_prefix}… · ${(k.scopes ?? []).join(", ")}`}
                >
                  <code style={{ marginRight: 4 }}>{k.key_prefix}…</code>
                  {k.name}
                </button>
              ))}
            </div>
          )}

          <div>
            <label
              htmlFor="clipper-key"
              style={{ display: "block", fontSize: "0.8125rem", fontWeight: 500, marginBottom: 6 }}
            >
              {selectedKeyId
                ? "Paste the raw key for the selected entry"
                : "Write-scoped API key"}
            </label>
            <input
              id="clipper-key"
              type="password"
              autoComplete="off"
              placeholder="paste your raw API key (sk_… / 64-char hex)"
              value={rawKey}
              onChange={(e) => setRawKey(e.target.value)}
              style={{
                width: "100%",
                padding: "0.5rem 0.75rem",
                border: "1px solid var(--accent-border)",
                borderRadius: "var(--radius-sm, 6px)",
                background: "var(--surface-1)",
                color: "var(--fg-primary)",
                fontSize: "0.875rem",
                fontFamily: "monospace",
                boxSizing: "border-box",
              }}
            />
            <div style={{ fontSize: "0.75rem", color: "var(--fg-subtle)", marginTop: 4 }}>
              The key is embedded in the bookmarklet and never leaves your browser until
              you click it. Treat the generated bookmarklet like a password.
            </div>
          </div>

          {bookmarklet && (
            <div style={{ display: "flex", flexDirection: "column", gap: "0.5rem" }}>
              <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
                <a
                  href={bookmarklet}
                  className="btn btn--primary btn--sm"
                  onClick={(e) => e.preventDefault()}
                  draggable
                  title="Drag me to your bookmarks bar"
                  style={{ cursor: "grab" }}
                >
                  <span className="btn__icon">
                    <Bookmark size={14} />
                  </span>
                  Clip to DayPage
                </a>
                <span style={{ fontSize: "0.75rem", color: "var(--fg-subtle)" }}>
                  ← drag this to your bookmarks bar
                </span>
              </div>
              <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <Btn
                  kind="soft"
                  size="sm"
                  icon={copied ? <Check size={14} /> : <Copy size={14} />}
                  onClick={handleCopy}
                >
                  {copied ? "Copied!" : "Copy bookmarklet code"}
                </Btn>
                <span style={{ fontSize: "0.75rem", color: "var(--fg-subtle)" }}>
                  or copy the <code>javascript:</code> URL and add it as a bookmark manually
                </span>
              </div>
            </div>
          )}
        </div>
      </Card>
    </div>
  );
}
