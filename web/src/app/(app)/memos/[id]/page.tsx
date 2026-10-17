import { notFound, redirect } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { supabaseMemoStore, type QueryBuilderLike } from "@/lib/memos/store";
import { fetchMemoDetail } from "@/lib/memos/detail";
import { loginRedirectTarget } from "@/lib/memos/redirects";
import { isUuid } from "@/lib/memos/query";
import { MemoDetailTopBar } from "./MemoDetailTopBar";
import { MemoDetailTitle } from "./MemoDetailTitle";
import { MetadataTiles } from "./MetadataTiles";
import { MemoAttachments } from "../_components/MemoAttachments";
import { MemoTags } from "../_components/MemoTags";
import { MemoBody } from "./MemoBody";
import { LocationCard } from "./LocationCard";
import { FileMetadataCard } from "./FileMetadataCard";

// READ-ONLY memo detail (ADR-0022). Identity is the verified Supabase
// auth uid (never email); reads go through the cookie-bound SSR client with
// RLS and explicit user_id predicates — no Drizzle/DATABASE_URL. This page
// intentionally wires no edit/delete/pin/share actions.

type Props = { params: Promise<{ id: string }> };

// Defense in depth: pre-existing rows could contain `javascript:` URIs.
function safeHref(url: string | null | undefined): string | null {
  if (!url) return null;
  try {
    const u = new URL(url);
    return u.protocol === "http:" || u.protocol === "https:" ? url : null;
  } catch {
    return null;
  }
}

function extractWeatherString(weather: unknown): string | null {
  if (!weather) return null;
  if (typeof weather === "string") return weather;
  if (typeof weather === "object" && weather !== null) {
    const w = weather as Record<string, unknown>;
    if (typeof w.description === "string") return w.description;
    if (typeof w.condition === "string") return w.condition;
    if (typeof w.weather === "string") return w.weather;
    return null;
  }
  return null;
}

function extractHumidityString(weather: unknown): string | null {
  if (!weather || typeof weather !== "object") return null;
  const w = weather as Record<string, unknown>;
  if (typeof w.humidity === "number") return `${w.humidity}%`;
  if (typeof w.humidity === "string") return w.humidity;
  return null;
}

function extractLocationFields(location: unknown): {
  lat: number | null;
  lng: number | null;
  place_name: string | null;
  country: string | null;
  display: string | null;
} {
  if (!location || typeof location !== "object") {
    return { lat: null, lng: null, place_name: null, country: null, display: null };
  }
  const l = location as Record<string, unknown>;
  const parts: string[] = [];
  if (typeof l.city === "string") parts.push(l.city);
  if (typeof l.country === "string") parts.push(l.country);
  return {
    lat: typeof l.lat === "number" ? l.lat : typeof l.latitude === "number" ? l.latitude : null,
    lng: typeof l.lng === "number" ? l.lng : typeof l.longitude === "number" ? l.longitude : null,
    place_name:
      typeof l.place_name === "string"
        ? l.place_name
        : typeof l.name === "string"
          ? l.name
          : typeof l.city === "string"
            ? l.city
            : null,
    country: typeof l.country === "string" ? l.country : null,
    display: parts.length > 0 ? parts.join(", ") : typeof l.name === "string" ? l.name : null,
  };
}

export default async function MemoDetailPage({ params }: Props) {
  const { id } = await params;
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect(loginRedirectTarget(`/memos/${encodeURIComponent(id)}`));
  if (!isUuid(id)) notFound();

  const store = supabaseMemoStore({
    from: (table) => supabase.from(table) as unknown as QueryBuilderLike,
  });
  const result = await fetchMemoDetail(store, user.id, id);

  if (!result.ok) {
    if (result.reason === "not-found") notFound();
    return (
      <div style={{ maxWidth: 600, margin: "0 auto", padding: "40px 24px" }}>
        <h1 style={{ fontSize: "1.125rem", fontWeight: 600, margin: "0 0 8px" }}>
          This memo is unavailable right now
        </h1>
        <p style={{ fontSize: "0.875rem", color: "var(--fg-muted)", lineHeight: 1.6 }}>
          The history backend did not respond. Nothing was changed — please try again.
        </p>
        <Link href="/memos" className="btn btn--soft btn--sm" style={{ marginTop: 12 }}>
          Back to history
        </Link>
      </div>
    );
  }

  const { memo, attachments, tags, presentationBody } = result.detail;
  const weatherStr = extractWeatherString(memo.weather);
  const humidityStr = extractHumidityString(memo.weather);
  const { lat, lng, place_name, country, display } = extractLocationFields(memo.location);

  return (
    <div style={{ maxWidth: 600, margin: "0 auto" }}>
      <MemoDetailTopBar createdAt={memo.created_at} />

      <div style={{ padding: "0 0 40px" }}>
        <MemoDetailTitle place={display} kind={memo.type} location={display} />

        <MetadataTiles
          weather={weatherStr}
          humidity={humidityStr}
          kind={memo.type}
          createdAt={memo.created_at}
        />

        {/* ALL attachments, in position order */}
        <MemoAttachments attachments={attachments} />

        {/* MemoBody is skipped ONLY for the validated imported-media-only
            presentation case (ADR-0026): the placeholder body renders as the
            media rows above, so no "No content" filler is shown. Every other
            body (empty/prose/Markdown/code) renders unchanged. */}
        {presentationBody === "" ? null : <MemoBody body={memo.body} />}

        {/* Exact metadata tags (imported labels) — original bytes, linked to
            the exact `?tag=` filter. */}
        <div style={{ padding: "0 14px" }}>
          <MemoTags tags={tags} />
        </div>

        <LocationCard
          location={display}
          lat={lat}
          lng={lng}
          place_name={place_name}
          country={country}
        />

        <FileMetadataCard
          created_at={memo.created_at}
          path={memo.vault_path}
          content_hash={null}
          memo_id={id}
        />

        {/* Read-only metadata */}
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
                        style={{ fontSize: "0.8125rem", color: "var(--accent)", wordBreak: "break-all" }}
                      >
                        {memo.source_url}
                      </a>
                    ) : (
                      <span
                        style={{ fontSize: "0.8125rem", color: "var(--fg-subtle)", wordBreak: "break-all" }}
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
                {memo.origin ?? "—"} · {memo.ingest_mode ?? "—"}
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
              <div style={{ fontSize: "0.8125rem" }}>{memo.compile_status ?? "—"}</div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
