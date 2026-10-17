import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { supabaseMemoStore, type QueryBuilderLike } from "@/lib/memos/store";
import { parseHistoryQuery } from "@/lib/memos/query";
import { fetchMemoHistory, type AttachmentView } from "@/lib/memos/history";
import { fetchTagCatalogue } from "@/lib/memos/tags";
import { loginRedirectTarget } from "@/lib/memos/redirects";
import { formatDayKey, formatTimeOfDay, formatWeekday } from "@/lib/memos/format";
import type { MemoType } from "@/lib/memos/types";
import { MemoTags } from "./_components/MemoTags";
import { TagFilter } from "./_components/TagFilter";

// URL-driven SSR history: search/filter/pagination all live in the query
// string, so keyboard and native back/forward behavior work without client
// state. Reads are request-scoped (verified uid + RLS + user_id predicates);
// nothing is cached across users or requests.

export const dynamic = "force-dynamic";

const TYPE_OPTIONS: ReadonlyArray<{ value: MemoType; label: string }> = [
  { value: "text", label: "Text" },
  { value: "url", label: "URL" },
  { value: "voice", label: "Voice" },
  { value: "photo", label: "Photo" },
  { value: "file", label: "File" },
];

function excerpt(body: string, max = 220): string {
  const collapsed = body.replace(/\s+/g, " ").trim();
  return collapsed.length > max ? `${collapsed.slice(0, max)}…` : collapsed;
}

function formatSize(bytes: number | null): string | null {
  if (bytes === null || !Number.isFinite(bytes) || bytes <= 0) return null;
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function AttachmentChips({ attachments }: { attachments: AttachmentView[] }) {
  if (attachments.length === 0) return null;
  const firstImage = attachments.find((a) => a.preview === "image" && a.available);
  const others = attachments.filter((a) => a !== firstImage);
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 8, flexWrap: "wrap" }}>
      {firstImage && (
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={firstImage.url}
          alt={firstImage.filename ?? "Attachment"}
          loading="lazy"
          style={{
            width: 56,
            height: 56,
            objectFit: "cover",
            borderRadius: 8,
            background: "var(--surface-sunken)",
          }}
        />
      )}
      {others.map((a) => (
        <span
          key={a.id}
          style={{
            fontSize: "0.72rem",
            color: a.available ? "var(--fg-muted)" : "var(--fg-subtle)",
            background: "var(--surface-sunken)",
            borderRadius: 999,
            padding: "3px 10px",
            fontFamily: "var(--font-mono)",
            letterSpacing: "0.4px",
          }}
          title={a.filename ?? undefined}
        >
          {a.preview === "audio" ? "AUDIO" : a.preview === "video" ? "VIDEO" : a.preview === "image" ? "IMAGE" : "FILE"}
          {formatSize(a.size_bytes) ? ` · ${formatSize(a.size_bytes)}` : ""}
          {a.available ? "" : " · unavailable"}
        </span>
      ))}
    </div>
  );
}

function Panel({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div
      style={{
        margin: "16px 24px",
        padding: "18px 20px",
        borderRadius: 14,
        border: "0.5px solid var(--border-default)",
        background: "var(--surface-white)",
      }}
    >
      <div style={{ fontWeight: 600, marginBottom: 6 }}>{title}</div>
      <div style={{ fontSize: "0.875rem", color: "var(--fg-muted)", lineHeight: 1.6 }}>{children}</div>
    </div>
  );
}

export default async function MemosHistoryPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const params = await searchParams;
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // Preserve the full intended destination (including search state) when the
  // request is anonymous.
  const queryEntries = Object.entries(params).filter(([, v]) => typeof v === "string") as Array<
    [string, string]
  >;
  const queryString = new URLSearchParams(queryEntries).toString();
  if (!user) redirect(loginRedirectTarget(`/memos${queryString ? `?${queryString}` : ""}`));

  const parsed = parseHistoryQuery(params);
  const store = supabaseMemoStore({
    from: (table) => supabase.from(table) as unknown as QueryBuilderLike,
  });

  // Complete exact tag catalogue (including unused labels). On failure we show
  // an honest error — an empty selector must never pose as "no tags".
  const catalogue = await fetchTagCatalogue(store, user.id);

  let body: React.ReactNode;
  if (catalogue.rows === null) {
    body = (
      <Panel title="Tags are unavailable right now">
        <p style={{ margin: 0 }}>
          The tag catalogue could not be read and nothing was changed. Please try again.
        </p>
        <p style={{ marginTop: 10 }}>
          <Link href="/memos" className="memo-link">
            Try again
          </Link>
        </p>
      </Panel>
    );
  } else if (!parsed.ok) {
    body = (
      <Panel title="Search parameters are not valid">
        <ul style={{ margin: "6px 0 0", paddingLeft: 18 }}>
          {parsed.errors.map((error) => (
            <li key={error}>{error}</li>
          ))}
        </ul>
        <p style={{ marginTop: 10 }}>
          <Link href="/memos" className="memo-link">
            Reset the search
          </Link>
        </p>
      </Panel>
    );
  } else {
    const result = await fetchMemoHistory(store, user.id, parsed.query);
    if (!result.ok) {
      body = (
        <Panel title="History is unavailable right now">
          <p style={{ margin: 0 }}>
            The history backend did not respond and nothing was changed. Please try again.
          </p>
          <p style={{ marginTop: 10 }}>
            <Link href="/memos" className="memo-link">
              Try again
            </Link>
          </p>
        </Panel>
      );
    } else if (result.items.length === 0) {
      const hasFilters =
        parsed.query.q !== null ||
        parsed.query.tag !== null ||
        parsed.query.type !== null ||
        parsed.query.fromIso !== null ||
        parsed.query.toIso !== null;
      body = (
        <Panel title={hasFilters ? "No memos match these filters" : "No memos yet"}>
          <p style={{ margin: 0 }}>
            {hasFilters
              ? "Try different search text, a wider date range, or clear the filters."
              : "Memos you capture will show up here, newest first."}
          </p>
          {hasFilters && (
            <p style={{ marginTop: 10 }}>
              <Link href="/memos" className="memo-link">
                Clear filters
              </Link>
            </p>
          )}
        </Panel>
      );
    } else {
      // Group by Asia/Shanghai calendar day (display only — stored timestamps
      // and server-date grouping elsewhere are untouched).
      const groups: Array<{ key: string; label: string; items: typeof result.items }> = [];
      for (const item of result.items) {
        const key = formatDayKey(item.created_at) ?? item.created_at.slice(0, 10);
        const label = [formatWeekday(item.created_at), key].filter(Boolean).join(" · ");
        const last = groups[groups.length - 1];
        if (last && last.key === key) last.items.push(item);
        else groups.push({ key, label, items: [item] });
      }

      const pageParams = new URLSearchParams();
      for (const [key, value] of Object.entries(params)) {
        if (typeof value === "string" && key !== "cursor") pageParams.set(key, value);
      }
      const olderHref = result.nextCursor
        ? `/memos?${(() => {
            const p = new URLSearchParams(pageParams);
            p.set("cursor", result.nextCursor);
            return p.toString();
          })()}`
        : null;

      body = (
        <>
          <div style={{ padding: "0 24px" }}>
            {groups.map((group) => (
              <section key={group.key} style={{ marginBottom: 18 }}>
                <h2
                  style={{
                    fontFamily: "var(--font-mono)",
                    fontSize: 10,
                    letterSpacing: "1.6px",
                    textTransform: "uppercase",
                    color: "var(--fg-subtle)",
                    margin: "18px 0 10px",
                    fontWeight: 700,
                  }}
                >
                  {group.label}
                </h2>
                <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
                  {group.items.map((item) => (
                    <article
                      key={item.id}
                      style={{
                        background: "var(--surface-white)",
                        border: "0.5px solid var(--border-default)",
                        borderRadius: 14,
                        padding: "14px 16px",
                      }}
                    >
                      <div
                        style={{
                          display: "flex",
                          alignItems: "center",
                          gap: 10,
                          marginBottom: 6,
                        }}
                      >
                        <span
                          style={{
                            fontFamily: "var(--font-mono)",
                            fontSize: "0.72rem",
                            color: "var(--fg-subtle)",
                            letterSpacing: "0.6px",
                          }}
                        >
                          {formatTimeOfDay(item.created_at) ?? ""}
                        </span>
                        <span
                          style={{
                            fontSize: "0.66rem",
                            textTransform: "uppercase",
                            letterSpacing: "1px",
                            color: "var(--fg-muted)",
                            background: "var(--surface-sunken)",
                            borderRadius: 999,
                            padding: "2px 8px",
                          }}
                        >
                          {item.type}
                        </span>
                        <Link
                          href={`/memos/${item.id}`}
                          className="memo-link"
                          style={{ marginLeft: "auto", fontSize: "0.78rem", color: "var(--accent)" }}
                        >
                          Open
                        </Link>
                      </div>
                      <Link
                        href={`/memos/${item.id}`}
                        style={{
                          display: "block",
                          fontSize: "0.925rem",
                          lineHeight: 1.65,
                          color: "var(--fg-primary)",
                          textDecoration: "none",
                          whiteSpace: "pre-line",
                          wordBreak: "break-word",
                        }}
                      >
                        {excerpt(item.presentationBody ?? item.body) ||
                          (item.presentationBody === "" ? (
                            // Verified generated-media-only body (ADR-0026):
                            // short fallback beside the existing thumbnail/chips.
                            <span style={{ color: "var(--fg-subtle)", fontStyle: "italic" }}>
                              Media
                            </span>
                          ) : (
                            <span style={{ color: "var(--fg-subtle)", fontStyle: "italic" }}>
                              No content
                            </span>
                          ))}
                      </Link>
                      <MemoTags tags={item.tags} />
                      <AttachmentChips attachments={item.attachments} />
                    </article>
                  ))}
                </div>
              </section>
            ))}
          </div>

          {result.hasMore && olderHref && (
            <div style={{ padding: "8px 24px 32px", display: "flex", justifyContent: "center" }}>
              <Link href={olderHref} className="btn btn--soft btn--sm">
                Older memos →
              </Link>
            </div>
          )}
        </>
      );
    }
  }

  return (
    <div style={{ maxWidth: 720, margin: "0 auto", width: "100%" }}>
      <div style={{ padding: "24px 24px 8px" }}>
        <h1
          style={{
            fontFamily: "var(--font-fraunces), var(--font-family-serif), serif",
            fontSize: 26,
            fontWeight: 500,
            letterSpacing: "-0.01em",
            margin: "0 0 4px",
            color: "var(--fg-primary)",
          }}
        >
          History
        </h1>
        <p style={{ fontSize: "0.85rem", color: "var(--fg-subtle)", margin: "0 0 16px" }}>
          All memos, newest first. Times shown in Asia/Shanghai.
        </p>

        <form
          key={JSON.stringify([params.q, params.type, params.tag, params.from, params.to])}
          method="get"
          action="/memos"
          style={{
            display: "flex",
            flexWrap: "wrap",
            gap: 8,
            alignItems: "center",
            marginBottom: 8,
          }}
        >
          <input
            type="search"
            name="q"
            defaultValue={typeof params.q === "string" ? params.q : ""}
            placeholder="Search memo text…"
            aria-label="Search memo text"
            maxLength={200}
            style={{
              flex: "2 1 220px",
              padding: "8px 12px",
              borderRadius: 10,
              border: "0.5px solid var(--border-default)",
              background: "var(--surface-white)",
              fontSize: "0.875rem",
              color: "var(--fg-primary)",
            }}
          />
          <select
            name="type"
            defaultValue={typeof params.type === "string" ? params.type : ""}
            aria-label="Filter by type"
            style={{
              padding: "8px 10px",
              borderRadius: 10,
              border: "0.5px solid var(--border-default)",
              background: "var(--surface-white)",
              fontSize: "0.875rem",
              color: "var(--fg-primary)",
            }}
          >
            <option value="">All types</option>
            {TYPE_OPTIONS.map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </select>
          {catalogue.rows !== null && (
            <TagFilter
              catalogue={catalogue.rows}
              value={typeof params.tag === "string" && params.tag !== "" ? params.tag : null}
            />
          )}
          <input
            type="date"
            name="from"
            defaultValue={typeof params.from === "string" ? params.from : ""}
            aria-label="From date"
            style={{
              padding: "7px 10px",
              borderRadius: 10,
              border: "0.5px solid var(--border-default)",
              background: "var(--surface-white)",
              fontSize: "0.825rem",
              color: "var(--fg-primary)",
            }}
          />
          <input
            type="date"
            name="to"
            defaultValue={typeof params.to === "string" ? params.to : ""}
            aria-label="To date"
            style={{
              padding: "7px 10px",
              borderRadius: 10,
              border: "0.5px solid var(--border-default)",
              background: "var(--surface-white)",
              fontSize: "0.825rem",
              color: "var(--fg-primary)",
            }}
          />
          <button type="submit" className="btn btn--primary btn--sm">
            Search
          </button>
          {(params.q || params.tag || params.type || params.from || params.to) && (
            <Link href="/memos" className="btn btn--soft btn--sm">
              Clear
            </Link>
          )}
        </form>
      </div>

      {body}
    </div>
  );
}
