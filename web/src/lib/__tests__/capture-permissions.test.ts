import { describe, expect, it } from "vitest";
import nextConfig from "../../../next.config";

describe("capture microphone permission policy", () => {
  it("permits user-authorized same-origin speech while denying camera, location and third-party microphone use", async () => {
    const routes = await nextConfig.headers?.();
    const headers = routes?.find((route) => route.source === "/(.*)")?.headers;
    const policy = headers?.find((header) => header.key === "Permissions-Policy")?.value;
    expect(policy).toBe("camera=(), microphone=(self), geolocation=()");
    expect(policy).not.toContain("*");
  });
});
