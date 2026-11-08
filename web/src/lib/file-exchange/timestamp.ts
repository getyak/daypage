// Matches DayPageCore's ExchangeTimestamp and Memo.memoComponents. Raw note
// fractions are decimal source, while review metadata is a binary64 JSON Date;
// converting both through Date.parse would silently erase that distinction.
export interface WireTimestamp {
  milliseconds: number;
  canonical: string;
}

const minimum = -62135596800000; // 0001-01-01T00:00:00Z
const maximum = 253402300799999; // 9999-12-31T23:59:59.999Z
const spelling = /^(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?([Zz]|([+-])(\d{2}):(\d{2}))$/;

function parseMilliseconds(value: string, allowSubmilliseconds: boolean): number | null {
  if (typeof value !== "string") return null;
  const match = spelling.exec(value);
  if (!match) return null;
  const [year, month, day, hour, minute, second] = match.slice(1, 7).map(Number);
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 59) return null;

  // Use Date only for the whole Gregorian civil second, never for the source
  // fraction. setUTCFullYear avoids Date.UTC's special treatment of years 0–99.
  const civil = new Date(0);
  civil.setUTCFullYear(year, month - 1, day);
  civil.setUTCHours(hour, minute, second, 0);
  if (civil.getUTCFullYear() !== year || civil.getUTCMonth() !== month - 1 || civil.getUTCDate() !== day) return null;

  let offset = 0;
  if (match[8].toUpperCase() !== "Z") {
    const hours = Number(match[10]), minutes = Number(match[11]);
    if (hours > 23 || minutes > 59) return null;
    offset = (hours * 60 + minutes) * (match[9] === "-" ? -1 : 1);
  }
  const fraction = match[7] ?? "";
  if (!allowSubmilliseconds && /[1-9]/.test(fraction.slice(3))) return null;
  const subsecond = Number((fraction.slice(0, 3) + "000").slice(0, 3));
  let milliseconds = civil.getTime() - offset * 60000 + subsecond;

  // This integer is the floor on the Unix timeline. At an exact negative half,
  // keeping the lower integer is away from zero; any further nonzero decimal
  // digit puts the source above half. Do not first round a binary64 fraction.
  const next = fraction.charAt(3);
  if (next > "5" || (next === "5" && (milliseconds >= 0 || /[1-9]/.test(fraction.slice(4))))) milliseconds++;
  return milliseconds >= minimum && milliseconds <= maximum ? milliseconds : null;
}

function format(milliseconds: number): string {
  const iso = new Date(milliseconds).toISOString();
  return milliseconds % 1000 === 0 ? iso.replace(".000Z", "Z") : iso;
}

/** Project the original raw RFC3339 scalar without clipping decimal precision. */
export function projectRawTimestamp(value: string): string | null {
  const milliseconds = parseMilliseconds(value, true);
  return milliseconds === null ? null : format(milliseconds);
}

/** A typed wire claim cannot hide any nonzero submillisecond source digits. */
export function parseWireTimestamp(value: string): WireTimestamp | null {
  const milliseconds = parseMilliseconds(value, false);
  return milliseconds === null ? null : { milliseconds, canonical: format(milliseconds) };
}

/** Foundation JSON Date's reference seconds, in the owning binary64 order. */
export function projectReviewReferenceSeconds(value: number): string {
  if (!Number.isFinite(value)) return "";
  const scaled = (value + 978307200) * 1000;
  const magnitude = Math.abs(scaled), integer = Math.floor(magnitude);
  const milliseconds = Math.sign(scaled) * (integer + (magnitude - integer >= 0.5 ? 1 : 0));
  if (!Number.isFinite(milliseconds) || milliseconds < minimum || milliseconds > maximum) return "";
  return format(milliseconds);
}
