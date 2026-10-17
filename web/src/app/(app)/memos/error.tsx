"use client";

// Honest error boundary for unexpected render failures on /memos. Server-side
// data failures are rendered as explicit panels in page.tsx instead.
export default function MemosHistoryError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <div style={{ maxWidth: 720, margin: "0 auto", width: "100%", padding: "32px 24px" }}>
      <h1 style={{ fontSize: "1.125rem", fontWeight: 600, margin: "0 0 8px" }}>
        Something went wrong loading history
      </h1>
      <p style={{ fontSize: "0.875rem", color: "var(--fg-muted)", lineHeight: 1.6, margin: "0 0 16px" }}>
        An unexpected error occurred while rendering this page. Your data was not
        changed.
        {error.digest ? ` (ref ${error.digest})` : ""}
      </p>
      <button type="button" onClick={() => reset()} className="btn btn--soft btn--sm">
        Try again
      </button>
    </div>
  );
}
