import { describe, it, expect, vi } from "vitest";
import type { WorkOrder as WorkOrderRow } from "@/lib/db/schema";

import {
  dispatch,
  poll,
  collect,
  openclawAdapter,
  type OpenClawOptions,
} from "../openclaw";
import { getAdapter } from "../index";

// US-028 tests. The OpenClaw adapter's contract is: POST the WorkOrder to the
// remote per-session loop API (`<baseUrl>/sessions`) with bearer auth, return
// the created session id, and never throw — a missing config / network failure /
// non-OK response all resolve to `{ status:'failed', ref:null, error }`. We mock
// `fetch` to assert the request structure and the unconfigured degradation.

const BASE_URL = "https://openclaw.test/api";
const TOKEN = "oc-test-token";

// Inject config + token so tests never depend on the ambient environment.
function opts(fetchImpl: typeof fetch): OpenClawOptions {
  return { baseUrl: BASE_URL, token: TOKEN, fetchImpl };
}

function makeOrder(overrides: Partial<WorkOrderRow> = {}): WorkOrderRow {
  return {
    id: "11111111-1111-1111-1111-111111111111",
    user_id: "22222222-2222-2222-2222-222222222222",
    suggestion_id: null,
    intent: "As a user I want a knowledge-graph concept page",
    context: { node_title: "Graph concept" },
    output_spec: "A rendered concept page",
    gate: "approve-first",
    callback: null,
    budget_tokens: null,
    status: "pending",
    result_ref: null,
    created_at: new Date("2026-06-10T00:00:00.000Z"),
    ...overrides,
  } as WorkOrderRow;
}

// A fetch mock resolving to a JSON body with the given status code.
function jsonFetch(body: unknown, status = 200) {
  return vi.fn(async (_url: string, _init?: RequestInit) => {
    return {
      ok: status >= 200 && status < 300,
      status,
      json: async () => body,
    } as unknown as Response;
  }) as unknown as typeof fetch;
}

describe("dispatch", () => {
  it("POSTs a well-formed session-create request and returns the session id", async () => {
    const fetchMock = jsonFetch({ session_id: "sess-42" });
    const order = makeOrder();

    const result = await dispatch(order, opts(fetchMock));

    expect(result).toEqual({ status: "active", ref: "sess-42" });

    const mock = fetchMock as unknown as ReturnType<typeof vi.fn>;
    expect(mock).toHaveBeenCalledTimes(1);
    const [url, init] = mock.mock.calls[0] as [string, RequestInit];

    // Endpoint: <baseUrl>/sessions (trailing slash on baseUrl normalized away).
    expect(url).toBe(`${BASE_URL}/sessions`);
    expect(init.method).toBe("POST");

    const headers = init.headers as Record<string, string>;
    expect(headers.Authorization).toBe(`Bearer ${TOKEN}`);
    expect(headers["Content-Type"]).toBe("application/json");

    // Body carries the WorkOrder intent + context the per-session loop needs.
    const sent = JSON.parse(init.body as string);
    expect(sent).toEqual({
      intent: order.intent,
      output_spec: order.output_spec,
      context: order.context,
      work_order_id: order.id,
    });
  });

  it("normalizes a trailing slash on the base URL", async () => {
    const fetchMock = jsonFetch({ session_id: "sess-1" });
    await dispatch(makeOrder(), {
      baseUrl: `${BASE_URL}/`,
      token: TOKEN,
      fetchImpl: fetchMock,
    });
    const mock = fetchMock as unknown as ReturnType<typeof vi.fn>;
    const [url] = mock.mock.calls[0] as [string];
    expect(url).toBe(`${BASE_URL}/sessions`);
  });

  it("degrades gracefully (failed, not thrown) when URL is missing", async () => {
    const fetchMock = jsonFetch({ session_id: "x" });
    const result = await dispatch(makeOrder(), {
      token: TOKEN,
      fetchImpl: fetchMock,
    });
    expect(result.status).toBe("failed");
    expect(result.ref).toBeNull();
    expect(result.error).toMatch(/not configured/);
    // No request should have been attempted.
    expect(
      fetchMock as unknown as ReturnType<typeof vi.fn>
    ).not.toHaveBeenCalled();
  });

  it("degrades gracefully when token is missing", async () => {
    const result = await dispatch(makeOrder(), { baseUrl: BASE_URL });
    expect(result.status).toBe("failed");
    expect(result.error).toMatch(/not configured/);
  });

  it("returns a failed outcome on a non-OK HTTP response", async () => {
    const result = await dispatch(makeOrder(), opts(jsonFetch({}, 500)));
    expect(result.status).toBe("failed");
    expect(result.error).toMatch(/HTTP 500/);
  });

  it("returns a failed outcome on a network error (no throw)", async () => {
    const fetchMock = vi.fn(async () => {
      throw new Error("ECONNREFUSED");
    }) as unknown as typeof fetch;
    const result = await dispatch(makeOrder(), opts(fetchMock));
    expect(result.status).toBe("failed");
    expect(result.error).toMatch(/network error/);
  });

  it("returns a failed outcome when the response omits session_id", async () => {
    const result = await dispatch(makeOrder(), opts(jsonFetch({ ok: true })));
    expect(result.status).toBe("failed");
    expect(result.error).toMatch(/missing session_id/);
  });
});

describe("poll", () => {
  it("maps remote status to a normalized running state", async () => {
    const result = await poll("sess-42", opts(jsonFetch({ status: "running" })));
    expect(result).toEqual({ state: "running" });
  });

  it("maps a terminal status to done", async () => {
    const result = await poll(
      "sess-42",
      opts(jsonFetch({ status: "completed" }))
    );
    expect(result.state).toBe("done");
  });

  it("reports unknown when the session is unavailable (non-OK)", async () => {
    const result = await poll("sess-42", opts(jsonFetch({}, 404)));
    expect(result.state).toBe("unknown");
  });

  it("reports unknown when unconfigured", async () => {
    const result = await poll("sess-42", {});
    expect(result.state).toBe("unknown");
  });

  it("GETs the session at <baseUrl>/sessions/<id> with auth", async () => {
    const fetchMock = jsonFetch({ status: "running" });
    await poll("sess 42", opts(fetchMock));
    const mock = fetchMock as unknown as ReturnType<typeof vi.fn>;
    const [url, init] = mock.mock.calls[0] as [string, RequestInit];
    // id is URL-encoded.
    expect(url).toBe(`${BASE_URL}/sessions/sess%2042`);
    expect(init.method).toBe("GET");
    expect((init.headers as Record<string, string>).Authorization).toBe(
      `Bearer ${TOKEN}`
    );
  });
});

describe("collect", () => {
  it("returns the artifact ref once the session is done", async () => {
    const result = await collect(
      "sess-42",
      opts(jsonFetch({ status: "done", result_ref: "artifact://abc" }))
    );
    expect(result).toEqual({ ready: true, ref: "artifact://abc" });
  });

  it("falls back to artifact_url when result_ref is absent", async () => {
    const result = await collect(
      "sess-42",
      opts(jsonFetch({ status: "succeeded", artifact_url: "https://x/y" }))
    );
    expect(result).toEqual({ ready: true, ref: "https://x/y" });
  });

  it("is not ready (null ref) while the session is still running", async () => {
    const result = await collect(
      "sess-42",
      opts(jsonFetch({ status: "running", result_ref: "artifact://abc" }))
    );
    expect(result).toEqual({ ready: false, ref: null });
  });

  it("is not ready when the session is unavailable", async () => {
    const result = await collect("sess-42", opts(jsonFetch({}, 404)));
    expect(result.ready).toBe(false);
    expect(result.ref).toBeNull();
  });
});

describe("getAdapter registry", () => {
  it("returns the openclaw adapter for the openclaw backend", () => {
    expect(getAdapter("openclaw")).toBe(openclawAdapter);
    expect(getAdapter("openclaw").backend).toBe("openclaw");
  });

  it("exposes the full ExecutorAdapter surface", () => {
    expect(typeof openclawAdapter.dispatch).toBe("function");
    expect(typeof openclawAdapter.poll).toBe("function");
    expect(typeof openclawAdapter.collect).toBe("function");
  });

  it("adapter methods degrade gracefully without env config", async () => {
    // No OPENCLAW_* env in the test runner → unconfigured failure, never a throw.
    const out = await openclawAdapter.dispatch(makeOrder());
    expect(out.status).toBe("failed");
    expect(out.error).toMatch(/not configured/);
  });
});
