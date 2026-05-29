"use client";

import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import {
  Inbox,
  Rss,
  Mail,
  Webhook,
  Plus,
  Trash2,
  Check,
  Copy,
} from "lucide-react";
import { Btn, Card, SectionLabel } from "@/components/ui";

// US-020: surface the already-built inbound connectors (email / rss / webhook)
// in Settings so data can flow into DayPage passively. RSS feeds are stored as
// `ingest_sources` rows (config encrypted via secret-crypto) through the
// existing /api/ingest-sources endpoint; fetch-rss.ts picks them up on its cron.

interface IngestSource {
  id: string;
  name: string;
  source_type: string;
  config: Record<string, unknown>;
  enabled: boolean;
  default_ingest_mode: "light" | "full";
  created_at: string;
}

const inputStyle: React.CSSProperties = {
  flex: 1,
  minWidth: 0,
  padding: "0.4rem 0.75rem",
  border: "1px solid var(--accent-border)",
  borderRadius: "var(--radius-sm, 6px)",
  background: "var(--surface-1)",
  color: "var(--fg-primary)",
  fontSize: "0.875rem",
};

const codeStyle: React.CSSProperties = {
  fontSize: "0.75rem",
  wordBreak: "break-all",
};

// ── Data hooks ─────────────────────────────────────────────────────────
function useIngestSources() {
  return useQuery<IngestSource[]>({
    queryKey: ["ingest-sources"],
    queryFn: async () => {
      const res = await fetch("/api/ingest-sources");
      if (!res.ok) throw new Error("Failed to fetch ingest sources");
      return res.json() as Promise<IngestSource[]>;
    },
  });
}

function useAddRssFeed() {
  const qc = useQueryClient();
  return useMutation<
    IngestSource,
    Error,
    { name: string; url: string; default_ingest_mode: "light" | "full" }
  >({
    mutationFn: async ({ name, url, default_ingest_mode }) => {
      const res = await fetch("/api/ingest-sources", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name,
          source_type: "rss",
          // The feed URL is stored inside the encrypted config blob — fetch-rss.ts
          // reads `config.url` after decrypting.
          config: { url },
          enabled: true,
          // US-022: memos from this feed default to the chosen compile tier.
          default_ingest_mode,
        }),
      });
      if (!res.ok) {
        const err = (await res.json().catch(() => ({}))) as { error?: string };
        throw new Error(err.error ?? "Failed to add feed");
      }
      return res.json() as Promise<IngestSource>;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ["ingest-sources"] }),
  });
}

function useDeleteSource() {
  const qc = useQueryClient();
  return useMutation<void, Error, string>({
    mutationFn: async (id) => {
      const res = await fetch(`/api/ingest-sources/${id}`, { method: "DELETE" });
      if (!res.ok && res.status !== 204) throw new Error("Failed to remove source");
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ["ingest-sources"] }),
  });
}

// ── Component ──────────────────────────────────────────────────────────
export function SourcesSection() {
  const { data: sources, isLoading } = useIngestSources();
  const addFeed = useAddRssFeed();
  const remove = useDeleteSource();

  const [feedName, setFeedName] = useState("");
  const [feedUrl, setFeedUrl] = useState("");
  // US-022: RSS is a low-signal firehose, so "light" is the sensible default.
  const [feedMode, setFeedMode] = useState<"light" | "full">("light");

  const rssFeeds = (sources ?? []).filter((s) => s.source_type === "rss");

  // The personal forwarding address & inbound webhook URL are derived from the
  // public app origin (set NEXT_PUBLIC_APP_URL in prod; localhost in dev).
  const appOrigin =
    process.env.NEXT_PUBLIC_APP_URL ??
    (typeof window !== "undefined" ? window.location.origin : "http://localhost:3000");
  const inboundEmail = "inbound@daypage.app";
  const inboundUrl = `${appOrigin.replace(/\/$/, "")}/api/ingest/email`;

  async function handleAddFeed() {
    const url = feedUrl.trim();
    if (!url) return;
    const name = feedName.trim() || hostFromUrl(url);
    await addFeed.mutateAsync({ name, url, default_ingest_mode: feedMode });
    setFeedName("");
    setFeedUrl("");
    setFeedMode("light");
  }

  async function handleRemoveFeed(id: string) {
    if (typeof window !== "undefined") {
      const ok = window.confirm("Remove this RSS feed? New items won't be ingested.");
      if (!ok) return;
    }
    await remove.mutateAsync(id);
  }

  return (
    <div className="mt-32 settings-section">
      <SectionLabel
        right={<span className="settings-section-hint">passive inbound data</span>}
      >
        <span className="settings-section-title">
          <Inbox size={14} strokeWidth={1.8} />
          Sources
        </span>
      </SectionLabel>

      {/* Email */}
      <Card>
        <div className="settings-row">
          <div className="settings-row-text">
            <div
              className="settings-row-label"
              style={{ display: "flex", alignItems: "center", gap: 6 }}
            >
              <Mail size={14} strokeWidth={1.8} />
              Email
            </div>
            <div className="settings-row-desc">
              Forward any email to your personal inbound address and the body
              becomes a memo. Subject lines turn into the memo title.
            </div>
          </div>
        </div>
        <div className="divider" />
        <div className="settings-row" style={{ gap: 8, alignItems: "center" }}>
          <code style={{ ...codeStyle, ...inputStyle, fontFamily: "var(--font-mono, monospace)" }}>
            {inboundEmail}
          </code>
          <CopyBtn value={inboundEmail} label="Copy address" />
        </div>
      </Card>

      {/* RSS */}
      <div style={{ marginTop: 16 }}>
      <Card>
        <div className="settings-row">
          <div className="settings-row-text">
            <div
              className="settings-row-label"
              style={{ display: "flex", alignItems: "center", gap: 6 }}
            >
              <Rss size={14} strokeWidth={1.8} />
              RSS feeds
            </div>
            <div className="settings-row-desc">
              DayPage polls each feed every 30 minutes and saves new items as
              memos. Add as many as you like.
            </div>
          </div>
        </div>
        <div className="divider" />

        {isLoading ? (
          <div className="settings-row" style={{ color: "var(--fg-subtle)", fontSize: "0.8125rem" }}>
            Loading…
          </div>
        ) : rssFeeds.length > 0 ? (
          rssFeeds.map((feed) => (
            <div key={feed.id} className="settings-row" style={{ alignItems: "center" }}>
              <div className="settings-row-text" style={{ minWidth: 0 }}>
                <div className="settings-row-label" style={{ display: "flex", alignItems: "center", gap: 6 }}>
                  <Check size={13} style={{ color: "var(--color-success, #22c55e)" }} />
                  {feed.name}
                </div>
                <div className="settings-row-desc" style={{ wordBreak: "break-all" }}>
                  {/* config is redacted server-side; the name carries the host */}
                  {feed.enabled ? "Active" : "Paused"} · {feed.default_ingest_mode === "full" ? "Full" : "Light"} compile · added{" "}
                  {new Date(feed.created_at).toLocaleDateString()}
                </div>
              </div>
              <div className="settings-row-control">
                <Btn
                  kind="ghost"
                  size="sm"
                  icon={<Trash2 size={14} />}
                  onClick={() => handleRemoveFeed(feed.id)}
                  disabled={remove.isPending}
                >
                  Remove
                </Btn>
              </div>
            </div>
          ))
        ) : (
          <div className="settings-row" style={{ color: "var(--fg-subtle)", fontSize: "0.8125rem" }}>
            No feeds yet.
          </div>
        )}

        <div className="divider" />
        <div className="settings-row" style={{ flexDirection: "column", gap: 8, alignItems: "stretch" }}>
          <div style={{ display: "flex", gap: 8 }}>
            <input
              type="text"
              placeholder="Name (optional)"
              value={feedName}
              onChange={(e) => setFeedName(e.target.value)}
              style={{ ...inputStyle, flex: "0 0 30%" }}
            />
            <input
              type="url"
              placeholder="https://example.com/feed.xml"
              value={feedUrl}
              onChange={(e) => setFeedUrl(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && handleAddFeed()}
              style={inputStyle}
            />
            <select
              value={feedMode}
              onChange={(e) => setFeedMode(e.target.value as "light" | "full")}
              aria-label="Compile tier"
              title="Compile tier for memos from this feed"
              style={{ ...inputStyle, flex: "0 0 8rem" }}
            >
              <option value="light">Light</option>
              <option value="full">Full</option>
            </select>
          </div>
          <div>
            <Btn
              kind="primary"
              size="sm"
              icon={<Plus size={14} />}
              onClick={handleAddFeed}
              disabled={!feedUrl.trim() || addFeed.isPending}
            >
              {addFeed.isPending ? "Adding…" : "Add feed"}
            </Btn>
          </div>
          {addFeed.isError && (
            <div style={{ color: "var(--color-error, #ef4444)", fontSize: "0.8125rem" }}>
              {addFeed.error?.message}
            </div>
          )}
        </div>
      </Card>
      </div>

      {/* Webhook (inbound) */}
      <div style={{ marginTop: 16 }}>
      <Card>
        <div className="settings-row">
          <div className="settings-row-text">
            <div
              className="settings-row-label"
              style={{ display: "flex", alignItems: "center", gap: 6 }}
            >
              <Webhook size={14} strokeWidth={1.8} />
              Inbound webhook
            </div>
            <div className="settings-row-desc">
              POST JSON to your inbound URL to create memos from any service
              (Zapier, n8n, scripts…). Authenticate with an API key in the{" "}
              <code style={{ fontSize: "0.75rem" }}>Authorization: Bearer …</code>{" "}
              header — generate one in the API Keys section below. The key is your
              secret; never embed it in client-side code.
            </div>
          </div>
        </div>
        <div className="divider" />
        <div className="settings-row" style={{ gap: 8, alignItems: "center" }}>
          <code style={{ ...codeStyle, ...inputStyle, fontFamily: "var(--font-mono, monospace)" }}>
            POST {inboundUrl}
          </code>
          <CopyBtn value={inboundUrl} label="Copy URL" />
        </div>
      </Card>
      </div>
    </div>
  );
}

// ── Helpers ────────────────────────────────────────────────────────────
function hostFromUrl(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return "RSS feed";
  }
}

function CopyBtn({ value, label }: { value: string; label: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <Btn
      kind="soft"
      size="sm"
      icon={copied ? <Check size={14} /> : <Copy size={14} />}
      onClick={() => {
        if (typeof navigator !== "undefined" && navigator.clipboard) {
          navigator.clipboard.writeText(value).then(
            () => setCopied(true),
            () => setCopied(false),
          );
        }
      }}
    >
      {copied ? "Copied" : label}
    </Btn>
  );
}
