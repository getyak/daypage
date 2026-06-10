// US-025: sandbox headless browser tool — read-only web fetching.
//
// The gateway lets sandboxed tasks pull a web page for context, but the browser
// must never become an SSRF pivot or a write-capable automation surface. Every
// fetch is screened by a strict URL policy BEFORE a browser is launched:
//   - only http(s) URLs are permitted (no file:, data:, ftp:, javascript:, ...)
//   - private / loopback / link-local / reserved hosts are rejected
//     (localhost, 127.*, 10.*, 172.16-31.*, 192.168.*, 169.254.*, ::1, ...)
//   - an optional host allow-list further restricts which sites may be reached
//   - navigation is strictly read-only: we load the page and read text /
//     screenshot. Form submission and other writes require gate=approve-first
//     and are NOT implemented in this MVP.
//
// The policy (`assertUrlAllowed`) is a pure, synchronous function so SSRF
// rejection is exhaustively unit-testable without launching a real browser.
// `fetchPage` lazily imports playwright so importing this module (e.g. under
// vitest) never pulls up Chromium.

// ─── URL / SSRF policy ───────────────────────────────────────────────────────

/** Raised when a URL is rejected by the read-only fetch policy. */
export class UrlNotAllowedError extends Error {
  constructor(reason: string) {
    super(reason);
    this.name = "UrlNotAllowedError";
  }
}

export interface UrlPolicy {
  /**
   * Optional host allow-list. When provided, the URL's hostname must match one
   * of these entries exactly (case-insensitive) or be a sub-domain of one.
   * When omitted, any public host that passes the SSRF checks is permitted.
   */
  allowedHosts?: readonly string[];
}

/**
 * Reject an IPv4 literal that points at a private, loopback, link-local, or
 * otherwise reserved range. Returns a reason string when blocked, else null.
 */
function blockedIpv4Reason(host: string): string | null {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!m) return null;
  const octets = m.slice(1, 5).map((o) => Number(o));
  if (octets.some((o) => o > 255)) {
    return `invalid IPv4 address '${host}'`;
  }
  const [a, b] = octets;
  // 0.0.0.0/8 — "this host"
  if (a === 0) return `IPv4 '${host}' is in the reserved 0.0.0.0/8 range`;
  // 127.0.0.0/8 — loopback
  if (a === 127) return `IPv4 '${host}' is loopback (127.0.0.0/8)`;
  // 10.0.0.0/8 — private
  if (a === 10) return `IPv4 '${host}' is private (10.0.0.0/8)`;
  // 172.16.0.0/12 — private
  if (a === 172 && b >= 16 && b <= 31) {
    return `IPv4 '${host}' is private (172.16.0.0/12)`;
  }
  // 192.168.0.0/16 — private
  if (a === 192 && b === 168) {
    return `IPv4 '${host}' is private (192.168.0.0/16)`;
  }
  // 169.254.0.0/16 — link-local (includes cloud metadata 169.254.169.254)
  if (a === 169 && b === 254) {
    return `IPv4 '${host}' is link-local (169.254.0.0/16)`;
  }
  // 100.64.0.0/10 — carrier-grade NAT
  if (a === 100 && b >= 64 && b <= 127) {
    return `IPv4 '${host}' is carrier-grade NAT (100.64.0.0/10)`;
  }
  return null;
}

/** Hostnames that are always loopback regardless of DNS. */
const LOOPBACK_HOSTNAMES = new Set([
  "localhost",
  "ip6-localhost",
  "ip6-loopback",
]);

/**
 * Reject an IPv6 literal (already stripped of surrounding brackets) that points
 * at loopback, link-local, or unique-local ranges. Returns a reason or null.
 */
function blockedIpv6Reason(host: string): string | null {
  if (host.indexOf(":") === -1) return null;
  const lower = host.toLowerCase();
  // ::1 loopback (and the fully-expanded form).
  if (lower === "::1" || lower === "0:0:0:0:0:0:0:1") {
    return `IPv6 '${host}' is loopback (::1)`;
  }
  // :: unspecified.
  if (lower === "::" || lower === "0:0:0:0:0:0:0:0") {
    return `IPv6 '${host}' is unspecified (::)`;
  }
  // fe80::/10 link-local.
  if (/^fe[89ab]/.test(lower)) {
    return `IPv6 '${host}' is link-local (fe80::/10)`;
  }
  // fc00::/7 unique-local.
  if (/^f[cd]/.test(lower)) {
    return `IPv6 '${host}' is unique-local (fc00::/7)`;
  }
  // IPv4-mapped IPv6 in dotted form (::ffff:127.0.0.1) — defer to IPv4 check.
  const dotted = /::ffff:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/i.exec(lower);
  if (dotted) {
    return blockedIpv4Reason(dotted[1]);
  }
  // IPv4-mapped IPv6 in hex form (::ffff:7f00:1, as Node normalizes it) —
  // reconstruct the dotted address from the two hextets and re-check.
  const hex = /::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/i.exec(lower);
  if (hex) {
    const high = parseInt(hex[1], 16);
    const low = parseInt(hex[2], 16);
    const dottedAddr = `${(high >> 8) & 0xff}.${high & 0xff}.${(low >> 8) & 0xff}.${low & 0xff}`;
    return (
      blockedIpv4Reason(dottedAddr) ??
      `IPv6 '${host}' is an IPv4-mapped address (::ffff:${dottedAddr})`
    );
  }
  return null;
}

/** True if `host` equals `allowed` or is a sub-domain of it (case-insensitive). */
function hostMatches(host: string, allowed: string): boolean {
  const h = host.toLowerCase();
  const a = allowed.toLowerCase();
  return h === a || h.endsWith(`.${a}`);
}

/**
 * Validate a URL against the read-only fetch policy. Throws UrlNotAllowedError
 * when the URL is unsafe; returns the parsed URL when it is allowed. Pure and
 * synchronous — no DNS, no I/O — so it is exhaustively unit-testable.
 */
export function assertUrlAllowed(url: string, policy: UrlPolicy = {}): URL {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new UrlNotAllowedError(`invalid URL: ${url}`);
  }

  // Only http(s). Rejects file:, data:, ftp:, javascript:, gopher:, etc.
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new UrlNotAllowedError(
      `protocol '${parsed.protocol}' is not allowed; only http(s)`,
    );
  }

  // Strip IPv6 brackets, lower-case for comparison.
  const rawHost = parsed.hostname;
  const host = rawHost.startsWith("[") ? rawHost.slice(1, -1) : rawHost;
  if (host.length === 0) {
    throw new UrlNotAllowedError("URL has an empty host");
  }

  // Loopback hostnames (no DNS needed to know these are local).
  if (LOOPBACK_HOSTNAMES.has(host.toLowerCase())) {
    throw new UrlNotAllowedError(`host '${host}' is loopback`);
  }

  // Private / loopback / link-local IP literals.
  const ipv4Reason = blockedIpv4Reason(host);
  if (ipv4Reason) throw new UrlNotAllowedError(ipv4Reason);
  const ipv6Reason = blockedIpv6Reason(host);
  if (ipv6Reason) throw new UrlNotAllowedError(ipv6Reason);

  // Optional host allow-list.
  if (policy.allowedHosts && policy.allowedHosts.length > 0) {
    const ok = policy.allowedHosts.some((a) => hostMatches(host, a));
    if (!ok) {
      throw new UrlNotAllowedError(`host '${host}' is not on the allow-list`);
    }
  }

  return parsed;
}

// ─── Read-only fetch ─────────────────────────────────────────────────────────

export interface FetchPageOptions {
  /** The page URL. Must be http(s) and pass the SSRF policy. */
  url: string;
  /** Optional host allow-list (see UrlPolicy). */
  allowedHosts?: readonly string[];
  /** Navigation timeout in ms. */
  timeoutMs?: number;
  /** Capture a PNG screenshot (base64) in addition to text. */
  screenshot?: boolean;
}

export interface FetchPageResult {
  url: string;
  /** Final URL after redirects. */
  finalUrl: string;
  /** HTTP status of the main navigation, when available. */
  status: number | null;
  /** Page <title>. */
  title: string;
  /** Rendered visible text content. */
  text: string;
  /** Base64-encoded PNG screenshot, when requested. */
  screenshotBase64?: string;
}

const DEFAULT_TIMEOUT_MS = 30_000;
const MAX_TEXT_LENGTH = 200_000; // guard against pathological pages.

/**
 * Fetch a web page read-only via headless Chromium: navigate, then extract the
 * title, visible text, and (optionally) a screenshot. The URL is screened by
 * `assertUrlAllowed` first; nothing is launched for a rejected URL.
 *
 * This performs NO writes — no clicks, form fills, or submissions. Write
 * operations are gated behind gate=approve-first and are out of scope for the
 * MVP (they are simply not exposed here, never silently executed).
 */
export async function fetchPage(
  opts: FetchPageOptions,
): Promise<FetchPageResult> {
  const {
    url,
    allowedHosts,
    timeoutMs = DEFAULT_TIMEOUT_MS,
    screenshot,
  } = opts;

  // Policy first: a rejected URL never launches a browser.
  const safe = assertUrlAllowed(url, { allowedHosts });

  // Lazy import so this module is cheap to import (e.g. in unit tests).
  const { chromium } = await import("@playwright/test");

  const browser = await chromium.launch({ headless: true });
  try {
    const context = await browser.newContext();
    const page = await context.newPage();

    const response = await page.goto(safe.toString(), {
      waitUntil: "domcontentloaded",
      timeout: timeoutMs,
    });

    const title = await page.title();
    const rawText = await page.evaluate(() => document.body?.innerText ?? "");
    const text = rawText.slice(0, MAX_TEXT_LENGTH);

    let screenshotBase64: string | undefined;
    if (screenshot) {
      const buf = await page.screenshot({ type: "png" });
      screenshotBase64 = buf.toString("base64");
    }

    return {
      url,
      finalUrl: page.url(),
      status: response?.status() ?? null,
      title,
      text,
      ...(screenshotBase64 ? { screenshotBase64 } : {}),
    };
  } finally {
    await browser.close();
  }
}
