// Strip HTML script tags and dangerous event handlers from user-supplied text
// to prevent stored XSS when content is rendered as HTML.
const SCRIPT_TAG_RE = /<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/gi;
const EVENT_HANDLER_RE = /\s+on\w+\s*=\s*["'][^"']*["']/gi;
const JAVASCRIPT_HREF_RE = /href\s*=\s*["']?\s*javascript:/gi;

export function sanitizeMemoBody(text: string): string {
  return text
    .replace(SCRIPT_TAG_RE, "")
    .replace(EVENT_HANDLER_RE, "")
    .replace(JAVASCRIPT_HREF_RE, 'href="#"');
}
