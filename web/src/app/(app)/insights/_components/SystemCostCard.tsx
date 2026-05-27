export async function SystemCostCard({ range }: { range: string }) {
  return (
    <div style={{
      background: "var(--surface-white)",
      borderRadius: "var(--radius-card)",
      border: "1px solid var(--accent-border)",
      padding: 24,
    }}>
      <div className="ds-section-label" style={{ marginBottom: 16 }}>System &amp; Cost</div>
      <div style={{ color: "var(--fg-subtle)", fontSize: "0.875rem", padding: "32px 0", textAlign: "center" }}>
        Loading system data for {range}…
      </div>
    </div>
  );
}
