"use client";

import { useRef, useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Link2, FileText, Mic, Bookmark, Sparkles, Send } from "lucide-react";

const URL_RE = /^https?:\/\//;

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
  const [savedDraftAt, setSavedDraftAt] = useState<number | null>(null);
  const [dragging, setDragging] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const taRef = useRef<HTMLTextAreaElement>(null);
  const queryClient = useQueryClient();
  const empty = body.trim().length === 0;

  function handleSaveDraft() {
    if (typeof window !== "undefined") {
      try {
        window.localStorage.setItem("daypage:add-draft", body);
        setSavedDraftAt(Date.now());
      } catch {
        // ignore quota errors
      }
    }
  }

  const mutation = useMutation({
    mutationFn: createMemo,
    onSuccess: (newMemo) => {
      setBody("");
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
    mutation.mutate(body);
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
        if (files.length > 0) {
          setBody(
            (b) =>
              (b ? b + "\n" : "") +
              files.map((f) => `file: ${f.name}`).join("\n"),
          );
        }
      }}
    >
      {/* Textarea — auto-grow on input */}
      <textarea
        ref={taRef}
        value={body}
        onChange={(e) => {
          setBody(e.target.value);
          const t = e.target;
          t.style.height = "auto";
          t.style.height = Math.min(t.scrollHeight, 320) + "px";
        }}
        placeholder="Paste a URL, drop a file, or just type something…"
        rows={3}
      />

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

      {/* Hidden file input — triggered by the File hint chip */}
      <input
        ref={fileInputRef}
        type="file"
        style={{ display: "none" }}
        onChange={(e) => {
          // Minimum viable: announce the picked file name in textarea so user sees a response.
          const f = e.target.files?.[0];
          if (f) {
            setBody((prev) => (prev ? prev + "\n" : "") + `file: ${f.name}`);
          }
          // Reset so picking the same file twice still fires onChange
          if (e.target) e.target.value = "";
        }}
      />

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
          {/* File — triggers hidden file input */}
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
          {savedDraftAt !== null && (
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
