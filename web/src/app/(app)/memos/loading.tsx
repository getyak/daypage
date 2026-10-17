// Honest loading state for the history page — no fake rows or counts.
export default function MemosHistoryLoading() {
  return (
    <div style={{ maxWidth: 720, margin: "0 auto", width: "100%", padding: "24px 24px" }}>
      <h1
        style={{
          fontFamily: "var(--font-fraunces), var(--font-family-serif), serif",
          fontSize: 26,
          fontWeight: 500,
          margin: "0 0 4px",
          color: "var(--fg-primary)",
        }}
      >
        History
      </h1>
      <p style={{ fontSize: "0.85rem", color: "var(--fg-subtle)" }} aria-live="polite">
        Loading memos…
      </p>
      <div style={{ display: "flex", flexDirection: "column", gap: 12, marginTop: 16 }}>
        {[0, 1, 2].map((i) => (
          <div
            key={i}
            style={{
              height: 92,
              borderRadius: 14,
              border: "0.5px solid var(--border-default)",
              background: "var(--surface-sunken)",
            }}
            aria-hidden="true"
          />
        ))}
      </div>
    </div>
  );
}
