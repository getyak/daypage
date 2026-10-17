// Top-level PostgREST values and values inside or=(...) have different
// grammars. Only the latter use quoteFilterLiteral. Never quote a top-level
// search value or use LIKE's '*' alias for a literal substring search.

/**
 * Wrap a filter value in PostgREST double-quote syntax, escaping backslashes
 * and inner quotes. This is PostgREST's documented way of carrying reserved
 * characters (`, ( ) : ."` and whitespace) inside filter values.
 */
export function quoteFilterLiteral(value: string): string {
  const escaped = value.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  return `"${escaped}"`;
}

/**
 * PostgreSQL's ***= regular-expression director treats the entire remainder
 * literally. Top-level imatch uses ~*, making this a case-insensitive literal
 * substring search, including quotes, stars, regex syntax and backslashes.
 * postgrest-js performs the only URL encoding; do not quote this value.
 */
export function buildLiteralSearch(q: string): string {
  return `***=${q}`;
}

/**
 * Keyset filter for descending (created_at, id) pagination:
 *   (created_at, id) < (cursor.createdAt, cursor.id)
 * expressed as the body of a PostgREST `or=(…)` group — postgrest-js wraps the
 * returned string in `or=(…)` itself. Cursor parts are strictly validated
 * before this function is reached (timestamp text + UUID).
 */
export function buildKeysetOr(cursor: { createdAt: string; id: string }): string {
  const ts = quoteFilterLiteral(cursor.createdAt);
  return `created_at.lt.${ts},and(created_at.eq.${ts},id.lt.${quoteFilterLiteral(cursor.id)})`;
}
