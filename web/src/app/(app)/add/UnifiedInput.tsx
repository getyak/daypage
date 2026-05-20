"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import {
  Link2,
  FileText,
  Image as ImageIcon,
  Mic,
  Bookmark,
  Sparkles,
  Send,
  X,
  Copy,
  Check,
} from "lucide-react";
import { useAddDraft } from "./useAddDraft";
import { Dialog } from "../_components/Dialog";

const isMac =
  typeof navigator !== "undefined" && /Mac|iPhone|iPad|iPod/.test(navigator.platform);

const URL_RE = /^https?:\/\//;
const TEXTAREA_MAX = 320;

// US-008: URL validation helper
function isValidUrl(s: string): boolean {
  try {
    new URL(s);
    return true;
  } catch {
    return false;
  }
}

function relativeTime(iso: string): string {
  const diffMs = Date.now() - new Date(iso).getTime();
  const secs = Math.floor(diffMs / 1000);
  if (secs < 60) return "just now";
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  return `${Math.floor(hrs / 24)}d ago`;
}

type Attachment = {
  id: string;
  file: File;
  previewUrl?: string;
};

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 102.4) / 10} KB`;
  return `${Math.round(bytes / 1024 / 102.4) / 10} MB`;
}

interface MemoPayload {
  body: string;
  type: "text" | "url";
  tempId: string;
}

interface MemoItem {
  id: string;
  body: string;
  type: string;
  compile_status: string;
  ingest_mode: string;
  created_at: string;
}

interface MemosCache {
  items: MemoItem[];
  next_cursor?: string | null;
  has_more?: boolean;
}

async function createMemo(payload: MemoPayload) {
  const { body, type } = payload;
  const res = await fetch("/api/memos", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ type, body, origin: "web" }),
  });
  if (!res.ok) {
    const data = (await res.json().catch(() => ({}))) as { error?: string };
    throw new Error(data.error ?? `Request failed (${res.status})`);
  }
  return res.json() as Promise<MemoItem>;
}

// US-007: Bookmarklet JS source
const BOOKMARKLET_SOURCE = `javascript:void(open('http://localhost:3000/add?url='+encodeURIComponent(location.href)+'&title='+encodeURIComponent(document.title)))`;

export function UnifiedInput() {
  const [body, setBody] = useState("");
  const [draftToastVisible, setDraftToastVisible] = useState(false);
  const [hydrated, setHydrated] = useState(false);
  const [dragging, setDragging] = useState(false);
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  // US-007: bookmarklet modal state
  const [bookmarkletOpen, setBookmarkletOpen] = useState(false);
  const [bookmarkletCopied, setBookmarkletCopied] = useState(false);
  // US-008: input mode toggle
  const [inputMode, setInputMode] = useState<"text" | "url">("text");

  const fileInputRef = useRef<HTMLInputElement>(null);
  const photoInputRef = useRef<HTMLInputElement>(null);
  const taRef = useRef<HTMLTextAreaElement>(null);
  const blurTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const queryClient = useQueryClient();
  const empty = body.trim().length === 0 && attachments.length === 0;

  // US-009: derive photo/file active state from attachments
  const photoActive = attachments.some((a) => a.file.type.startsWith("image/"));
  const fileActive = attachments.some((a) => !a.file.type.startsWith("image/"));

  // US-008: URL mode validity (computed here, used in render and submit)
  const urlModeInvalid = inputMode === "url" && !isValidUrl(body.trim());

  const { saveDraft, clearDraft, restoredAt } = useAddDraft();

  // Mark hydrated after first client render to avoid hydration mismatch.
  useEffect(() => {
    setHydrated(true);
  }, []);

  // Prefill from draft on mount (after hydration).
  useEffect(() => {
    if (!hydrated) return;
    try {
      const raw = localStorage.getItem("codex.add.draft.v1");
      if (raw) {
        const parsed = JSON.parse(raw) as { text?: string };
        if (parsed.text) setBody(parsed.text);
      }
    } catch {
      // ignore malformed storage
    }
  }, [hydrated]);

  // Autosize textarea on mount and whenever body changes
  useEffect(() => {
    const ta = taRef.current;
    if (!ta) return;
    ta.style.height = "auto";
    ta.style.height = Math.min(ta.scrollHeight, TEXTAREA_MAX) + "px";
  }, [body]);

  // Revoke any remaining object URLs on unmount.
  const attachmentsRef = useRef<Attachment[]>([]);
  useEffect(() => {
    attachmentsRef.current = attachments;
  }, [attachments]);
  useEffect(() => {
    return () => {
      for (const a of attachmentsRef.current) {
        if (a.previewUrl) URL.revokeObjectURL(a.previewUrl);
      }
    };
  }, []);

  // US-010: memoized callbacks
  const addFiles = useCallback((files: File[]) => {
    if (files.length === 0) return;
    const next: Attachment[] = files.map((file) => ({
      id: `${file.name}-${file.size}-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
      file,
      previewUrl: file.type.startsWith("image/")
        ? URL.createObjectURL(file)
        : undefined,
    }));
    setAttachments((prev) => [...prev, ...next]);
  }, []);

  const removeAttachment = useCallback((id: string) => {
    setAttachments((prev) => {
      const target = prev.find((a) => a.id === id);
      if (target?.previewUrl) URL.revokeObjectURL(target.previewUrl);
      return prev.filter((a) => a.id !== id);
    });
  }, []);

  const showDraftToast = useCallback(() => {
    setDraftToastVisible(true);
    setTimeout(() => setDraftToastVisible(false), 2500);
  }, []);

  const handleSaveDraft = useCallback(() => {
    saveDraft({ text: body, mode: "text", attachmentRef: null, savedAt: new Date().toISOString() });
    showDraftToast();
  }, [body, saveDraft, showDraftToast]);

  const handleDiscardDraft = useCallback(() => {
    clearDraft();
    setBody("");
  }, [clearDraft]);

  const handleBlur = useCallback(() => {
    if (body.trim() === "") {
      blurTimerRef.current = setTimeout(() => {
        clearDraft();
      }, 1000);
    }
  }, [body, clearDraft]);

  const handleFocus = useCallback(() => {
    if (blurTimerRef.current !== null) {
      clearTimeout(blurTimerRef.current);
      blurTimerRef.current = null;
    }
  }, []);

  const [failToast, setFailToast] = useState(false);

  const mutation = useMutation({
    mutationFn: createMemo,
    onMutate: (payload) => {
      const tempItem: MemoItem = {
        id: payload.tempId,
        body: payload.body,
        type: payload.type,
        compile_status: "pending",
        ingest_mode: "light",
        created_at: new Date().toISOString(),
      };
      queryClient.setQueryData<MemosCache>(["memos", "pending"], (old) => ({
        items: [tempItem, ...(old?.items ?? [])],
        next_cursor: old?.next_cursor ?? null,
        has_more: old?.has_more ?? false,
      }));
      return { tempId: payload.tempId };
    },
    onSuccess: (newMemo, _payload, context) => {
      setBody("");
      setInputMode("text");
      clearDraft();
      for (const a of attachments) {
        if (a.previewUrl) URL.revokeObjectURL(a.previewUrl);
      }
      setAttachments([]);
      queryClient.setQueryData<MemosCache>(["memos", "pending"], (old) => {
        if (!old) return { items: [newMemo], next_cursor: null, has_more: false };
        const items = old.items.map((m) =>
          m.id === context?.tempId ? newMemo : m
        );
        return { ...old, items };
      });
    },
    onError: (_err, _payload, context) => {
      if (context?.tempId) {
        queryClient.setQueryData<MemosCache>(["memos", "pending"], (old) => {
          if (!old) return old;
          return { ...old, items: old.items.filter((m) => m.id !== context.tempId) };
        });
      }
      setFailToast(true);
      setTimeout(() => setFailToast(false), 3000);
    },
  });

  // US-008: Add button disabled logic (after mutation is defined)
  const addDisabled = empty || mutation.isPending || urlModeInvalid;

  const handleSubmit = useCallback(() => {
    if (empty) return;
    const attachmentLines = attachments.map((a) => `file: ${a.file.name}`);
    const combined = [body.trim(), ...attachmentLines].filter(Boolean).join("\n");
    const type = URL_RE.test(combined.trim()) ? "url" : "text";
    const tempId = `temp-${crypto.randomUUID()}`;
    mutation.mutate({ body: combined, type, tempId });
  }, [empty, attachments, body, mutation]);

  // US-007: copy bookmarklet source to clipboard
  const handleCopyBookmarklet = useCallback(async () => {
    try {
      await navigator.clipboard.writeText(BOOKMARKLET_SOURCE);
      setBookmarkletCopied(true);
      setTimeout(() => setBookmarkletCopied(false), 2000);
    } catch {
      // fallback: select the pre text
    }
  }, []);

  // US-008: toggle URL mode
  const handleUrlToggle = useCallback(() => {
    setInputMode((prev) => (prev === "url" ? "text" : "url"));
  }, []);

  // Determine textarea placeholder based on mode
  const textareaPlaceholder =
    inputMode === "url"
      ? "https://… paste the link you want to save"
      : "Paste a URL, drop a file, or just type something…";

  return (
    <div
      className={`add-input ${dragging ? "is-dragging" : ""}`}
      onDragEnter={(e) => {
        e.preventDefault();
        setDragging(true);
      }}
      onDragLeave={(e) => {
        if (e.currentTarget === e.target) setDragging(false);
      }}
      onDragOver={(e) => e.preventDefault()}
      onDrop={(e) => {
        e.preventDefault();
        setDragging(false);
        const files = Array.from(e.dataTransfer.files);
        addFiles(files);
      }}
    >
      {/* Textarea */}
      <textarea
        ref={taRef}
        value={body}
        onChange={(e) => setBody(e.target.value)}
        onBlur={handleBlur}
        onFocus={handleFocus}
        onKeyDown={(e) => {
          if ((e.metaKey || e.ctrlKey) && e.key === "Enter" && !addDisabled) {
            e.preventDefault();
            handleSubmit();
          }
        }}
        placeholder={textareaPlaceholder}
        rows={3}
      />
      {/* Keyboard shortcut hint */}
      <div
        className="ds-mono-11"
        style={{ color: "var(--fg-subtle)", marginTop: "0.25rem", userSelect: "none" }}
      >
        {isMac ? "⌘ + Enter to submit" : "Ctrl + Enter to submit"}
      </div>

      {/* Attachment preview row */}
      {attachments.length > 0 && (
        <div className="add-input__attachments">
          {attachments.map((a) => (
            <div key={a.id} className="add-input__attachment">
              {a.previewUrl ? (
                /* eslint-disable-next-line @next/next/no-img-element */
                <img
                  src={a.previewUrl}
                  alt={a.file.name}
                  className="add-input__attachment-thumb"
                />
              ) : (
                <div className="add-input__attachment-thumb add-input__attachment-thumb--file">
                  <FileText size={18} />
                </div>
              )}
              <div className="add-input__attachment-meta">
                <span className="add-input__attachment-name" title={a.file.name}>
                  {a.file.name}
                </span>
                <span className="add-input__attachment-size">
                  {formatSize(a.file.size)}
                </span>
              </div>
              <button
                type="button"
                className="add-input__attachment-remove"
                aria-label={`Remove ${a.file.name}`}
                onClick={() => removeAttachment(a.id)}
              >
                <X size={14} />
              </button>
            </div>
          ))}
        </div>
      )}

      {/* Submit failure toast */}
      {failToast && (
        <div
          role="alert"
          style={{
            position: "fixed",
            bottom: "1.5rem",
            right: "1.5rem",
            display: "flex",
            alignItems: "center",
            gap: "0.75rem",
            padding: "0.625rem 1rem",
            background: "var(--fg-primary)",
            color: "var(--bg-warm)",
            borderRadius: "var(--radius-sm)",
            fontSize: "0.875rem",
            fontWeight: 500,
            boxShadow: "0 4px 16px rgba(0,0,0,0.14)",
            zIndex: 9999,
          }}
        >
          Failed to submit, try again
        </div>
      )}

      {/* Inline error */}
      {mutation.isError && (
        <div
          role="alert"
          style={{
            display: "flex",
            alignItems: "center",
            gap: "0.5rem",
            padding: "0.625rem 0.75rem",
            marginTop: "0.75rem",
            background: "var(--error-soft, #fff1f1)",
            border: "1px solid var(--error, #e53e3e)",
            borderRadius: "var(--radius-sm)",
            fontSize: "0.875rem",
            color: "var(--error, #c53030)",
          }}
        >
          <span style={{ flex: 1 }}>
            {mutation.error instanceof Error
              ? mutation.error.message
              : "Something went wrong"}
          </span>
          <button
            type="button"
            className="btn btn--secondary btn--sm"
            onClick={handleSubmit}
          >
            Retry
          </button>
        </div>
      )}

      {/* Hidden file inputs */}
      {/* US-009: single file only, capture="environment" for photo */}
      <input
        ref={photoInputRef}
        type="file"
        accept="image/*"
        capture="environment"
        style={{ display: "none" }}
        onChange={(e) => {
          const files = Array.from(e.target.files ?? []);
          addFiles(files);
          if (e.target) e.target.value = "";
        }}
      />
      {/* US-009: single file only (no multiple) */}
      <input
        ref={fileInputRef}
        type="file"
        style={{ display: "none" }}
        onChange={(e) => {
          const files = Array.from(e.target.files ?? []);
          addFiles(files);
          if (e.target) e.target.value = "";
        }}
      />

      {/* Restored draft hint */}
      {hydrated && restoredAt && (
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: "0.5rem",
            padding: "0.375rem 0.75rem",
            marginTop: "0.5rem",
            background: "var(--surface-2, #f7f7f7)",
            borderRadius: "var(--radius-sm)",
            fontSize: "0.8125rem",
            color: "var(--fg-subtle)",
          }}
        >
          <span style={{ flex: 1 }}>
            Restored draft · {relativeTime(restoredAt)}
          </span>
          <button
            type="button"
            className="btn btn--secondary btn--sm"
            onClick={handleDiscardDraft}
          >
            Discard draft
          </button>
        </div>
      )}

      {/* Action row */}
      <div className="add-input__row">
        <div className="add-input__hints">
          {/* US-008: URL mode toggle — highlighted when active */}
          <button
            type="button"
            className="chip chip--ghost chip--interactive"
            onClick={handleUrlToggle}
            style={
              inputMode === "url"
                ? { background: "var(--accent-soft)", color: "var(--accent)" }
                : undefined
            }
          >
            <Link2 size={12} />
            URL
          </button>
          {/* US-009: Photo — highlighted when image attachment present */}
          <button
            type="button"
            className="chip chip--ghost chip--interactive"
            onClick={() => photoInputRef.current?.click()}
            style={
              photoActive
                ? { background: "var(--accent-soft)", color: "var(--accent)" }
                : undefined
            }
          >
            <ImageIcon size={12} />
            Photo
          </button>
          {/* US-009: File — highlighted when non-image attachment present */}
          <button
            type="button"
            className="chip chip--ghost chip--interactive"
            onClick={() => fileInputRef.current?.click()}
            style={
              fileActive
                ? { background: "var(--accent-soft)", color: "var(--accent)" }
                : undefined
            }
          >
            <FileText size={12} />
            File
          </button>
          {/* Voice — still disabled */}
          <button
            type="button"
            className="chip chip--ghost chip--interactive"
            disabled
            title="coming soon"
            style={{ opacity: 0.5, cursor: "not-allowed" }}
          >
            <Mic size={12} />
            Voice
          </button>
          {/* US-007: Bookmarklet — opens modal */}
          <button
            type="button"
            className="chip chip--ghost chip--interactive"
            onClick={() => setBookmarkletOpen(true)}
          >
            <Bookmark size={12} />
            Bookmarklet
          </button>
        </div>
        <div style={{ display: "flex", gap: "0.5rem", alignItems: "center" }}>
          {draftToastVisible && (
            <span className="ds-mono-11" style={{ color: "var(--fg-subtle)" }}>
              Draft saved
            </span>
          )}
          {/* US-008: Show hint when URL mode is active and input is invalid */}
          {urlModeInvalid && body.trim().length > 0 && (
            <span
              className="ds-mono-11"
              style={{ color: "var(--error, #c53030)" }}
            >
              Enter a valid URL
            </span>
          )}
          <button
            type="button"
            className="btn btn--secondary btn--sm"
            disabled={empty || mutation.isPending}
            onClick={handleSaveDraft}
          >
            Save draft
          </button>
          <button
            type="button"
            className="btn btn--primary btn--sm"
            disabled={addDisabled}
            onClick={handleSubmit}
          >
            {mutation.isPending ? "Adding…" : "Add"}
            <Send size={12} />
          </button>
        </div>
      </div>

      {/* Meta line */}
      <div className="add-input__meta">
        <Sparkles size={11} />
        <span>Type, paste or drop — I auto-detect what it is.</span>
      </div>

      {/* US-007: Bookmarklet modal */}
      <Dialog
        open={bookmarkletOpen}
        onClose={() => setBookmarkletOpen(false)}
        title="Save to Codex — Bookmarklet"
      >
        <p style={{ margin: "0 0 1rem", fontSize: "0.875rem", color: "var(--fg-secondary, #555)" }}>
          Drag the link below to your bookmarks bar. Then click it on any page to send it to Codex.
        </p>
        {/* Draggable bookmarklet link */}
        <div style={{ marginBottom: "1rem", textAlign: "center" }}>
          {/* eslint-disable-next-line @next/next/no-html-link-for-pages */}
          <a
            href={BOOKMARKLET_SOURCE}
            draggable="true"
            onClick={(e) => e.preventDefault()}
            style={{
              display: "inline-block",
              padding: "0.5rem 1rem",
              background: "var(--accent-soft, #eef2ff)",
              color: "var(--accent, #4f46e5)",
              borderRadius: "var(--radius-sm, 4px)",
              fontWeight: 600,
              fontSize: "0.9375rem",
              textDecoration: "none",
              border: "2px dashed var(--accent, #4f46e5)",
              cursor: "grab",
            }}
          >
            📎 Save to Codex
          </a>
        </div>
        {/* Source code block + copy button */}
        <div style={{ position: "relative", marginBottom: "0.75rem" }}>
          <pre
            style={{
              margin: 0,
              padding: "0.625rem 0.75rem",
              background: "var(--surface-2, #f7f7f7)",
              borderRadius: "var(--radius-sm, 4px)",
              fontSize: "0.75rem",
              overflowX: "auto",
              wordBreak: "break-all",
              whiteSpace: "pre-wrap",
              color: "var(--fg-secondary, #555)",
              paddingRight: "2.5rem",
            }}
          >
            {BOOKMARKLET_SOURCE}
          </pre>
          <button
            type="button"
            onClick={handleCopyBookmarklet}
            aria-label="Copy bookmarklet source"
            style={{
              position: "absolute",
              top: "0.375rem",
              right: "0.375rem",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              background: "var(--surface-1, #fff)",
              border: "1px solid var(--border, #e2e8f0)",
              borderRadius: "var(--radius-sm, 4px)",
              cursor: "pointer",
              padding: "0.25rem",
              color: bookmarkletCopied ? "var(--accent, #4f46e5)" : "var(--fg-subtle)",
            }}
          >
            {bookmarkletCopied ? <Check size={14} /> : <Copy size={14} />}
          </button>
        </div>
        {bookmarkletCopied && (
          <p style={{ margin: 0, fontSize: "0.75rem", color: "var(--accent, #4f46e5)" }}>
            Copied to clipboard!
          </p>
        )}
      </Dialog>
    </div>
  );
}
