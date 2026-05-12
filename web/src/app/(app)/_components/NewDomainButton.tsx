"use client";

import { useState, useRef, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Plus, X } from "lucide-react";

export function NewDomainButton() {
  const [open, setOpen] = useState(false);
  const [label, setLabel] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [isPending, startTransition] = useTransition();
  const router = useRouter();
  const inputRef = useRef<HTMLInputElement>(null);

  function slugify(s: string) {
    return s
      .toLowerCase()
      .trim()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "");
  }

  function openModal() {
    setLabel("");
    setError(null);
    setOpen(true);
    setTimeout(() => inputRef.current?.focus(), 50);
  }

  function closeModal() {
    setOpen(false);
    setLabel("");
    setError(null);
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    const trimmed = label.trim();
    if (!trimmed) {
      setError("Domain name is required");
      return;
    }
    const slug = slugify(trimmed);
    if (!slug) {
      setError("Name must contain at least one letter or number");
      return;
    }

    setError(null);
    startTransition(async () => {
      try {
        const res = await fetch("/api/domains", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ slug, label: trimmed }),
        });
        if (!res.ok) {
          const data = (await res.json().catch(() => ({}))) as { error?: string };
          setError(data.error ?? "Failed to create domain");
          return;
        }
        closeModal();
        router.refresh();
      } catch {
        setError("Network error — please try again");
      }
    });
  }

  return (
    <>
      <button
        className="sb__domain sb__domain--add"
        onClick={openModal}
        type="button"
      >
        <span className="sb__domain-icon">
          <Plus size={12} />
        </span>
        <span className="sb__domain-label">New domain</span>
      </button>

      {open && (
        <div
          style={{
            position: "fixed",
            inset: 0,
            zIndex: 100,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            background: "rgba(0,0,0,0.35)",
          }}
          onClick={(e) => {
            if (e.target === e.currentTarget) closeModal();
          }}
        >
          <div
            style={{
              background: "var(--surface-white)",
              border: "1px solid var(--accent-border)",
              borderRadius: "var(--radius-card)",
              padding: "24px",
              width: "360px",
              maxWidth: "calc(100vw - 32px)",
              boxShadow: "0 8px 32px rgba(0,0,0,0.12)",
            }}
          >
            <div
              style={{
                display: "flex",
                alignItems: "center",
                justifyContent: "space-between",
                marginBottom: "16px",
              }}
            >
              <span
                style={{
                  fontFamily: "var(--font-heading)",
                  fontSize: "14px",
                  fontWeight: 600,
                  color: "var(--fg-primary)",
                  letterSpacing: "0.04em",
                  textTransform: "uppercase",
                }}
              >
                New Domain
              </span>
              <button
                type="button"
                onClick={closeModal}
                style={{
                  background: "none",
                  border: "none",
                  cursor: "pointer",
                  color: "var(--fg-muted)",
                  display: "flex",
                  padding: "2px",
                }}
                aria-label="Close"
              >
                <X size={16} />
              </button>
            </div>

            <form onSubmit={handleSubmit}>
              <div style={{ marginBottom: "16px" }}>
                <label
                  htmlFor="new-domain-name"
                  style={{
                    display: "block",
                    fontSize: "12px",
                    color: "var(--fg-muted)",
                    marginBottom: "6px",
                    fontFamily: "var(--font-mono)",
                    letterSpacing: "0.06em",
                    textTransform: "uppercase",
                  }}
                >
                  Domain name
                </label>
                <input
                  id="new-domain-name"
                  ref={inputRef}
                  type="text"
                  value={label}
                  onChange={(e) => setLabel(e.target.value)}
                  placeholder="e.g. Work, Personal, Health"
                  maxLength={200}
                  style={{
                    width: "100%",
                    border: "1.5px solid var(--accent-border)",
                    borderRadius: "var(--radius-small)",
                    padding: "8px 12px",
                    fontSize: "14px",
                    fontFamily: "var(--font-body)",
                    color: "var(--fg-primary)",
                    background: "var(--bg-warm)",
                    outline: "none",
                    boxSizing: "border-box",
                  }}
                  onFocus={(e) => {
                    e.currentTarget.style.borderColor = "var(--accent)";
                    e.currentTarget.style.boxShadow = "0 0 0 3px var(--accent-soft)";
                  }}
                  onBlur={(e) => {
                    e.currentTarget.style.borderColor = "var(--accent-border)";
                    e.currentTarget.style.boxShadow = "none";
                  }}
                />
                {label.trim() && (
                  <div
                    style={{
                      marginTop: "4px",
                      fontSize: "11px",
                      color: "var(--fg-subtle)",
                      fontFamily: "var(--font-mono)",
                    }}
                  >
                    slug: {slugify(label.trim()) || "—"}
                  </div>
                )}
                {error && (
                  <div
                    style={{
                      marginTop: "6px",
                      fontSize: "12px",
                      color: "var(--error, #c0392b)",
                    }}
                  >
                    {error}
                  </div>
                )}
              </div>

              <div style={{ display: "flex", gap: "8px", justifyContent: "flex-end" }}>
                <button
                  type="button"
                  onClick={closeModal}
                  className="btn btn--secondary btn--sm"
                  disabled={isPending}
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  className="btn btn--primary btn--sm"
                  disabled={isPending || !label.trim()}
                >
                  {isPending ? "Creating…" : "Create"}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </>
  );
}
