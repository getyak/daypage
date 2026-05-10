"use client";

import { useState, useTransition } from "react";

const PRESET_COLORS = [
  "#6366f1", // indigo
  "#8b5cf6", // violet
  "#ec4899", // pink
  "#f43f5e", // rose
  "#f97316", // orange
  "#eab308", // yellow
  "#22c55e", // green
  "#14b8a6", // teal
  "#3b82f6", // blue
  "#6b7280", // gray
];

type DomainClientViewProps = {
  domainId: string;
  initialLabel: string;
  initialColor: string | null;
};

export function DomainClientView({
  domainId,
  initialLabel,
  initialColor,
}: DomainClientViewProps) {
  const [label, setLabel] = useState(initialLabel);
  const [color, setColor] = useState(initialColor ?? PRESET_COLORS[0]);
  const [editing, setEditing] = useState(false);
  const [draftLabel, setDraftLabel] = useState(initialLabel);
  const [toast, setToast] = useState<string | null>(null);
  const [isPending, startTransition] = useTransition();

  function showToast(msg: string) {
    setToast(msg);
    setTimeout(() => setToast(null), 2500);
  }

  async function patchDomain(updates: { label?: string; color?: string }) {
    const res = await fetch(`/api/domains/${domainId}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(updates),
    });
    if (!res.ok) throw new Error("Failed to update domain");
    return res.json();
  }

  function handleLabelSave() {
    if (!draftLabel.trim() || draftLabel === label) {
      setEditing(false);
      setDraftLabel(label);
      return;
    }
    startTransition(async () => {
      try {
        await patchDomain({ label: draftLabel.trim() });
        setLabel(draftLabel.trim());
        setEditing(false);
        showToast("Domain renamed");
      } catch {
        showToast("Failed to save — try again");
      }
    });
  }

  function handleColorChange(newColor: string) {
    setColor(newColor);
    startTransition(async () => {
      try {
        await patchDomain({ color: newColor });
        showToast("Color updated");
      } catch {
        showToast("Failed to save color");
        setColor(color);
      }
    });
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: "1rem" }}>
      {/* Title row */}
      <div style={{ display: "flex", alignItems: "center", gap: "0.75rem", flexWrap: "wrap" }}>
        {/* Color dot + picker */}
        <div style={{ position: "relative" }}>
          <ColorPicker
            current={color}
            colors={PRESET_COLORS}
            onChange={handleColorChange}
          />
        </div>

        {/* Editable label */}
        {editing ? (
          <div style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
            <input
              autoFocus
              value={draftLabel}
              onChange={(e) => setDraftLabel(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") handleLabelSave();
                if (e.key === "Escape") {
                  setEditing(false);
                  setDraftLabel(label);
                }
              }}
              style={{
                fontSize: "1.75rem",
                fontWeight: 700,
                fontFamily: "var(--font-space-grotesk)",
                border: "none",
                borderBottom: "2px solid var(--accent)",
                background: "transparent",
                outline: "none",
                color: "var(--fg-primary)",
                padding: "0 0 2px 0",
                minWidth: "200px",
              }}
            />
            <button
              onClick={handleLabelSave}
              disabled={isPending}
              className="btn btn--primary btn--sm"
            >
              Save
            </button>
            <button
              onClick={() => {
                setEditing(false);
                setDraftLabel(label);
              }}
              className="btn btn--ghost btn--sm"
            >
              Cancel
            </button>
          </div>
        ) : (
          <button
            onClick={() => {
              setEditing(true);
              setDraftLabel(label);
            }}
            title="Click to rename"
            style={{
              background: "none",
              border: "none",
              cursor: "pointer",
              padding: "0",
              fontSize: "1.75rem",
              fontWeight: 700,
              fontFamily: "var(--font-space-grotesk)",
              color: "var(--fg-primary)",
              borderBottom: "2px solid transparent",
              transition: "border-color 150ms",
            }}
            onMouseEnter={(e) =>
              ((e.currentTarget as HTMLButtonElement).style.borderBottomColor =
                "var(--accent-border)")
            }
            onMouseLeave={(e) =>
              ((e.currentTarget as HTMLButtonElement).style.borderBottomColor =
                "transparent")
            }
          >
            {label}
          </button>
        )}
      </div>

      {/* Toast */}
      {toast && (
        <div
          style={{
            position: "fixed",
            bottom: "1.5rem",
            right: "1.5rem",
            background: "var(--fg-primary)",
            color: "var(--bg-warm)",
            padding: "0.5rem 1rem",
            borderRadius: "var(--radius-sm)",
            fontSize: "0.8125rem",
            fontWeight: 500,
            zIndex: 9999,
            pointerEvents: "none",
          }}
        >
          {toast}
        </div>
      )}
    </div>
  );
}

function ColorPicker({
  current,
  colors,
  onChange,
}: {
  current: string;
  colors: string[];
  onChange: (c: string) => void;
}) {
  const [open, setOpen] = useState(false);

  return (
    <div style={{ position: "relative" }}>
      <button
        onClick={() => setOpen((o) => !o)}
        title="Change domain color"
        style={{
          width: "28px",
          height: "28px",
          borderRadius: "50%",
          background: current,
          border: "2px solid transparent",
          cursor: "pointer",
          outline: "none",
          flexShrink: 0,
          boxShadow: "0 0 0 2px var(--bg-warm), 0 0 0 4px " + current + "66",
        }}
      />
      {open && (
        <>
          <div
            style={{
              position: "fixed",
              inset: 0,
              zIndex: 10,
            }}
            onClick={() => setOpen(false)}
          />
          <div
            style={{
              position: "absolute",
              top: "calc(100% + 8px)",
              left: 0,
              zIndex: 20,
              background: "var(--surface-white)",
              border: "1px solid var(--accent-border)",
              borderRadius: "var(--radius-md)",
              padding: "0.5rem",
              display: "grid",
              gridTemplateColumns: "repeat(5, 1fr)",
              gap: "0.375rem",
              boxShadow: "0 4px 16px rgba(0,0,0,0.1)",
            }}
          >
            {colors.map((c) => (
              <button
                key={c}
                onClick={() => {
                  onChange(c);
                  setOpen(false);
                }}
                style={{
                  width: "24px",
                  height: "24px",
                  borderRadius: "50%",
                  background: c,
                  border: c === current ? "2px solid var(--fg-primary)" : "2px solid transparent",
                  cursor: "pointer",
                  outline: "none",
                }}
              />
            ))}
          </div>
        </>
      )}
    </div>
  );
}
