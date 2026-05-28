import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { memos, memo_attachments, users, page_sources, pages, annotations } from "@/lib/db/schema";
import { eq, and, inArray } from "drizzle-orm";
import { notFound } from "next/navigation";
import Link from "next/link";
import { MemoActions } from "./MemoActions";
import { MemoDetailTopBar } from "./MemoDetailTopBar";
import { MemoDetailTitle } from "./MemoDetailTitle";
import { MetadataTiles } from "./MetadataTiles";
import { HeroPhoto } from "./HeroPhoto";

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

function extractWeatherString(weather: unknown): string | null {
  if (!weather) return null;
  if (typeof weather === "string") return weather;
  if (typeof weather === "object" && weather !== null) {
    const w = weather as Record<string, unknown>;
    // Try common weather JSON shapes
    if (typeof w.description === "string") return w.description;
    if (typeof w.condition === "string") return w.condition;
    if (typeof w.weather === "string") return w.weather;
    return JSON.stringify(weather);
  }
  return String(weather);
}

function extractHumidityString(weather: unknown): string | null {
  if (!weather || typeof weather !== "object") return null;
  const w = weather as Record<string, unknown>;
  if (typeof w.humidity === "number") return `${w.humidity}%`;
  if (typeof w.humidity === "string") return w.humidity;
  return null;
}

function extractLocationString(location: unknown): string | null {
  if (!location) return null;
  if (typeof location === "string") return location;
  if (typeof location === "object" && location !== null) {
    const l = location as Record<string, unknown>;
    const parts: string[] = [];
    if (typeof l.city === "string") parts.push(l.city);
    if (typeof l.country === "string") parts.push(l.country);
    if (parts.length) return parts.join(", ");
    if (typeof l.name === "string") return l.name;
  }
  return null;
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

  // Load photo attachment if present
  const photoAttachments = await db
    .select()
    .from(memo_attachments)
    .where(and(eq(memo_attachments.memo_id, id), eq(memo_attachments.kind, "photo")))
    .limit(1);
  const photoAttachment = photoAttachments[0] ?? null;

  // Annotations attach to pages (via page_id), not memos.
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

  const weatherStr = extractWeatherString(memo.weather);
  const humidityStr = extractHumidityString(memo.weather);
  const locationStr = extractLocationString(memo.location);
  const createdAtISO = memo.created_at.toISOString();

  // Extract exif dimensions if available
  const exif = photoAttachment?.exif as Record<string, unknown> | null ?? null;
  const photoWidth = typeof exif?.width === "number" ? exif.width : null;
  const photoHeight = typeof exif?.height === "number" ? exif.height : null;

  return (
    <div style={{ maxWidth: 600, margin: "0 auto" }}>
      {/* US-012: Sticky glass top bar */}
      <MemoDetailTopBar createdAt={createdAtISO} />

      <div style={{ padding: "0 0 40px" }}>
        {/* US-013: Title block */}
        <MemoDetailTitle
          place={locationStr}
          kind={memo.type}
          location={locationStr}
        />

        {/* US-014: Metadata tiles */}
        <MetadataTiles
          weather={weatherStr}
          humidity={humidityStr}
          kind={memo.type}
          createdAt={createdAtISO}
        />

        {/* US-015: Hero photo */}
        {photoAttachment && (
          <HeroPhoto
            src={`/api/img/${photoAttachment.storage_key}`}
            filename={photoAttachment.filename}
            width={photoWidth as number | null}
            height={photoHeight as number | null}
            alt={photoAttachment.ocr_text ?? null}
          />
        )}

        {/* Body */}
        <div style={{ padding: "0 14px 24px" }}>
          <div
            style={{
              background: "var(--surface-sunken)",
              borderRadius: 12,
              padding: "16px 20px",
              lineHeight: 1.7,
              fontSize: "0.9375rem",
              whiteSpace: "pre-wrap",
              wordBreak: "break-word",
            }}
          >
            {memo.body || (
              <span style={{ color: "var(--fg-subtle)", fontStyle: "italic" }}>No content</span>
            )}
          </div>
        </div>

        {/* Actions row */}
        <div style={{ padding: "0 14px 24px", display: "flex", justifyContent: "flex-end" }}>
          <MemoActions memoId={id} compileStatus={memo.compile_status} />
        </div>

        {/* Metadata grid */}
        <div style={{ padding: "0 14px 24px" }}>
          <div
            style={{
              display: "grid",
              gridTemplateColumns: "repeat(auto-fill, minmax(200px, 1fr))",
              gap: 12,
            }}
          >
            {memo.source_url &&
              (() => {
                const safe = safeHref(memo.source_url);
                return (
                  <div
                    style={{
                      background: "var(--surface-white)",
                      border: "0.5px solid var(--border-default)",
                      borderRadius: 10,
                      padding: "10px 14px",
                    }}
                  >
                    <div
                      style={{
                        fontSize: "0.7rem",
                        color: "var(--fg-subtle)",
                        textTransform: "uppercase",
                        fontWeight: 600,
                        marginBottom: 4,
                      }}
                    >
                      Source URL
                    </div>
                    {safe ? (
                      <a
                        href={safe}
                        target="_blank"
                        rel="noopener noreferrer"
                        style={{
                          fontSize: "0.8125rem",
                          color: "var(--accent)",
                          wordBreak: "break-all",
                        }}
                      >
                        {memo.source_url}
                      </a>
                    ) : (
                      <span
                        style={{
                          fontSize: "0.8125rem",
                          color: "var(--fg-subtle)",
                          wordBreak: "break-all",
                        }}
                        title="Blocked: non-http(s) URL"
                      >
                        {memo.source_url}
                      </span>
                    )}
                  </div>
                );
              })()}
            {memo.device && (
              <div
                style={{
                  background: "var(--surface-white)",
                  border: "0.5px solid var(--border-default)",
                  borderRadius: 10,
                  padding: "10px 14px",
                }}
              >
                <div
                  style={{
                    fontSize: "0.7rem",
                    color: "var(--fg-subtle)",
                    textTransform: "uppercase",
                    fontWeight: 600,
                    marginBottom: 4,
                  }}
                >
                  Device
                </div>
                <div style={{ fontSize: "0.8125rem" }}>{memo.device}</div>
              </div>
            )}
            {!!memo.weather && (
              <div
                style={{
                  background: "var(--surface-white)",
                  border: "0.5px solid var(--border-default)",
                  borderRadius: 10,
                  padding: "10px 14px",
                }}
              >
                <div
                  style={{
                    fontSize: "0.7rem",
                    color: "var(--fg-subtle)",
                    textTransform: "uppercase",
                    fontWeight: 600,
                    marginBottom: 4,
                  }}
                >
                  Weather
                </div>
                <div style={{ fontSize: "0.8125rem" }}>{String(memo.weather)}</div>
              </div>
            )}
            <div
              style={{
                background: "var(--surface-white)",
                border: "0.5px solid var(--border-default)",
                borderRadius: 10,
                padding: "10px 14px",
              }}
            >
              <div
                style={{
                  fontSize: "0.7rem",
                  color: "var(--fg-subtle)",
                  textTransform: "uppercase",
                  fontWeight: 600,
                  marginBottom: 4,
                }}
              >
                Origin
              </div>
              <div style={{ fontSize: "0.8125rem" }}>
                {memo.origin} · {memo.ingest_mode}
              </div>
            </div>
            <div
              style={{
                background: "var(--surface-white)",
                border: "0.5px solid var(--border-default)",
                borderRadius: 10,
                padding: "10px 14px",
              }}
            >
              <div
                style={{
                  fontSize: "0.7rem",
                  color: "var(--fg-subtle)",
                  textTransform: "uppercase",
                  fontWeight: 600,
                  marginBottom: 4,
                }}
              >
                Status
              </div>
              <div
                style={{
                  fontSize: "0.8125rem",
                  color: statusColor[memo.compile_status] ?? "var(--fg-subtle)",
                }}
              >
                {memo.compile_status}
              </div>
            </div>
            {memo.compile_error && (
              <div
                style={{
                  background: "var(--surface-white)",
                  border: "0.5px solid var(--error, #ef4444)",
                  borderRadius: 10,
                  padding: "10px 14px",
                  gridColumn: "1 / -1",
                }}
              >
                <div
                  style={{
                    fontSize: "0.7rem",
                    color: "var(--error, #ef4444)",
                    textTransform: "uppercase",
                    fontWeight: 600,
                    marginBottom: 4,
                  }}
                >
                  Compile Error
                </div>
                <div
                  style={{
                    fontSize: "0.8125rem",
                    color: "var(--fg-muted)",
                    fontFamily: "var(--font-mono)",
                    whiteSpace: "pre-wrap",
                  }}
                >
                  {memo.compile_error}
                </div>
              </div>
            )}
          </div>
        </div>

        {/* Linked pages */}
        {linkedPages.length > 0 && (
          <div style={{ padding: "0 14px 24px" }}>
            <div
              style={{
                fontSize: "0.7rem",
                fontWeight: 600,
                textTransform: "uppercase",
                letterSpacing: "0.04em",
                color: "var(--fg-subtle)",
                marginBottom: 10,
              }}
            >
              Linked pages ({linkedPages.length})
            </div>
            <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
              {linkedPages.map((lp) => (
                <Link
                  key={lp.page_id}
                  href={`/wiki/${lp.page_slug}`}
                  style={{
                    display: "inline-flex",
                    alignItems: "center",
                    gap: 6,
                    padding: "5px 12px",
                    borderRadius: 999,
                    background: "var(--accent-soft)",
                    color: "var(--accent)",
                    fontSize: "0.8125rem",
                    textDecoration: "none",
                  }}
                >
                  <span
                    style={{
                      fontSize: "0.65rem",
                      opacity: 0.7,
                      textTransform: "uppercase",
                    }}
                  >
                    {lp.page_type}
                  </span>
                  {lp.page_title}
                </Link>
              ))}
            </div>
          </div>
        )}

        {/* Annotations */}
        {memoAnnotations.length > 0 && (
          <div style={{ padding: "0 14px" }}>
            <div
              style={{
                fontSize: "0.7rem",
                fontWeight: 600,
                textTransform: "uppercase",
                letterSpacing: "0.04em",
                color: "var(--fg-subtle)",
                marginBottom: 10,
              }}
            >
              Annotations ({memoAnnotations.length})
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
              {memoAnnotations.map((a) => (
                <div
                  key={a.id}
                  style={{
                    background: "var(--surface-white)",
                    border: "0.5px solid var(--border-default)",
                    borderRadius: 10,
                    padding: "10px 14px",
                  }}
                >
                  <div style={{ fontSize: "0.7rem", color: "var(--fg-subtle)", marginBottom: 4 }}>
                    {a.tag}
                  </div>
                  {a.note && <div style={{ fontSize: "0.8125rem" }}>{a.note}</div>}
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
