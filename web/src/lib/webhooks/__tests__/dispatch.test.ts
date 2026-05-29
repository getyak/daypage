import { describe, it, expect, vi } from "vitest";
import { createHmac } from "crypto";

// dispatch.ts pulls in the db client at import time; stub it so the pure
// signing helper can be unit-tested without DATABASE_URL.
vi.mock("@/lib/db/client", () => ({ db: {} }));

import { signWebhookBody } from "../dispatch";

describe("signWebhookBody", () => {
  it("produces an HMAC-SHA256 hex signature with the sha256= prefix", () => {
    const body = JSON.stringify({ type: "page.changed", action: "create_page" });
    const secret = "s3cret";
    const sig = signWebhookBody(body, secret);

    const expected =
      "sha256=" + createHmac("sha256", secret).update(body, "utf8").digest("hex");
    expect(sig).toBe(expected);
    expect(sig).toMatch(/^sha256=[0-9a-f]{64}$/);
  });

  it("is deterministic for the same body+secret and differs on change", () => {
    const body = '{"a":1}';
    expect(signWebhookBody(body, "k")).toBe(signWebhookBody(body, "k"));
    expect(signWebhookBody(body, "k")).not.toBe(signWebhookBody(body, "k2"));
    expect(signWebhookBody(body, "k")).not.toBe(signWebhookBody('{"a":2}', "k"));
  });
});
