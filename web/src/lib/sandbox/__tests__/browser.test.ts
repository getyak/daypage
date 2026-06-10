// US-025: verifies the sandbox headless-browser URL / SSRF policy.
//   - SSRF: private / loopback / link-local hosts are rejected
//     (localhost, 127.*, 10.*, 172.16-31.*, 192.168.*, 169.254.*, ::1, ...)
//   - non-http(s) protocols (file:, data:, ftp:, javascript:) are rejected
//   - the optional host allow-list constrains reachable hosts
//   - legitimate public http(s) URLs are allowed
//
// Only the pure policy is exercised here; `fetchPage` lazily imports playwright
// and is not invoked, so no real browser is launched.
import { describe, it, expect } from "vitest";

import { assertUrlAllowed, UrlNotAllowedError } from "../browser";

describe("assertUrlAllowed — SSRF: private/loopback/link-local rejected", () => {
  it.each([
    // loopback hostname
    "http://localhost/",
    "http://localhost:3000/admin",
    "https://LOCALHOST/",
    // 127.0.0.0/8 loopback
    "http://127.0.0.1/",
    "http://127.0.0.1:8080/secret",
    "http://127.1.2.3/",
    // 10.0.0.0/8 private
    "http://10.0.0.1/",
    "http://10.255.255.255/",
    // 172.16.0.0/12 private
    "http://172.16.0.1/",
    "http://172.31.255.254/",
    // 192.168.0.0/16 private
    "http://192.168.0.1/",
    "http://192.168.1.100/",
    // 169.254.0.0/16 link-local (incl. cloud metadata)
    "http://169.254.0.1/",
    "http://169.254.169.254/latest/meta-data/",
    // 0.0.0.0/8
    "http://0.0.0.0/",
    // IPv6 loopback / link-local / unique-local
    "http://[::1]/",
    "http://[fe80::1]/",
    "http://[fc00::1]/",
    "http://[::ffff:127.0.0.1]/",
  ])("rejects %j", (url) => {
    expect(() => assertUrlAllowed(url)).toThrow(UrlNotAllowedError);
  });

  it("attaches a descriptive reason for a private address", () => {
    expect(() => assertUrlAllowed("http://192.168.1.1/")).toThrow(
      /192\.168\.0\.0\/16/,
    );
  });
});

describe("assertUrlAllowed — non-http(s) protocols rejected", () => {
  it.each([
    "file:///etc/passwd",
    "ftp://example.com/x",
    "data:text/html,<h1>hi</h1>",
    "javascript:alert(1)",
    "gopher://example.com/",
  ])("rejects %j", (url) => {
    expect(() => assertUrlAllowed(url)).toThrow(/only http\(s\)|invalid URL/);
  });
});

describe("assertUrlAllowed — invalid input", () => {
  it.each(["not a url", "", "http://"])("rejects %j", (url) => {
    expect(() => assertUrlAllowed(url)).toThrow(UrlNotAllowedError);
  });
});

describe("assertUrlAllowed — public hosts allowed", () => {
  it.each([
    "https://example.com/",
    "http://example.com/path?q=1",
    "https://news.ycombinator.com/item?id=1",
    "https://8.8.8.8/",
    "https://172.15.0.1/", // just outside 172.16.0.0/12
    "https://172.32.0.1/", // just outside 172.16.0.0/12
  ])("allows %j", (url) => {
    expect(() => assertUrlAllowed(url)).not.toThrow();
    expect(assertUrlAllowed(url)).toBeInstanceOf(URL);
  });
});

describe("assertUrlAllowed — host allow-list", () => {
  const allowedHosts = ["example.com", "trusted.org"] as const;

  it("allows an exact allow-listed host", () => {
    expect(() =>
      assertUrlAllowed("https://example.com/x", { allowedHosts }),
    ).not.toThrow();
  });

  it("allows a sub-domain of an allow-listed host", () => {
    expect(() =>
      assertUrlAllowed("https://docs.example.com/x", { allowedHosts }),
    ).not.toThrow();
  });

  it("rejects a host not on the allow-list", () => {
    expect(() =>
      assertUrlAllowed("https://evil.com/x", { allowedHosts }),
    ).toThrow(/not on the allow-list/);
  });

  it("still rejects a private IP even if the allow-list is permissive", () => {
    expect(() =>
      assertUrlAllowed("http://127.0.0.1/", { allowedHosts: ["127.0.0.1"] }),
    ).toThrow(UrlNotAllowedError);
  });
});
