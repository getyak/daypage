// Display-only date helpers. Original `created_at` values are immutable; these
// formats are consistently rendered in Asia/Shanghai for the flomo import and
// never mutate the stored timestamps or server-date grouping elsewhere.

export const DISPLAY_TIME_ZONE = "Asia/Shanghai";

type DateStyle = "date" | "time" | "weekday";

function formatInShanghai(isoLike: string, style: DateStyle): string | null {
  const date = new Date(isoLike);
  if (Number.isNaN(date.getTime())) return null;
  const options: Intl.DateTimeFormatOptions =
    style === "date"
      ? { timeZone: DISPLAY_TIME_ZONE, year: "numeric", month: "2-digit", day: "2-digit" }
      : style === "time"
        ? { timeZone: DISPLAY_TIME_ZONE, hour: "2-digit", minute: "2-digit", hour12: false }
        : { timeZone: DISPLAY_TIME_ZONE, weekday: "short" };
  return new Intl.DateTimeFormat("en-CA", options).format(date);
}

/** `2026-01-02` in Asia/Shanghai. */
export function formatDayKey(isoLike: string): string | null {
  return formatInShanghai(isoLike, "date");
}

/** `08:30` in Asia/Shanghai (24h). */
export function formatTimeOfDay(isoLike: string): string | null {
  return formatInShanghai(isoLike, "time");
}

/** `FRI` in Asia/Shanghai. */
export function formatWeekday(isoLike: string): string | null {
  return formatInShanghai(isoLike, "weekday")?.toUpperCase() ?? null;
}

/** Detail top-bar anchor: `FRI · 2026-01-02 · 08:30`. */
export function formatMemoAnchor(isoLike: string): string {
  const day = formatDayKey(isoLike);
  const time = formatTimeOfDay(isoLike);
  const weekday = formatWeekday(isoLike);
  if (!day || !time) return isoLike;
  return [weekday, day, time].filter(Boolean).join(" · ");
}
