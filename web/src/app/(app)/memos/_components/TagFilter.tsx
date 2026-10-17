// Compact accessible tag selector for the /memos filter form (issue #884).
//
// A labelled native selector keeps the catalogue restrained — no permanent
// wall of hundreds of pills — while preserving exact label bytes as option
// values. The catalogue contains unused labels and shows NO fake counts.

interface TagFilterProps {
  /** Complete exact catalogue labels (leading `#`, original bytes). */
  catalogue: readonly string[];
  /** Currently selected exact label, or null when unfiltered. */
  value: string | null;
}

export function TagFilter({ catalogue, value }: TagFilterProps) {
  // Keep the exact current selection even if it is not in the fetched
  // catalogue (never silently drop or rewrite the user's filter).
  const options =
    value !== null && !catalogue.includes(value) ? [value, ...catalogue] : catalogue;
  return (
    <select
      name="tag"
      defaultValue={value ?? ""}
      aria-label="Filter by tag"
      style={{
        maxWidth: 200,
        padding: "8px 10px",
        borderRadius: 10,
        border: "0.5px solid var(--border-default)",
        background: "var(--surface-white)",
        fontSize: "0.875rem",
        color: "var(--fg-primary)",
        overflowWrap: "anywhere",
      }}
    >
      <option value="">All tags</option>
      {options.map((label) => (
        <option key={label} value={label}>
          {label}
        </option>
      ))}
    </select>
  );
}
