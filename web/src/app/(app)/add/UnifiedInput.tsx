"use client";

import { useEffect, useRef, useState } from "react";
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
} from "lucide-react";
import { useAddDraft } from "./useAddDraft";

const isMac =
  typeof navigator !== "undefined" && /Mac|iPhone|iPad|iPod/.test(navigator.platform);

const URL_RE = /^https?:\/\//;
const TEXTAREA_MAX = 320;

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

async function createMemo(body: string) {
  const type = URL_RE.test(body.trim()) ? "url" : "text";
  const res = await fetch("/api/memos", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ type, body, origin: "web" }),
  });
  if (!res.ok) {
    const data = (await res.json().catch(() => ({}))) as { error?: string };
    throw new Error(data.error ?? `Request failed (${res.status})`);
  }
  return res.json();
}

export function UnifiedInput() {
  const [body, setBody] = useState("");
  const [draftToastVisible, setDraftToastVisible] = useState(false);
  const [hydrated, setHydrated] = useState(false);
  const [dragging, setDragging] = useState(false);
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const photoInputRef = useRef<HTMLInputElement>(null);
  const taRef = useRef<HTMLTextAreaElement>(null);
  const blurTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const queryClient = useQueryClient();
  const empty = body.trim().length === 0 && attachments.length === 0;

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

  // Autosize textarea on mount and whenever body changes — avoids the
  // first-keystroke jump from CSS min-height to scrollHeight.
  useEffect(() => {
    const ta = taRef.current;
    if (!ta) return;
    ta.style.height = "auto";
    ta.style.height = Math.min(ta.scrollHeight, TEXTAREA_MAX) + "px";
  }, [body]);

  // Revoke any remaining object URLs on unmount.
  // Per-item revoke also runs in removeAttachment / mutation success.
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

  function addFiles(files: File[]) {
    if (files.length === 0) return;
    const next: Attachment[] = files.map((file) => ({
      id: `${file.name}-${file.size}-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
      file,
      previewUrl: file.type.startsWith("image/")
        ? URL.createObjectURL(file)
        : undefined,
    }));
    setAttachments((prev) => [...prev, ...next]);
  }

  function removeAttachment(id: string) {
    setAttachments((prev) => {
      const target = prev.find((a) => a.id === id);
      if (target?.previewUrl) URL.revokeObjectURL(target.previewUrl);
      return prev.filter((a) => a.id !== id);
    });
  }

  function showDraftToast() {
    setDraftToastVisible(true);
    setTimeout(() => setDraftToastVisible(false), 2500);
  }

  function handleSaveDraft() {
    saveDraft({ text: body, mode: "text", attachmentRef: null, savedAt: new Date().toISOString() });
    showDraftToast();
  }

  function handleDiscardDraft() {
    clearDraft();
    setBody("");
  }

  // Clear draft when textarea is emptied and blurred for >1s.
  function handleBlur() {
    if (body.trim() === "") {
      blurTimerRef.current = setTimeout(() => {
        clearDraft();
      }, 1000);
    }
  }

  function handleFocus() {
    if (blurTimerRef.current !== null) {
      clearTimeout(blurTimerRef.current);
      blurTimerRef.current = null;
    }
  }

  const mutation = useMutation({
    mutationFn: createMemo,
    onSuccess: (newMemo) => {
      setBody("");
      clearDraft();
      for (const a of attachments) {
        if (a.previewUrl) URL.revokeObjectURL(a.previewUrl);
      }
      setAttachments([]);
      // Prepend the new pending memo to the compile queue cache
      queryClient.setQueryData<{ items: unknown[] }>(
        ["memos", "pending"],
        (old) => ({
          items: [newMemo, ...(old?.items ?? [])],
          next_cursor: null,
          has_more: false,
        })
      );
    },
  });

  function handleSubmit() {
    if (empty) return;
    // Append attachment filenames to body — server contract is text-only;
    // real binary upload is tracked separately.
    const attachmentLines = attachments.map((a) => `file: ${a.file.name}`);
    const combined = [body.trim(), ...attachmentLines].filter(Boolean).join("\n");
    mutation.mutate(combined);
  }

  return (
    <div
      className={`add-input ${dragging ? "is-dragging" : ""}`}
      onDragEnter={(e) => {
        e.preventDefault();
        setDragging(true);
      }}
      onDragLeave={(e) => {
        // Only cancel when truly leaving the wrapper (avoid child leave events)
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
      {/* Textarea — height is driven by useEffect to avoid first-keystroke jump */}
      <textarea
        ref={taRef}
        value={body}
        onChange={(e) => setBody(e.target.value)}
        onBlur={handleBlur}
        onFocus={handleFocus}
        onKeyDown={(e) => {
          if ((e.metaKey || e.ctrlKey) && e.key === "Enter" && !empty && !mutation.isPending) {
            e.preventDefault();
            handleSubmit();
          }
        }}
        placeholder="Paste a URL, drop a file, or just type something…"
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

      {/* Hidden file inputs — triggered by Photo / File hint chips */}
      <input
        ref={photoInputRef}
        type="file"
        accept="image/*"
        multiple
        style={{ display: "none" }}
        onChange={(e) => {
          const files = Array.from(e.target.files ?? []);
          addFiles(files);
          if (e.target) e.target.value = "";
        }}
      />
      <input
        ref={fileInputRef}
        type="file"
        multiple
        style={{ display: "none" }}
        onChange={(e) => {
          const files = Array.from(e.target.files ?? []);
          addFiles(files);
          if (e.target) e.target.value = "";
        }}
      />

      {/* Restored draft hint — shown after hydration when a saved draft exists */}
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

      {/* Action row — 4 capture chips on the left, save/add on the right */}
      <div className="add-input__row">
        <div className="add-input__hints">
          {/* URL — opens prompt and appends */}
          <button
            type="button"
            className="chip chip--ghost chip--interactive"
            onClick={() => {
              const url = window.prompt("Paste URL");
              if (url) setBody((b) => (b ? b + "\n" + url : url));
            }}
          >
            <Link2 size={12} />
            URL
          </button>
          {/* Photo — triggers image picker (with mobile camera capture) */}
          <button
            type="button"
            className="chip chip--ghost chip--interactive"
            onClick={() => photoInputRef.current?.click()}
          >
            <ImageIcon size={12} />
            Photo
          </button>
          {/* File — triggers any-type file picker */}
          <button
            type="button"
            className="chip chip--ghost chip--interactive"
            onClick={() => fileInputRef.current?.click()}
          >
            <FileText size={12} />
            File
          </button>
          {/* Voice — still disabled, MediaRecorder TODO */}
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
          {/* Bookmarklet — shows a prompt the user can copy from */}
          <button
            type="button"
            className="chip chip--ghost chip--interactive"
            onClick={() => {
              window.prompt(
                "Copy this bookmarklet to your bookmark bar:",
                "javascript:void(open('http://localhost:3000/add?url='+encodeURIComponent(location.href)))"
              );
            }}
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
            disabled={empty || mutation.isPending}
            onClick={handleSubmit}
          >
            {mutation.isPending ? "Adding…" : "Add"}
            <Send size={12} />
          </button>
        </div>
      </div>

      {/* Meta line — moved out of hints, separate row at the bottom */}
      <div className="add-input__meta">
        <Sparkles size={11} />
        <span>Type, paste or drop — I auto-detect what it is.</span>
      </div>
    </div>
  );
}
