import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { memos, users, page_sources, pages, annotations } from "@/lib/db/schema";
import { eq, and, inArray } from "drizzle-orm";
import { notFound } from "next/navigation";
import Link from "next/link";
import { MemoActions } from "./MemoActions";

// Defense in depth: even though /api/ingest now rejects non-http(s) source_url,
// pre-existing rows could contain `javascript:` URIs. Guard the href render.
function safeHref(url: string | null | undefined): string | null {
  if (!url) return null;
  try {
    const u = new URL(url);
    return u.protocol === "http:" || u.protocol === "https:" ? url : null;
  } catch {
    return null;
  }
}

type Props = { params: Promise<{ id: string }> };

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db.select({ id: users.id }).from(users).where(eq(users.email, email)).limit(1);
  return rows[0]?.id ?? null;
}

function relativeTime(date: Date): string {
  const diffMs = Date.now() - date.getTime();
  const diffMin = Math.floor(diffMs / 60_000);
  if (diffMin < 1) return "just now";
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffH = Math.floor(diffMin / 60);
  if (diffH < 24) return `${diffH}h ago`;
  const diffD = Math.floor(diffH / 24);
  if (diffD === 1) return "yesterday";
  return `${diffD}d ago`;
}

export default async function MemoDetailPage({ params }: Props) {
  const { id } = await params;
  const session = await auth();
  if (!session?.user?.email) notFound();

  const userId = await resolveUserId(session.user.email);
  if (!userId) notFound();

  const memoRows = await db
    .select()
    .from(memos)
    .where(and(eq(memos.id, id), eq(memos.user_id, userId)))
    .limit(1);

  const memo = memoRows[0];
  if (!memo) notFound();

  // Annotations attach to pages (via page_id), not memos. To scope them to
  // this memo, first find the pages it sourced, then load annotations on
  // those pages only. Previously the query filtered solely by user_id and
  // would surface unrelated annotations from any other page the user owned.
  const linkedPages = await db
    .select({
      page_id: page_sources.page_id,
      page_title: pages.title,
      page_slug: pages.slug,
      page_type: pages.type,
    })
    .from(page_sources)
    .innerJoin(pages, eq(page_sources.page_id, pages.id))
    .where(eq(page_sources.memo_id, id));

  const linkedPageIds = linkedPages.map((p) => p.page_id);
  const memoAnnotations =
    linkedPageIds.length > 0
      ? await db
          .select()
          .from(annotations)
          .where(
            and(
              eq(annotations.user_id, userId),
              inArray(annotations.page_id, linkedPageIds)
            )
          )
          .limit(20)
      : [];

  const statusColor: Record<string, string> = {
    pending: "var(--fg-subtle)",
    running: "var(--accent)",
    done: "var(--success, #22c55e)",
    failed: "var(--error, #ef4444)",
  };

  return (
    <div className="page" style={{ maxWidth: 800 }}>
      {/* Breadcrumb */}
      <div style={{ display: "flex", alignItems: "center", gap: 6, marginBottom: 24, fontSize: "0.8rem", color: "var(--fg-subtle)" }}>
        <Link href="/home" style={{ color: "var(--fg-subtle)" }}>Home</Link>
        <span>/</span>
        <Link href="/add" style={{ color: "var(--fg-subtle)" }}>Sources</Link>
        <span>/</span>
        <span style={{ color: "var(--fg)" }}>Memo</span>
      </div>

      {/* Header */}
      <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between", gap: 16, marginBottom: 24 }}>
        <div>
          <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 8 }}>
            <span style={{ fontSize: "0.7rem", fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.04em", padding: "2px 8px", borderRadius: 999, background: "var(--surface-sunken)", color: "var(--fg-muted)" }}>
              {memo.type}
            </span>
            <span style={{ fontSize: "0.75rem", padding: "2px 8px", borderRadius: 999, background: "var(--surface-sunken)", color: statusColor[memo.compile_status] ?? "var(--fg-subtle)" }}>
              {memo.compile_status}
            </span>
            <span style={{ fontSize: "0.75rem", color: "var(--fg-subtle)" }}>
              {relativeTime(memo.created_at)}
            </span>
          </div>
          <h1 style={{ fontSize: "1.25rem", fontWeight: 600, margin: 0, lineHeight: 1.4 }}>
            {memo.body.slice(0, 80) || "(empty memo)"}
          </h1>
        </div>

        {/* US-007 actions */}
        <MemoActions memoId={id} compileStatus={memo.compile_status} />
      </div>

      {/* Body */}
      <div style={{ background: "var(--surface-sunken)", borderRadius: 8, padding: "16px 20px", marginBottom: 24, lineHeight: 1.7, fontSize: "0.9375rem", whiteSpace: "pre-wrap", wordBreak: "break-word" }}>
        {memo.body || <span style={{ color: "var(--fg-subtle)", fontStyle: "italic" }}>No content</span>}
      </div>

      {/* Metadata */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(200px, 1fr))", gap: 12, marginBottom: 24 }}>
        {memo.source_url && (() => {
          const safe = safeHref(memo.source_url);
          return (
            <div style={{ background: "var(--surface)", border: "1px solid var(--border)", borderRadius: 8, padding: "10px 14px" }}>
              <div style={{ fontSize: "0.7rem", color: "var(--fg-subtle)", textTransform: "uppercase", fontWeight: 600, marginBottom: 4 }}>Source URL</div>
              {safe ? (
                <a href={safe} target="_blank" rel="noopener noreferrer" style={{ fontSize: "0.8125rem", color: "var(--accent)", wordBreak: "break-all" }}>
                  {memo.source_url}
                </a>
              ) : (
                <span style={{ fontSize: "0.8125rem", color: "var(--fg-subtle)", wordBreak: "break-all" }} title="Blocked: non-http(s) URL">
                  {memo.source_url}
                </span>
              )}
            </div>
          );
        })()}
        {memo.device && (
          <div style={{ background: "var(--surface)", border: "1px solid var(--border)", borderRadius: 8, padding: "10px 14px" }}>
            <div style={{ fontSize: "0.7rem", color: "var(--fg-subtle)", textTransform: "uppercase", fontWeight: 600, marginBottom: 4 }}>Device</div>
            <div style={{ fontSize: "0.8125rem" }}>{memo.device}</div>
          </div>
        )}
        {!!memo.weather && (
          <div style={{ background: "var(--surface)", border: "1px solid var(--border)", borderRadius: 8, padding: "10px 14px" }}>
            <div style={{ fontSize: "0.7rem", color: "var(--fg-subtle)", textTransform: "uppercase", fontWeight: 600, marginBottom: 4 }}>Weather</div>
            <div style={{ fontSize: "0.8125rem" }}>{String(memo.weather)}</div>
          </div>
        )}
        <div style={{ background: "var(--surface)", border: "1px solid var(--border)", borderRadius: 8, padding: "10px 14px" }}>
          <div style={{ fontSize: "0.7rem", color: "var(--fg-subtle)", textTransform: "uppercase", fontWeight: 600, marginBottom: 4 }}>Origin</div>
          <div style={{ fontSize: "0.8125rem" }}>{memo.origin} · {memo.ingest_mode}</div>
        </div>
        {memo.compile_error && (
          <div style={{ background: "var(--surface)", border: "1px solid var(--error, #ef4444)", borderRadius: 8, padding: "10px 14px", gridColumn: "1 / -1" }}>
            <div style={{ fontSize: "0.7rem", color: "var(--error, #ef4444)", textTransform: "uppercase", fontWeight: 600, marginBottom: 4 }}>Compile Error</div>
            <div style={{ fontSize: "0.8125rem", color: "var(--fg-muted)", fontFamily: "var(--font-mono)", whiteSpace: "pre-wrap" }}>{memo.compile_error}</div>
          </div>
        )}
      </div>

      {/* Linked pages */}
      {linkedPages.length > 0 && (
        <div style={{ marginBottom: 24 }}>
          <div style={{ fontSize: "0.7rem", fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.04em", color: "var(--fg-subtle)", marginBottom: 10 }}>
            Linked pages ({linkedPages.length})
          </div>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
            {linkedPages.map((lp) => (
              <Link
                key={lp.page_id}
                href={`/wiki/${lp.page_slug}`}
                style={{ display: "inline-flex", alignItems: "center", gap: 6, padding: "5px 12px", borderRadius: 999, background: "var(--accent-soft)", color: "var(--accent)", fontSize: "0.8125rem", textDecoration: "none" }}
              >
                <span style={{ fontSize: "0.65rem", opacity: 0.7, textTransform: "uppercase" }}>{lp.page_type}</span>
                {lp.page_title}
              </Link>
            ))}
          </div>
        </div>
      )}

      {/* Annotations */}
      {memoAnnotations.length > 0 && (
        <div>
          <div style={{ fontSize: "0.7rem", fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.04em", color: "var(--fg-subtle)", marginBottom: 10 }}>
            Annotations ({memoAnnotations.length})
          </div>
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            {memoAnnotations.map((a) => (
              <div key={a.id} style={{ background: "var(--surface)", border: "1px solid var(--border)", borderRadius: 8, padding: "10px 14px" }}>
                <div style={{ fontSize: "0.7rem", color: "var(--fg-subtle)", marginBottom: 4 }}>{a.tag}</div>
                {a.note && <div style={{ fontSize: "0.8125rem" }}>{a.note}</div>}
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
