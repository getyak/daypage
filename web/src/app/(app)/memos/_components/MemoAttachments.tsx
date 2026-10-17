"use client";

// Reusable read-only attachment renderer: ALL attachments, already in position
// order, each one visible with an honest state. Images get an accessible
// enlargement plus graceful HEIC/decode failure fallback and an original
// download; audio gets seekable controls with preload="metadata" and the
// original filename/duration; MOV/video gets optional native playback with a
// clear codec fallback; files and unknown/legacy metadata stay visible with a
// download or honest "unavailable" state. Nothing here invents a "verified"
// status and nothing is silently dropped.

import { useEffect, useRef, useState } from "react";
import type { AttachmentView } from "@/lib/memos/history";

function formatBytes(size: number | null): string | null {
  if (size === null || !Number.isFinite(size) || size <= 0) return null;
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
}

function formatDuration(view: AttachmentView): string | null {
  const ms =
    view.duration_ms !== null && view.duration_ms > 0
      ? view.duration_ms
      : view.duration_sec !== null && view.duration_sec > 0
        ? view.duration_sec * 1000
        : null;
  if (ms === null) return null;
  const totalSeconds = Math.round(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}:${String(seconds).padStart(2, "0")}`;
}

const cardStyle: React.CSSProperties = {
  background: "var(--surface-white)",
  border: "0.5px solid var(--border-default)",
  borderRadius: 14,
  padding: "12px 14px",
};

const metaStyle: React.CSSProperties = {
  fontFamily: "var(--font-mono)",
  fontSize: 10,
  letterSpacing: "1.2px",
  textTransform: "uppercase",
  color: "var(--fg-subtle)",
};

const linkStyle: React.CSSProperties = {
  fontSize: "0.8125rem",
  color: "var(--accent)",
  fontWeight: 500,
};

function displayName(view: AttachmentView): string {
  return view.filename ?? `${view.kind} attachment`;
}

function DownloadLink({ view }: { view: AttachmentView }) {
  return (
    <a href={view.url} download className="memo-link" style={linkStyle}>
      Download original
    </a>
  );
}

function UnavailableNotice({ view }: { view: AttachmentView }) {
  return (
    <div style={{ fontSize: "0.8125rem", color: "var(--fg-subtle)", lineHeight: 1.5 }}>
      {view.available
        ? "Preview unavailable — the original file can still be downloaded."
        : "This file is not available for download with the current storage metadata."}
    </div>
  );
}

function ImageAttachment({ view }: { view: AttachmentView }) {
  const [failed, setFailed] = useState(false);
  const [open, setOpen] = useState(false);
  const dialogRef = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const el = dialogRef.current;
    if (!el) return;
    const handler = () => setOpen(false);
    el.addEventListener("close", handler);
    return () => el.removeEventListener("close", handler);
  }, []);

  useEffect(() => {
    if (open) dialogRef.current?.showModal();
    else dialogRef.current?.close();
  }, [open]);

  return (
    <figure style={{ ...cardStyle, margin: 0 }}>
      {failed || !view.available ? (
        <div style={{ fontSize: "0.8125rem", color: "var(--fg-subtle)", lineHeight: 1.5 }}>
          This photo could not be displayed (HEIC and other formats depend on
          browser support).
        </div>
      ) : (
        // Authenticated same-origin route — never the Next image optimizer or
        // a public/signed URL.
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={view.url}
          alt={view.ocr_text ?? displayName(view)}
          loading="lazy"
          onError={() => { setOpen(false); setFailed(true); }}
          style={{
            width: "100%",
            maxHeight: 420,
            objectFit: "contain",
            borderRadius: 10,
            background: "var(--surface-sunken)",
            display: "block",
          }}
        />
      )}
      <figcaption
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          gap: 10,
          marginTop: 8,
          flexWrap: "wrap",
        }}
      >
        <span style={{ fontSize: "0.8125rem", color: "var(--fg-muted)", wordBreak: "break-all" }}>
          {displayName(view)}
          {formatBytes(view.size_bytes) ? ` · ${formatBytes(view.size_bytes)}` : ""}
        </span>
        <span style={{ display: "flex", gap: 12 }}>
          {!failed && view.available && (
            <button
              type="button"
              onClick={() => setOpen(true)}
              style={{ ...linkStyle, background: "none", border: "none", cursor: "pointer", padding: 0 }}
              aria-label={`Enlarge ${displayName(view)}`}
            >
              Enlarge
            </button>
          )}
          {view.available && <DownloadLink view={view} />}
        </span>
      </figcaption>
      {!view.available && <UnavailableNotice view={view} />}

      <dialog
        ref={dialogRef}
        className="memo-photo-dialog"
        aria-label={`Photo: ${displayName(view)}`}
        style={{ border: "none", background: "transparent", padding: 0, margin: "auto", maxWidth: "100vw", maxHeight: "100vh" }}
        onClick={(event) => { if (event.target === event.currentTarget) setOpen(false); }}
      >
        {open && view.available && !failed && (
        <div
          style={{
            background: "rgba(0,0,0,0.88)",
            padding: 16,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            flexDirection: "column",
            gap: 12,
          }}
        >
          <button type="button" onClick={() => setOpen(false)}
            aria-label="Close photo"
            style={{ alignSelf: "flex-end", color: "#fff", border: "1px solid #ffffff66", borderRadius: 8, padding: "8px 14px", cursor: "pointer" }}>
            Close
          </button>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src={view.url}
            alt={view.ocr_text ?? displayName(view)}
            onError={() => { setOpen(false); setFailed(true); }}
            style={{ width: "min(92vw, 1200px)", maxWidth: "92vw", maxHeight: "80vh", borderRadius: 12, objectFit: "contain" }}
          />
        </div>
        )}
      </dialog>
    </figure>
  );
}

function AudioAttachment({ view }: { view: AttachmentView }) {
  const [failed, setFailed] = useState(false);
  const duration = formatDuration(view);
  return (
    <div style={cardStyle}>
      <div style={{ ...metaStyle, marginBottom: 6 }}>AUDIO</div>
      <div style={{ fontSize: "0.8125rem", color: "var(--fg-primary)", marginBottom: 8, wordBreak: "break-all" }}>
        {displayName(view)}
        {duration ? ` · ${duration}` : ""}
        {formatBytes(view.size_bytes) ? ` · ${formatBytes(view.size_bytes)}` : ""}
      </div>
      {view.available && !failed ? (
        <audio
          controls
          preload="metadata"
          src={view.url}
          onError={() => setFailed(true)}
          style={{ width: "100%" }}
          aria-label={`Audio: ${displayName(view)}`}
        />
      ) : (
        <UnavailableNotice view={view} />
      )}
      {view.available && (
        <div style={{ marginTop: 8 }}>
          <DownloadLink view={view} />
        </div>
      )}
    </div>
  );
}

function VideoAttachment({ view }: { view: AttachmentView }) {
  const [failed, setFailed] = useState(false);
  return (
    <div style={cardStyle}>
      <div style={{ ...metaStyle, marginBottom: 6 }}>VIDEO · MOV</div>
      <div style={{ fontSize: "0.8125rem", color: "var(--fg-primary)", marginBottom: 8, wordBreak: "break-all" }}>
        {displayName(view)}
        {formatBytes(view.size_bytes) ? ` · ${formatBytes(view.size_bytes)}` : ""}
      </div>
      {view.available && !failed ? (
        <video
          controls
          preload="metadata"
          src={view.url}
          onError={() => setFailed(true)}
          style={{ width: "100%", maxHeight: 360, borderRadius: 10, background: "#000" }}
          aria-label={`Video: ${displayName(view)}`}
        />
      ) : (
        <UnavailableNotice view={view} />
      )}
      {failed && (
        <div style={{ fontSize: "0.8125rem", color: "var(--fg-subtle)", marginTop: 6 }}>
          This browser cannot play this MOV codec — download the original file instead.
        </div>
      )}
      {view.available && (
        <div style={{ marginTop: 8 }}>
          <DownloadLink view={view} />
        </div>
      )}
    </div>
  );
}

function FileAttachment({ view }: { view: AttachmentView }) {
  return (
    <div style={cardStyle}>
      <div style={{ ...metaStyle, marginBottom: 6 }}>FILE</div>
      <div style={{ fontSize: "0.8125rem", color: "var(--fg-primary)", wordBreak: "break-all" }}>
        {displayName(view)}
        {formatBytes(view.size_bytes) ? ` · ${formatBytes(view.size_bytes)}` : ""}
        {view.mime_type ? ` · ${view.mime_type}` : ""}
      </div>
      <div style={{ marginTop: 8 }}>
        {view.available ? (
          <DownloadLink view={view} />
        ) : (
          <UnavailableNotice view={view} />
        )}
      </div>
    </div>
  );
}

function UnknownAttachment({ view }: { view: AttachmentView }) {
  return (
    <div style={cardStyle}>
      <div style={{ ...metaStyle, marginBottom: 6 }}>ATTACHMENT</div>
      <div style={{ fontSize: "0.8125rem", color: "var(--fg-primary)", wordBreak: "break-all" }}>
        {displayName(view)}
        {formatBytes(view.size_bytes) ? ` · ${formatBytes(view.size_bytes)}` : ""}
        {view.mime_type ? ` · ${view.mime_type}` : ""}
      </div>
      <UnavailableNotice view={view} />
      {view.available && (
        <div style={{ marginTop: 8 }}>
          <DownloadLink view={view} />
        </div>
      )}
    </div>
  );
}

export function MemoAttachments({ attachments }: { attachments: AttachmentView[] }) {
  if (attachments.length === 0) return null;

  return (
    <section style={{ padding: "0 22px 22px" }} aria-label="Attachments">
      <div style={{ ...metaStyle, marginBottom: 8 }}>
        ATTACHMENTS ({attachments.length})
      </div>
      <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
        {attachments.map((view) => {
          switch (view.preview) {
            case "image":
              return <ImageAttachment key={view.id} view={view} />;
            case "audio":
              return <AudioAttachment key={view.id} view={view} />;
            case "video":
              return <VideoAttachment key={view.id} view={view} />;
            case "file":
              return <FileAttachment key={view.id} view={view} />;
            default:
              return <UnknownAttachment key={view.id} view={view} />;
          }
        })}
      </div>
    </section>
  );
}
