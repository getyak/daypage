import { describe, expect, it } from "vitest";
import { unstable_getResponseFromNextConfig } from "next/experimental/testing/server";
import nextConfig from "../../../next.config";

describe("private upload CSP through Next's actual config matcher", () => {
  it.each(["/uploads/a.svg", "/uploads/a.jpg", "/uploads/nested/a.html", "/uploads"])(
    "keeps %s sandboxed after matching the global page policy",
    async (path) => {
      const response = await unstable_getResponseFromNextConfig({
        url: `http://localhost${path}`, nextConfig,
      });
      expect(response.headers.get("content-security-policy")).toBe("sandbox");
      expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    },
  );

  it.each(["/home", "/api/upload", "/uploads-unrelated/a.svg"])(
    "preserves the existing page policy for %s",
    async (path) => {
      const response = await unstable_getResponseFromNextConfig({
        url: `http://localhost${path}`, nextConfig,
      });
      const policy = response.headers.get("content-security-policy");
      expect(policy).toContain("default-src 'self'");
      expect(policy).toContain("frame-ancestors 'none'");
      expect(policy).not.toContain("sandbox");
      expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    },
  );
});
