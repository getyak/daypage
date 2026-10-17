import { describe, it, expect, vi } from "vitest";
import {
  handleAttachmentRequest,
  parseRangeHeader,
  type AttachmentProxyContext,
  type AttachmentProxyUser,
  type ObjectFetchArgs,
} from "../attachment-proxy";
import { supabaseMemoStore } from "../store";
import { FakePostgrest, type FakeRow } from "./fake-postgrest";

const USER_A = "11111111-2222-4333-8444-555555555555";
const USER_B = "22222222-2222-4333-8444-555555555555";
const MEMO_ID = "a1111111-0000-4000-8000-000000000001";
const ATTACH_ID = "aaaa1111-0000-4000-8000-000000000001";

function memoRow(overrides: FakeRow = {}): FakeRow {
  return {
    id: MEMO_ID,
    user_id: USER_A,
    type: "photo",
    body: "hi",
    created_at: "2026-01-01T00:00:00.000000+00:00",
    location: null,
    weather: null,
    device: null,
    source_url: null,
    ingest_mode: "light",
    compile_status: "pending",
    origin: "web",
    vault_path: null,
    deleted_at: null,
    ...overrides,
  };
}

function attachmentRow(overrides: FakeRow = {}): FakeRow {
  return {
    id: ATTACH_ID,
    memo_id: MEMO_ID,
    kind: "photo",
    storage_key: `${USER_A}/${MEMO_ID}/abc123.jpg`,
    filename: "photo.jpg",
    mime_type: "image/jpeg",
    size_bytes: 1000,
    duration_sec: null,
    duration_ms: null,
    position: 0,
    ocr_text: null,
    transcript: null,
    ...overrides,
  };
}

interface MakeCtxOptions {
  user?: AttachmentProxyUser | null;
  memos?: FakeRow[];
  attachments?: FakeRow[];
  upstream?: (args: ObjectFetchArgs) => Promise<Response>;
}

function makeCtx(options: MakeCtxOptions = {}) {
  const db = new FakePostgrest({
    memos: options.memos ?? [memoRow()],
    memo_attachments: options.attachments ?? [attachmentRow()],
  });
  const fetchObject = vi.fn(
    options.upstream ??
      (() =>
        Promise.resolve(
          new Response("bytes", {
            status: 200,
            headers: { "content-type": "image/jpeg", "content-length": "5" },
          }),
        )),
  );
  const ctx: AttachmentProxyContext = {
    authenticate: () =>
      Promise.resolve(options.user === undefined ? { id: USER_A, accessToken: "tok-secret" } : options.user),
    store: supabaseMemoStore(db),
    fetchObject,
  };
  return { ctx, fetchObject, db };
}

function request(path: string, init: RequestInit = {}): Request {
  return new Request(`http://localhost${path}`, init);
}

const PARAMS = { memoId: MEMO_ID, attachmentId: ATTACH_ID };

describe("attachment proxy — authentication and ownership", () => {
  it("returns 401 before any data or upstream access when unauthenticated", async () => {
    const { ctx, fetchObject, db } = makeCtx({ user: null });
    const res = await handleAttachmentRequest(request(`/api/memos/${MEMO_ID}/attachments/${ATTACH_ID}`), PARAMS, ctx);
    expect(res.status).toBe(401);
    expect(fetchObject).not.toHaveBeenCalled();
    expect(db.countCalls("memos")).toBe(0);
  });

  it("works for uid-based identity with no email anywhere", async () => {
    const { ctx } = makeCtx({ user: { id: USER_A, accessToken: "tok" } });
    const res = await handleAttachmentRequest(request(`/api/memos/${MEMO_ID}/attachments/${ATTACH_ID}`), PARAMS, ctx);
    expect(res.status).toBe(200);
  });

  it("returns uniform 404 for malformed ids", async () => {
    const { ctx, fetchObject } = makeCtx();
    for (const params of [
      { memoId: "not-a-uuid", attachmentId: ATTACH_ID },
      { memoId: MEMO_ID, attachmentId: "../../etc" },
    ]) {
      const res = await handleAttachmentRequest(request("/api/memos/x/attachments/y"), params, ctx);
      expect(res.status).toBe(404);
      expect(await res.json()).toEqual({ error: "Not found" });
    }
    expect(fetchObject).not.toHaveBeenCalled();
  });

  it("returns uniform 404 for wrong user, tombstone, missing and wrong-memo rows — no upstream fetch", async () => {
    const tombstoned = memoRow({ deleted_at: "2026-01-02T00:00:00+00:00" });
    const otherMemoAttachment = attachmentRow({
      id: "aaaa2222-0000-4000-8000-000000000002",
      memo_id: "b2222222-0000-4000-8000-000000000002",
    });

    const cases: Array<{ label: string; options: MakeCtxOptions; params?: typeof PARAMS }> = [
      {
        label: "wrong user",
        options: {
          user: { id: USER_B, accessToken: "tok" },
          memos: [memoRow({ user_id: USER_B, id: "b2222222-0000-4000-8000-000000000002" })],
        },
      },
      { label: "tombstone", options: { memos: [tombstoned] } },
      { label: "missing memo", options: { memos: [] } },
      {
        label: "attachment of another memo",
        options: { attachments: [otherMemoAttachment] },
      },
    ];

    for (const testCase of cases) {
      const { ctx, fetchObject } = makeCtx(testCase.options);
      const res = await handleAttachmentRequest(
        request(`/api/memos/${MEMO_ID}/attachments/${ATTACH_ID}`),
        testCase.params ?? PARAMS,
        ctx,
      );
      expect(res.status, testCase.label).toBe(404);
      expect(await res.json(), testCase.label).toEqual({ error: "Not found" });
      expect(fetchObject, testCase.label).not.toHaveBeenCalled();
    }
  });

  it("refuses unsafe or foreign stored keys without fetching upstream", async () => {
    for (const storage_key of [
      `${USER_A}/../../etc/passwd`,
      `${USER_A}/a/./b`,
      "https://evil.example/x.jpg",
      `${USER_B}/${MEMO_ID}/abc123.jpg`,
      `${USER_A}/x\u0000.jpg`,
    ]) {
      const { ctx, fetchObject } = makeCtx({ attachments: [attachmentRow({ storage_key })] });
      const res = await handleAttachmentRequest(
        request(`/api/memos/${MEMO_ID}/attachments/${ATTACH_ID}`),
        PARAMS,
        ctx,
      );
      expect(res.status, storage_key).toBe(404);
      expect(fetchObject, storage_key).not.toHaveBeenCalled();
    }
  });

  it("rejects non-GET/HEAD methods", async () => {
    const { ctx } = makeCtx();
    const res = await handleAttachmentRequest(
      request(`/api/memos/${MEMO_ID}/attachments/${ATTACH_ID}`, { method: "POST" }),
      PARAMS,
      ctx,
    );
    expect(res.status).toBe(405);
    expect(res.headers.get("allow")).toBe("GET, HEAD");
  });
});

describe("attachment proxy — streaming and headers", () => {
  it("streams the upstream body through and propagates the abort signal", async () => {
    const upstreamBody = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new Uint8Array([1, 2, 3]));
        controller.close();
      },
    });
    let captured: ObjectFetchArgs | null = null;
    const { ctx } = makeCtx();
    const ctxWithCapture: AttachmentProxyContext = {
      ...ctx,
      fetchObject: (args: ObjectFetchArgs) => {
        captured = args;
        return Promise.resolve(
          new Response(upstreamBody, {
            status: 200,
            headers: { "content-type": "image/jpeg", "content-length": "3" },
          }),
        );
      },
    };
    const req = request(`/api/memos/${MEMO_ID}/attachments/${ATTACH_ID}`);
    const res = await handleAttachmentRequest(req, PARAMS, ctxWithCapture);
    expect(res.status).toBe(200);
    // Not buffered: the exact upstream stream is handed to the client.
    expect(res.body).toBe(upstreamBody);
    expect(captured).not.toBeNull();
    expect(captured!.key).toBe(`${USER_A}/${MEMO_ID}/abc123.jpg`);
    expect(captured!.signal).toBe(req.signal);
    expect(captured!.accessToken).toBe("tok-secret");

    // Private, no-store, nosniff — safe headers only.
    expect(res.headers.get("cache-control")).toBe("private, no-store");
    expect(res.headers.get("x-content-type-options")).toBe("nosniff");
    expect(res.headers.get("accept-ranges")).toBe("bytes");
    expect(res.headers.get("content-type")).toBe("image/jpeg");
    expect(res.headers.get("content-disposition")).toContain("inline;");
    expect(res.headers.get("set-cookie")).toBeNull();
  });

  it("downloads non-preview MIME as attachment with a CRLF-safe RFC 5987 filename", async () => {
    const evil = 'report\r\nSet-Cookie: pwn=1.pdf';
    const { ctx } = makeCtx({
      attachments: [attachmentRow({ mime_type: "application/pdf", kind: "file", filename: evil })],
    });
    const res = await handleAttachmentRequest(
      request(`/api/memos/${MEMO_ID}/attachments/${ATTACH_ID}`),
      PARAMS,
      ctx,
    );
    const disposition = res.headers.get("content-disposition") ?? "";
    expect(disposition).toContain("attachment;");
    expect(disposition).not.toMatch(/[\r\n]/);
    expect(disposition).toContain("filename*=UTF-8''");
    // No header value may contain CR/LF.
    for (const [, value] of res.headers.entries()) {
      expect(value).not.toMatch(/[\r\n]/);
    }
  });

  it("serves HEAD without a body but with the same safe headers", async () => {
    const { ctx, fetchObject } = makeCtx();
    const res = await handleAttachmentRequest(
      request(`/api/memos/${MEMO_ID}/attachments/${ATTACH_ID}`, { method: "HEAD" }),
      PARAMS,
      ctx,
    );
    expect(res.status).toBe(200);
    expect(res.body).toBeNull();
    expect(res.headers.get("content-type")).toBe("image/jpeg");
    expect(fetchObject).toHaveBeenCalledTimes(1);
  });

  it("fails closed on redirects and upstream errors without leaking tokens or keys", async () => {
    for (const status of [302, 403, 404, 500]) {
      const { ctx } = makeCtx({
        upstream: () =>
          Promise.resolve(
            new Response("secret-upstream-body", {
              status,
              headers: { location: "https://evil.example/steal" },
            }),
          ),
      });
      const res = await handleAttachmentRequest(
        request(`/api/memos/${MEMO_ID}/attachments/${ATTACH_ID}`),
        PARAMS,
        ctx,
      );
      expect(res.status, String(status)).toBe(502);
      const text = await res.text();
      expect(text).not.toContain("secret-upstream-body");
      expect(text).not.toContain("tok-secret");
      expect(text).not.toContain("abc123.jpg");
      expect(text).not.toContain("evil.example");
    }
  });

  it("returns a generic error when the upstream fetch itself fails", async () => {
    const { ctx } = makeCtx({
      upstream: () => Promise.reject(new Error("storage exploded at /secret/path")),
    });
    const res = await handleAttachmentRequest(
      request(`/api/memos/${MEMO_ID}/attachments/${ATTACH_ID}`),
      PARAMS,
      ctx,
    );
    expect(res.status).toBe(502);
    const text = await res.text();
    expect(text).not.toContain("storage exploded");
    expect(text).not.toContain("/secret/path");
  });
});

describe("attachment proxy — byte ranges", () => {
  it("checks the complete closed, open and suffix response interval", async () => {
    const cases = [
      ["bytes=0-9", "bytes 0-8/1000", "9", 502],
      ["bytes=0-9", "bytes 0-10/1000", "11", 502],
      ["bytes=5-", "bytes 5-99/1000", "95", 502],
      ["bytes=-1", "bytes 950-999/1000", "50", 502],
      ["bytes=990-", "bytes 990-1000/1000", "11", 502],
      ["bytes=0-9", "bytes 0-9/1000", "9", 502],
      ["bytes=990-9999", "bytes 990-999/1000", "10", 206],
      ["bytes=990-", "bytes 990-999/1000", "10", 206],
      ["bytes=-1", "bytes 999-999/1000", "1", 206],
      ["bytes=-2000", "bytes 0-999/1000", "1000", 206],
    ] as const;
    for (const [range, contentRange, length, status] of cases) {
      const { ctx } = makeCtx({ upstream: async () => new Response(new Uint8Array(Number(length)), {
        status: 206, headers: { "content-range": contentRange, "content-length": length },
      }) });
      const response = await handleAttachmentRequest(request("/attachment", { headers: { range } }), PARAMS, ctx);
      expect(response.status, `${range}: ${contentRange}`).toBe(status);
      await response.body?.cancel();
    }
  });

  it("cancels discarded bodies on HEAD and every rejected upstream response", async () => {
    for (const [method, status, headers] of [
      ["HEAD", 200, {}], ["HEAD", 206, { "content-range": "bytes 0-9/1000", "content-length": "10" }],
      ["GET", 302, { location: "https://example.invalid" }], ["GET", 416, {}],
      ["GET", 500, {}], ["GET", 206, { "content-range": "bytes 0-99/1000" }],
    ] as const) {
      const cancel = vi.fn();
      const body = new ReadableStream({ cancel });
      const { ctx, fetchObject } = makeCtx({ upstream: async () => new Response(body, { status, headers }) });
      const response = await handleAttachmentRequest(request("/attachment", { method, headers: { range: "bytes=0-9" } }), PARAMS, ctx);
      expect(cancel, `${method} ${status}`).toHaveBeenCalledOnce();
      expect(fetchObject.mock.calls[0][0].method).toBe(method);
      if (method === "HEAD") expect(response.body).toBeNull();
    }
  });

  it("forwards consumer cancellation to the upstream stream", async () => {
    const cancel = vi.fn();
    const { ctx } = makeCtx({ upstream: async () => new Response(new ReadableStream({ cancel })) });
    const response = await handleAttachmentRequest(request("/attachment"), PARAMS, ctx);
    await response.body!.cancel();
    expect(cancel).toHaveBeenCalledOnce();
  });

  it("returns private generic failures for rejected auth and DB promises", async () => {
    const { ctx } = makeCtx();
    ctx.authenticate = async () => { throw new Error("secret token"); };
    const authFailure = await handleAttachmentRequest(request("/attachment"), PARAMS, ctx);
    expect(authFailure.status).toBe(502);
    expect(await authFailure.text()).not.toContain("secret");
    const next = makeCtx().ctx;
    next.store.getAttachmentForMemo = async () => { throw new Error("secret DB path"); };
    const dbFailure = await handleAttachmentRequest(request("/attachment"), PARAMS, next);
    expect(dbFailure.status).toBe(502);
    expect(dbFailure.headers.get("cache-control")).toBe("private, no-store");
  });

  it("parses single ranges strictly", () => {
    expect(parseRangeHeader(null, 1000)).toEqual({ kind: "none" });
    expect(parseRangeHeader("bytes=0-9", 1000).kind).toBe("single");
    expect(parseRangeHeader("bytes=5-", 1000).kind).toBe("single");
    expect(parseRangeHeader("bytes=-100", 1000).kind).toBe("single");
    expect(parseRangeHeader("bytes=0-1,4-5", 1000).kind).toBe("invalid");
    expect(parseRangeHeader("bytes=abc", 1000).kind).toBe("invalid");
    expect(parseRangeHeader("bytes=9-3", 1000).kind).toBe("invalid");
    expect(parseRangeHeader("bytes=-", 1000).kind).toBe("invalid");
    expect(parseRangeHeader("bytes=0-9", null).kind).toBe("single");
  });

  it("forwards a valid range and returns 206 with Content-Range/Accept-Ranges", async () => {
    let forwardedRange: string | null = null;
    const { ctx } = makeCtx({
      upstream: (args) => {
        forwardedRange = args.range;
        return Promise.resolve(
          new Response("chunk", {
            status: 206,
            headers: { "content-range": "bytes 0-9/1000", "content-length": "10" },
          }),
        );
      },
    });
    const res = await handleAttachmentRequest(
      request(`/api/memos/${MEMO_ID}/attachments/${ATTACH_ID}`, { headers: { range: "bytes=0-9" } }),
      PARAMS,
      ctx,
    );
    expect(forwardedRange).toBe("bytes=0-9");
    expect(res.status).toBe(206);
    expect(res.headers.get("content-range")).toBe("bytes 0-9/1000");
    expect(res.headers.get("accept-ranges")).toBe("bytes");
    expect(res.headers.get("cache-control")).toBe("private, no-store");
    expect(res.headers.get("content-type")).toBe("image/jpeg");
  });

  it("rejects malformed, multi and out-of-range requests with 416 and a safe content-range", async () => {
    for (const range of ["bytes=0-1,4-5", "bytes=abc", "bytes=2000-3000"]) {
      const { ctx, fetchObject } = makeCtx();
      const res = await handleAttachmentRequest(
        request(`/api/memos/${MEMO_ID}/attachments/${ATTACH_ID}`, { headers: { range } }),
        PARAMS,
        ctx,
      );
      expect(res.status, range).toBe(416);
      expect(res.headers.get("content-range"), range).toBe("bytes */1000");
      expect(fetchObject, range).not.toHaveBeenCalled();
    }
  });

  it("maps upstream 416 to 416 when the size is unknown", async () => {
    const { ctx } = makeCtx({
      attachments: [attachmentRow({ size_bytes: null })],
      upstream: () => Promise.resolve(new Response(null, { status: 416 })),
    });
    const res = await handleAttachmentRequest(
      request(`/api/memos/${MEMO_ID}/attachments/${ATTACH_ID}`, { headers: { range: "bytes=999999-" } }),
      PARAMS,
      ctx,
    );
    expect(res.status).toBe(416);
    expect(res.headers.get("content-range")).toBeNull();
  });

  it("fails closed on inconsistent upstream partial responses", async () => {
    const inconsistent: Array<{ label: string; status: number; headers: Record<string, string> }> = [
      { label: "206 without content-range", status: 206, headers: {} },
      { label: "206 wrong start", status: 206, headers: { "content-range": "bytes 50-59/1000" } },
      { label: "206 wrong total", status: 206, headers: { "content-range": "bytes 0-9/999" } },
      { label: "206 malformed", status: 206, headers: { "content-range": "bytes ??" } },
      { label: "206 total unknown", status: 206, headers: { "content-range": "bytes 0-9/*" } },
    ];
    for (const testCase of inconsistent) {
      const { ctx } = makeCtx({
        upstream: () => Promise.resolve(new Response("partial", { status: testCase.status, headers: testCase.headers })),
      });
      const res = await handleAttachmentRequest(
        request(`/api/memos/${MEMO_ID}/attachments/${ATTACH_ID}`, { headers: { range: "bytes=0-9" } }),
        PARAMS,
        ctx,
      );
      expect(res.status, testCase.label).toBe(502);
    }
  });

  it("fails closed when upstream answers 206 without a range request", async () => {
    const { ctx } = makeCtx({
      upstream: () =>
        Promise.resolve(
          new Response("partial", { status: 206, headers: { "content-range": "bytes 0-9/1000" } }),
        ),
    });
    const res = await handleAttachmentRequest(
      request(`/api/memos/${MEMO_ID}/attachments/${ATTACH_ID}`),
      PARAMS,
      ctx,
    );
    expect(res.status).toBe(502);
  });
});
