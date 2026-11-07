// Route A only: actual Next/SSR/browser SDK, synthetic Auth and GET-domains.
// --self-test never listens, starts Next, bundles code or opens a browser.
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { createServer, request as httpRequest } from "node:http";
import { readFile, writeFile, mkdir, readdir, lstat, realpath } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { spawn, execFileSync } from "node:child_process";
import { StringDecoder } from "node:string_decoder";

export const ORIGIN = "http://127.0.0.1:13143";
export const AUTH = "/__get443_supabase";
export const CONTROL = "/__get443_control";
export const PUBLIC_KEY = "synthetic-get443-public-key-not-a-credential";
export const OWNERS = Object.freeze({ A: "aaaaaaaa-0000-4000-8000-000000000001", B: "bbbbbbbb-0000-4000-8000-000000000002" });
const WEB = fileURLToPath(new URL("../", import.meta.url));
const REPO = path.dirname(WEB);
const hash = bytes => createHash("sha256").update(bytes).digest("hex");
const encode = value => Buffer.from(JSON.stringify(value));
const reply = (status, value) => ({ status, bytes: value === undefined ? Buffer.alloc(0) : encode(value), type: "application/json" });
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function exactKeys(value, allowed) {
  return value && typeof value === "object" && !Array.isArray(value) && Object.keys(value).every(key => allowed.includes(key));
}
function wireDigest(manifest) {
  const rows = [...manifest.files].sort((a, b) => Buffer.compare(Buffer.from(a.path), Buffer.from(b.path)))
    .map(file => `${file.path}\0${file.kind}\0${file.bytes}\0${file.sha256}`);
  return hash(Buffer.from(`${manifest.format}\n${manifest.notes_count}\0${manifest.reviews_count}\n${rows.join("\n")}`));
}
function safeFile(root, relative) {
  assert.ok(relative && !relative.includes("\\") && relative.split("/").every(part => part && part !== "." && part !== ".."));
  const file = path.resolve(root, relative);
  assert.ok(file.startsWith(root + path.sep)); return file;
}
async function fileMap(root) {
  const manifestBytes = await readFile(path.join(root, "daypage-exchange.json"));
  const manifest = JSON.parse(manifestBytes);
  assert.ok(manifestBytes.length < 256 * 1024 && manifest.files.length < 20);
  const files = new Map([["daypage-exchange.json", manifestBytes]]);
  for (const row of manifest.files) {
    const file = safeFile(root, row.path), stat = await lstat(file);
    assert.ok(stat.isFile() && !stat.isSymbolicLink() && stat.size < 1024 * 1024);
    const bytes = await readFile(file);
    assert.equal(bytes.length, row.bytes); assert.equal(hash(bytes), row.sha256); files.set(row.path, bytes);
  }
  assert.equal(wireDigest(manifest), manifest.content_sha256);
  return files;
}
async function writeMap(root, files) {
  await mkdir(root, { recursive: true, mode: 0o700 });
  for (const [relative, bytes] of files) {
    const file = safeFile(root, relative); await mkdir(path.dirname(file), { recursive: true }); await writeFile(file, bytes, { flag: "wx" });
  }
}
export function historicalDerivative(original) {
  const files = new Map([...original].map(([name, bytes]) => [name, Buffer.from(bytes)]));
  const records = JSON.parse(files.get("records.json"));
  assert.equal(records.notes.length, 2); assert.equal(records.reviews.length, 1);
  const first = records.notes[0], rawPath = "raw/" + first.day + ".md";
  const blocks = files.get(rawPath).toString("utf8").split("\n\n<!-- daypage-memo-separator -->\n\n");
  assert.equal(blocks.length, 2); assert.equal(hash(Buffer.from(blocks[0])), first.revision);
  assert.ok(blocks[0].endsWith(first.body));
  const body = first.body + "\n\nGET443 changed current source; historical review bytes stay original.";
  const changed = blocks[0].slice(0, -first.body.length) + body;
  records.notes = [{ ...first, body, revision: hash(Buffer.from(changed)) }];
  files.set(rawPath, Buffer.from(changed)); files.set("records.json", encode(records));
  const manifest = JSON.parse(files.get("daypage-exchange.json"));
  manifest.export_id = randomUUID(); manifest.notes_count = 1;
  for (const file of manifest.files) { file.bytes = files.get(file.path).length; file.sha256 = hash(files.get(file.path)); }
  manifest.content_sha256 = wireDigest(manifest); files.set("daypage-exchange.json", encode(manifest));
  assert.ok(files.get(records.reviews[0].file).equals(original.get(records.reviews[0].file)), "Native review metadata/citations/body must remain exact");
  return files;
}
async function fixtures(artifact, previewExchange) {
  const fixtureRoot = path.join(artifact, "fixtures");
  const asset = await fileMap(path.join(WEB, "tests/fixtures/file-exchange-v1"));
  const review = await fileMap(path.join(WEB, "tests/fixtures/file-exchange-reviews-v1/manual-review-fractional-root"));
  const values = { asset, review, historical: historicalDerivative(review) }, metadata = {};
  for (const [name, files] of Object.entries(values)) {
    const directory = path.join(fixtureRoot, name); await writeMap(directory, files);
    const manifest = JSON.parse(files.get("daypage-exchange.json"));
    if (previewExchange) {
      const preview = await previewExchange([...files].map(([file, bytes]) => ({ path: file, size: bytes.length, read: async () => bytes })));
      if (name === "historical") assert.deepEqual(preview.reviewSources.map(x => [x.current, x.changed, x.unavailable]), [[0, 1, 1]]);
    }
    metadata[name] = { directory, exportID: manifest.export_id, notes: manifest.notes_count, reviews: manifest.reviews_count,
      files: [...files].map(([file, bytes]) => ({ path: file, bytes: bytes.length, sha256: hash(bytes) })) };
  }
  await writeFile(path.join(artifact, "fixture-manifest.json"), JSON.stringify(metadata, null, 2) + "\n");
  return { metadata, values };
}

export class SyntheticAuth {
  issued = new Map(); refresh = new Map(); held = new Map(); holdOwner = null; denyOwner = null;
  sequence = 0; released = 0; ledger = [];
  user(owner) {
    return { id: OWNERS[owner], aud: "authenticated", role: "authenticated", email: `synthetic-${owner.toLowerCase()}@get443.invalid`,
      app_metadata: { provider: "email", providers: ["email"] }, user_metadata: { name: "Synthetic " + owner },
      identities: [], created_at: "2026-11-07T00:00:00Z", updated_at: "2026-11-07T00:00:00Z" };
  }
  session(owner) {
    const now = Math.floor(Date.now() / 1000), user = this.user(owner);
    const jwt = [Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString("base64url"),
      Buffer.from(JSON.stringify({ sub: user.id, aud: "authenticated", role: "authenticated", iat: now, exp: now + 3600, session_id: randomUUID() })).toString("base64url"),
      createHash("sha256").update(randomUUID()).digest("base64url")].join(".");
    const refresh = randomUUID(); this.issued.set(jwt, owner); this.refresh.set(refresh, owner);
    return { access_token: jwt, refresh_token: refresh, token_type: "bearer", expires_in: 3600, expires_at: now + 3600, user };
  }
  state() { return { held: this.held.size, released: this.released, holdOwner: this.holdOwner, denyOwner: this.denyOwner }; }
  release() {
    const held = [...this.held.values()]; this.held.clear(); this.holdOwner = null;
    for (const release of held) { this.released++; release(); }
  }
  async handle(method, url, headers, bytes = Buffer.alloc(0)) {
    const client = headers["x-client-info"] ?? "";
    const browser = client === "supabase-ssr/0.12.0 createBrowserClient";
    const server = client === "supabase-ssr/0.12.0 createServerClient";
    const owner = this.issued.get((headers.authorization ?? "").replace(/^Bearer /, ""));
    const log = { method, path: url.pathname, client: browser ? "browser" : server ? "server" : "unknown", outcome: "rejected" };
    this.ledger.push(log);
    if ((!browser && !server) || headers.apikey !== PUBLIC_KEY) return reply(403, { error_code: "fixture_client", msg: "Synthetic SDK identity required" });
    if (url.pathname === AUTH + "/auth/v1/user" && method === "GET" && !url.search) {
      if (!owner) return reply(401, { error_code: "bad_jwt", msg: "Synthetic session required" });
      if (browser && owner === this.denyOwner) { log.outcome = "synthetic-denied"; return reply(403, { error_code: "fixture_denied", msg: "Synthetic verification denied" }); }
      const value = reply(200, this.user(owner)); // Capture A now; B later cannot rewrite an old response.
      if (browser && owner === this.holdOwner) {
        log.outcome = "held"; const id = ++this.sequence;
        await new Promise(resolve => this.held.set(id, resolve));
        log.outcome = "released";
      } else log.outcome = "allowed";
      return value;
    }
    if (url.pathname === AUTH + "/auth/v1/token" && method === "POST" && [...url.searchParams.keys()].join() === "grant_type") {
      let body; try { body = JSON.parse(bytes); } catch { return reply(400, { msg: "Synthetic JSON required" }); }
      if (url.searchParams.get("grant_type") === "password" && exactKeys(body, ["email", "password", "gotrue_meta_security"]) &&
        body.password === "get443-synthetic-fixture-input" &&
        (!body.gotrue_meta_security || (exactKeys(body.gotrue_meta_security, []) && Object.keys(body.gotrue_meta_security).length === 0))) {
        const selected = ["A", "B"].find(name => this.user(name).email === body.email);
        if (selected) { log.outcome = "allowed"; return reply(200, this.session(selected)); }
      }
      if (url.searchParams.get("grant_type") === "refresh_token" && exactKeys(body, ["refresh_token"]) && this.refresh.has(body.refresh_token)) {
        log.outcome = "allowed"; return reply(200, this.session(this.refresh.get(body.refresh_token)));
      }
      return reply(400, { msg: "Only explicit synthetic fixture input is accepted" });
    }
    if (url.pathname === AUTH + "/auth/v1/logout" && method === "POST" && owner && url.search === "?scope=local" && bytes.length === 0) {
      log.outcome = "allowed"; return reply(204);
    }
    if (url.pathname === AUTH + "/rest/v1/domains" && method === "GET" && owner &&
      [...url.searchParams.keys()].sort().join() === "order,select,user_id" &&
      url.searchParams.get("user_id") === "eq." + OWNERS[owner] &&
      url.searchParams.get("select") === "id,label,slug,color" && url.searchParams.get("order") === "position.asc,created_at.asc") {
      log.outcome = "allowed"; return reply(200, []);
    }
    return reply(403, { msg: "Fixture rejects every other Auth/REST/storage/provider operation" });
  }
}

function packageInfo(require, name) {
  const entry = require.resolve(name); let folder = path.dirname(entry);
  for (let n = 0; n < 8; n++, folder = path.dirname(folder)) {
    try {
      const file = path.join(folder, "package.json"), json = require(file);
      if (json.name === name) return { entry, file, version: json.version };
    } catch { /* Continue only along this resolved package's parents. */ }
  }
  throw new Error("Cannot identify installed pinned package: " + name);
}
async function bundles(artifact) {
  const require = createRequire(new URL("../package.json", import.meta.url));
  const tsx = packageInfo(require, "tsx"), ssr = packageInfo(require, "@supabase/ssr");
  const playwright = packageInfo(require, "@playwright/test"), next = packageInfo(require, "next"), react = packageInfo(require, "react");
  const sdk = packageInfo(createRequire(ssr.entry), "@supabase/supabase-js"), auth = packageInfo(createRequire(sdk.entry), "@supabase/auth-js");
  assert.equal(tsx.version, "4.20.6"); assert.equal(ssr.version, "0.12.0"); assert.equal(sdk.version, "2.108.2"); assert.equal(auth.version, "2.108.2");
  assert.equal(playwright.version, "1.60.0"); assert.equal(next.version, "16.2.6"); assert.equal(react.version, "19.2.4");
  const build = createRequire(tsx.entry)("esbuild"); assert.equal(build.version, "0.25.10");
  const out = path.join(artifact, "bundles"); await mkdir(out, { recursive: true });
  const peer = await build.build({ absWorkingDir: WEB, entryPoints: ["scripts/file-exchange-notebooks-peer.ts"],
    bundle: true, platform: "browser", format: "iife", target: "es2020", outfile: path.join(out, "peer.js"),
    define: { "process.env.NODE_ENV": '"production"' }, metafile: true, logLevel: "silent" });
  const codec = await build.build({ absWorkingDir: WEB, entryPoints: ["src/lib/file-exchange/preview.ts"],
    bundle: true, platform: "node", format: "esm", target: "node22", outfile: path.join(out, "codec.mjs"), metafile: true, logLevel: "silent" });
  const packages = await Promise.all([tsx, ssr, sdk, auth, playwright, next, react].map(async value => ({ ...value, sha256: hash(await readFile(value.file)) })));
  await writeFile(path.join(artifact, "bundle-provenance.json"), JSON.stringify({ packages, esbuild: build.version,
    peerInputs: peer.metafile.inputs, codecInputs: codec.metafile.inputs, peerSHA256: hash(await readFile(path.join(out, "peer.js"))),
    lockSHA256: hash(await readFile(path.join(REPO, "pnpm-lock.yaml"))) }, null, 2) + "\n");
  return { peer: await readFile(path.join(out, "peer.js")), previewExchange: (await import(pathToFileURL(path.join(out, "codec.mjs")).href)).previewExchange };
}
async function artifactRoot() {
  const value = process.env.GET443_NOTEBOOKS_ARTIFACT_DIR;
  assert.ok(value && path.isAbsolute(value), "Use a dedicated absolute task artifact directory");
  const root = path.resolve(value);
  assert.ok(root !== path.parse(root).root && !root.startsWith(REPO + path.sep) && root !== REPO);
  await mkdir(root, { recursive: true, mode: 0o700 });
  assert.equal((await lstat(root)).isSymbolicLink(), false); assert.equal(await realpath(root), root);
  return root;
}
function requirePublicConfig() {
  assert.equal(process.env.GET443_NOTEBOOKS_RUN, "1");
  assert.equal(process.env.NEXT_PUBLIC_SUPABASE_URL, ORIGIN + AUTH);
  assert.equal(process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY, PUBLIC_KEY);
  assert.equal(process.env.NEXT_TELEMETRY_DISABLED, "1"); assert.equal(process.env.DAYPAGE_PRIVATE_PREVIEW, "1");
  for (const key of ["DATABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "INNGEST_SIGNING_KEY", "UPSTASH_REDIS_REST_TOKEN"]) {
    assert.ok(!Object.hasOwn(process.env, key), "Unexpected credential variable present: " + key);
  }
}
function peerHTML() {
  return `<!doctype html><html lang="en" data-realm="${ORIGIN + AUTH}" data-public-key="${PUBLIC_KEY}"><head><meta charset="utf-8"><title>GET443 synthetic SDK peer</title></head><body><h1>Actual pinned SDK, synthetic Auth service</h1><p>No real Auth acceptance.</p><form id="sign-in-A"><button>Sign in synthetic A</button></form><form id="sign-in-B"><button>Sign in synthetic B</button></form><form id="sign-out"><button>Sign out local synthetic session</button></form><output id="peer-status" role="status">Ready</output><output id="peer-event">Waiting for INITIAL_SESSION</output><script src="/__get443_sdk/peer.js" defer></script></body></html>`;
}
async function readBody(request) {
  const chunks = []; let size = 0;
  for await (const chunk of request) { size += chunk.length; assert.ok(size <= 64 * 1024, "Bounded fixture request"); chunks.push(chunk); }
  return Buffer.concat(chunks);
}
function send(response, result) {
  response.writeHead(result.status, { "Content-Type": result.type, "Cache-Control": "no-store", "Content-Length": result.bytes.length });
  response.end(result.bytes);
}
function containsSelectedData(text, markers) { return markers.some(marker => marker.length >= 8 && text.includes(marker)); }
function acceptedNextExit(result, requestedSignal) {
  if (![null, "SIGTERM"].includes(requestedSignal) || !exactKeys(result, ["code", "signal"]) || Object.keys(result).length !== 2) return false;
  return (result.code === 0 && result.signal === null) ||
    // Pinned Next16.2.6 start-server.ts graceful SIGTERM cleanup exits143.
    // Accept it only when our successful child.kill recorded that request;
    // this never overrides startup-failure or unexpected-exit flags.
    (result.code === 143 && result.signal === null && requestedSignal === "SIGTERM") ||
    (result.code === null && result.signal === "SIGTERM" && requestedSignal === "SIGTERM");
}
function safeStartupLine(line) {
  const plain = line.replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, "");
  if (/authorization|cookie|token|password|secret|session|credential|NEXT_PUBLIC_|SUPABASE_|eyJ[\w-]+\.[\w-]+\.[\w-]+|(?:sk-proj-|ghp_|github_pat_|lin_api_)/i.test(plain)) return "[redacted-sensitive-startup-line]";
  return plain.replace(/https?:\/\/[^\s<>"']+/g, value => {
    try { const url = new URL(value); return url.origin === "http://127.0.0.1:13144" ? url.origin + url.pathname : "[redacted-url]"; } catch { return "[redacted-url]"; }
  }).replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[redacted-email]").slice(0, 360);
}
function startupOutput() {
  const lines = [], streams = new Map(); let dropped = 0, closed = false;
  function save(stream, value) { if (lines.length < 48) lines.push({ stream, text: safeStartupLine(value) }); else dropped++; }
  return {
    push(stream, bytes) {
      if (closed) return;
      let state = streams.get(stream);
      if (!state) { state = { decoder: new StringDecoder("utf8"), partial: "", oversized: false }; streams.set(stream, state); }
      for (const part of state.decoder.write(bytes).split(/(\n)/)) {
        if (part === "\n") {
          if (state.oversized) dropped++; else if (state.partial) save(stream, state.partial);
          state.partial = ""; state.oversized = false;
        } else if (!state.oversized) {
          state.partial += part;
          if (state.partial.length > 4096) { state.partial = ""; state.oversized = true; }
        }
      }
    },
    finish() {
      if (!closed) for (const [stream, state] of streams) {
        state.partial += state.decoder.end();
        if (state.oversized) dropped++; else if (state.partial) save(stream, state.partial);
      }
      closed = true; streams.clear(); return { lines, dropped, captureBoundary: "before-private-readiness-only" };
    },
  };
}
function listenerEvidence(output, childPID) {
  const records = output.trim().split("\n");
  const valid = records.every(line => /^(?:p[1-9][0-9]*|f[0-9]+)$/.test(line));
  const pids = [...new Set(records.filter(line => /^p[1-9][0-9]*$/.test(line)))];
  return { owned: valid && pids.join() === "p" + childPID, valid,
    // Only the requested PID/FD fields may be retained, never arbitrary lsof
    // errors/file paths. Preserve suffixes to diagnose dialect differences.
    fields: records.slice(0, 20).map(line => /^[pf][0-9]+[A-Za-z]*$/.test(line) ? line.slice(0, 40) : "[unrecognized-field]") };
}
function markersFor(values) {
  const markers = new Set();
  for (const files of Object.values(values)) for (const [name, bytes] of files) {
    markers.add(name); markers.add(hash(bytes));
    const text = bytes.toString("utf8");
    if (name === "records.json") { const value = JSON.parse(text); for (const row of [...value.notes, ...value.reviews]) if (row.body) markers.add(row.body); }
    markers.add(text);
  }
  return [...markers].flatMap(value => [value, encodeURIComponent(value), JSON.stringify(value).slice(1, -1), Buffer.from(value).toString("base64")]);
}

export async function serve() {
  requirePublicConfig(); const artifact = await artifactRoot();
  for (const file of [".env", ".env.local", ".env.production", ".env.production.local"]) {
    await assert.rejects(lstat(path.join(WEB, file)), error => error.code === "ENOENT", "No real env files in fixture process");
  }
  const built = await bundles(artifact), staged = await fixtures(artifact, built.previewExchange), markers = markersFor(staged.values);
  const nextEntry = createRequire(new URL("../package.json", import.meta.url)).resolve("next/dist/bin/next");
  const sourceSHA = execFileSync("git", ["rev-parse", "HEAD"], { cwd: REPO, encoding: "utf8" }).trim();
  const auth = new SyntheticAuth(), network = []; let ready = false, closing = false, child;
  const server = createServer(async (request, response) => {
    const url = new URL(request.url ?? "/", ORIGIN), method = request.method ?? "GET";
    try {
      if (url.origin !== ORIGIN || request.headers.host !== "127.0.0.1:13143" || (request.headers.origin && request.headers.origin !== ORIGIN)) {
        network.push({ method, path: "[origin-rejected]", outcome: "rejected" }); return send(response, reply(403, { error: "fixture-origin" }));
      }
      const body = await readBody(request);
      if (containsSelectedData(url.href + "\n" + JSON.stringify(request.headers) + "\n" + body.toString("utf8"), markers)) {
        network.push({ method, path: "[selected-data-rejected]", outcome: "selected-data-rejected" }); return send(response, reply(403, { error: "selected-data" }));
      }
      if (url.pathname.startsWith(AUTH + "/")) return send(response, await auth.handle(method, url, request.headers, body));
      if (url.pathname.startsWith(CONTROL + "/")) {
        if (method === "GET" && url.pathname === CONTROL + "/ready") return send(response, reply(ready ? 200 : 503, { ready }));
        if (method === "GET" && url.pathname === CONTROL + "/info") return send(response, reply(200, { sourceSHA, origin: ORIGIN, fixtures: staged.metadata, auth: auth.state() }));
        if (method === "GET" && url.pathname === CONTROL + "/state") return send(response, reply(200, { ...auth.state(), authLedger: auth.ledger, network }));
        if (method === "POST" && url.pathname === CONTROL + "/mode") {
          const value = JSON.parse(body); assert.ok(exactKeys(value, ["hold", "deny", "release"]) && [null, "A", "B", undefined].includes(value.hold) && [null, "A", "B", undefined].includes(value.deny));
          if (value.release) auth.release(); auth.holdOwner = value.hold ?? null; auth.denyOwner = value.deny ?? null;
          return send(response, reply(200, auth.state()));
        }
        return send(response, reply(403, { error: "fixture-control" }));
      }
      if (method === "GET" && url.pathname === "/__get443_sdk/peer") return send(response, { status: 200, bytes: Buffer.from(peerHTML()), type: "text/html; charset=utf-8" });
      if (method === "GET" && url.pathname === "/__get443_sdk/peer.js") return send(response, { status: 200, bytes: built.peer, type: "text/javascript" });
      if (!["GET", "HEAD"].includes(method) || url.pathname.startsWith("/api/") || /\/(?:storage|agent|telemetry)\b/i.test(url.pathname)) {
        network.push({ method, path: url.pathname, outcome: "rejected" }); return send(response, reply(403, { error: "fixture-rejects-write-or-api" }));
      }
      network.push({ method, path: url.pathname, outcome: "next" });
      const upstream = httpRequest({ hostname: "127.0.0.1", port: 13144, method, path: request.url,
        headers: { ...request.headers, host: "127.0.0.1:13143", "x-forwarded-host": "127.0.0.1:13143", "x-forwarded-proto": "http" } }, incoming => {
        const headers = { ...incoming.headers };
        if (typeof headers.location === "string") headers.location = headers.location.replace("http://127.0.0.1:13144", ORIGIN);
        response.writeHead(incoming.statusCode ?? 502, headers); incoming.pipe(response);
      });
      upstream.on("error", () => { if (!response.headersSent) send(response, reply(502, { error: "private-next-unavailable" })); else response.destroy(); });
      upstream.end(body);
    } catch {
      network.push({ method, path: "[fixture-error]", outcome: "fixture-error" });
      if (!response.headersSent) send(response, reply(500, { error: "fixture-request-failed" })); else response.destroy();
    }
  });
  server.on("upgrade", (_, socket) => { network.push({ method: "UPGRADE", path: "[websocket]", outcome: "rejected" }); socket.destroy(); });
  await new Promise((resolve, reject) => { server.once("error", reject); server.listen(13143, "127.0.0.1", resolve); });
  const env = Object.fromEntries(["PATH", "HOME", "LANG", "LC_ALL", "SYSTEMROOT", "CI"].filter(key => process.env[key] !== undefined).map(key => [key, process.env[key]]));
  Object.assign(env, { NEXT_TELEMETRY_DISABLED: "1", DAYPAGE_PRIVATE_PREVIEW: "1", NEXT_PUBLIC_SUPABASE_URL: ORIGIN + AUTH,
    NEXT_PUBLIC_SUPABASE_ANON_KEY: PUBLIC_KEY, TMPDIR: artifact });
  const output = startupOutput(), readiness = { attempts: [], ready: false, failure: null };
  try {
    child = spawn(process.execPath, [nextEntry, "start", "--hostname", "127.0.0.1", "--port", "13144"], { cwd: WEB, env, stdio: ["ignore", "pipe", "pipe"] });
    child.stdout.on("data", bytes => output.push("stdout", bytes)); child.stderr.on("data", bytes => output.push("stderr", bytes));
  } catch (error) { server.close(); throw error; }
  let unexpectedChildExit = false, spawnFailed = false;
  const exit = new Promise(resolve => {
    child.once("exit", (code, signal) => { if (!closing) unexpectedChildExit = true; ready = false; resolve({ code, signal }); });
    child.once("error", () => { spawnFailed = true; ready = false; resolve({ code: null, signal: null, spawnFailed: true }); });
  });
  async function shutdown(signal, failure = false) {
    if (closing) return; closing = true; ready = false; auth.release(); server.close();
    let requestedNextSignal = null;
    if (child.exitCode === null && child.signalCode === null && child.kill("SIGTERM")) requestedNextSignal = "SIGTERM";
    const result = await Promise.race([exit, sleep(10_000).then(() => null)]);
    const clean = acceptedNextExit(result, requestedNextSignal) && !unexpectedChildExit && !spawnFailed && !failure;
    await writeFile(path.join(artifact, "server-startup.json"), JSON.stringify({ childPID: child.pid ?? null, ...readiness, output: output.finish() }, null, 2) + "\n");
    await writeFile(path.join(artifact, "server-exit.json"), JSON.stringify({ signal, requestedNextSignal, nextPID: child.pid ?? null, nextExit: result,
      verifiedExit: Boolean(result), unexpectedChildExit, passed: clean, authLedger: auth.ledger, network }, null, 2) + "\n");
    process.exit(clean ? 0 : 1);
  }
  process.once("SIGTERM", () => void shutdown("SIGTERM")); process.once("SIGINT", () => void shutdown("SIGINT"));
  function ownsPrivateListener() {
    try {
      const output = execFileSync("lsof", ["-nP", "-iTCP:13144", "-sTCP:LISTEN", "-Fp"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
      return listenerEvidence(output, child.pid);
    } catch (error) { return { owned: false, commandError: /^[A-Z0-9_]+$/.test(error.code ?? "") ? error.code : null, exitCode: Number.isInteger(error.status) ? error.status : null }; }
  }
  try {
    for (let attempt = 0; attempt < 120; attempt++) {
      assert.ok(!spawnFailed && !unexpectedChildExit && child.exitCode === null && child.signalCode === null, "Private Next exited before readiness");
      const lookup = ownsPrivateListener(), record = { attempt, lookup, status: null, fetchError: null };
      readiness.attempts.push(record);
      if (lookup.owned) {
        try {
          const value = await fetch("http://127.0.0.1:13144/notebooks", { redirect: "manual", signal: AbortSignal.timeout(1000) });
          record.status = value.status; if ([200, 307, 308].includes(value.status)) { ready = true; break; }
        } catch (error) { record.fetchError = ["AbortError", "TimeoutError", "TypeError"].includes(error.name) ? error.name : "other"; }
      }
      await sleep(250);
    }
    assert.ok(ready, "Private actual Next did not become ready");
    readiness.ready = true;
    await writeFile(path.join(artifact, "server-startup.json"), JSON.stringify({ childPID: child.pid, ...readiness, output: output.finish() }, null, 2) + "\n");
    await writeFile(path.join(artifact, "server-provenance.json"), JSON.stringify({ sourceSHA, listenerOwnedByNextPID: true,
      origin: ORIGIN, nextPID: child.pid, publicRealm: ORIGIN + AUTH, fixtureMode: "synthetic-auth-only", actualNext: true,
      buildID: (await readFile(path.join(WEB, ".next/BUILD_ID"), "utf8")).trim() }, null, 2) + "\n");
  } catch (error) {
    readiness.failure = safeStartupLine(error.message ?? "Private readiness failed");
    await shutdown("startup-failure", true);
  }
}

function assertBrowserLedgers(ledger) {
  assert.equal(ledger.browsers.length, 2);
  assert.deepEqual(ledger.browsers.map(browser => browser.phase), [0, 1]);
  for (const browser of ledger.browsers) {
    assert.ok(browser.rows.length > 0); assert.ok(browser.rows.every(row => row.outcome === "allowed")); assert.deepEqual(browser.errors, []);
  }
}
export async function verifyEvidence() {
  const root = await artifactRoot(), load = async name => JSON.parse(await readFile(safeFile(root, name), "utf8"));
  const source = await load("server-provenance.json"), exit = await load("server-exit.json"), report = await load("playwright-results.json");
  assert.equal(source.actualNext, true); assert.equal(source.listenerOwnedByNextPID, true); assert.equal(source.origin, ORIGIN);
  assert.equal(source.publicRealm, ORIGIN + AUTH); assert.ok(source.buildID);
  assert.equal(source.sourceSHA, execFileSync("git", ["rev-parse", "HEAD"], { cwd: REPO, encoding: "utf8" }).trim());
  assert.equal(exit.nextPID, source.nextPID); assert.equal(exit.verifiedExit, true); assert.equal(exit.passed, true); assert.equal(exit.unexpectedChildExit, false);
  assert.equal(acceptedNextExit(exit.nextExit, exit.requestedNextSignal), true, "Next must exit0 or use a supported result of this task's requested SIGTERM");
  assert.ok(exit.network.every(row => row.outcome === "next"));
  assert.ok(exit.authLedger.every(row => ["allowed", "released", "synthetic-denied"].includes(row.outcome)));
  assert.ok(exit.authLedger.some(row => row.client === "server" && row.path === AUTH + "/rest/v1/domains"));
  assert.equal(report.stats.expected, 2); assert.equal(report.stats.unexpected, 0); assert.equal(report.stats.skipped, 0); assert.equal(report.stats.flaky, 0);
  const tests = [];
  function visit(suite) { for (const spec of suite.specs ?? []) tests.push(...spec.tests); for (const child of suite.suites ?? []) visit(child); }
  for (const suite of report.suites) visit(suite);
  assert.equal(tests.length, 2); assert.deepEqual(tests.map(test => test.projectName).sort(), ["desktop", "narrow"]);
  for (const test of tests) { assert.equal(test.expectedStatus, "passed"); assert.equal(test.results.length, 1); assert.equal(test.results[0].status, "passed"); }
  for (const project of ["desktop", "narrow"]) {
    const value = await load("ui/" + project + "/acceptance.json");
    assert.equal(value.project, project); assert.equal(value.sourceSHA, source.sourceSHA); assert.equal(value.passed, true);
    assert.deepEqual(value.viewport, project === "desktop" ? { width: 1440, height: 900 } : { width: 375, height: 812 });
    for (const key of ["picker", "previewNoWrites", "cancelNoWrites", "confirmedReadback", "coldReopen", "zipOriginalBytes", "assetOriginalBytes", "reviewOriginalBytes", "historicalSources", "crossTabSignOut", "switchOwner", "lateOwnerFence", "initialNullLocked", "initialDeniedLocked", "deadlineLateLocked", "networkBoundary"]) assert.equal(value.assertions[key], true, project + ":" + key);
    assert.equal(value.browserExits.length, 2);
    for (const browser of value.browserExits) { assert.equal(browser.verifiedExit, true); assert.equal(browser.forced, false); assert.equal(browser.profileRemoved, true); }
    const ledger = await load("ui/" + project + "/network-ledger.json");
    assertBrowserLedgers(ledger);
    for (const label of ["confirmed", "cold-reopen", "historical-review", "identity-locked"]) {
      assert.ok(value.files.some(file => file.path === `ui/${project}/${label}.png`));
    }
    assert.ok(value.files.filter(file => file.kind === "download").length >= 3);
    for (const file of value.files) {
      const bytes = await readFile(safeFile(root, file.path)); assert.equal(bytes.length, file.bytes); assert.equal(hash(bytes), file.sha256);
    }
  }
  await writeFile(path.join(root, "verified-ui-acceptance.json"), JSON.stringify({ passed: true, sourceSHA: source.sourceSHA,
    projects: ["desktop", "narrow"], authMode: "synthetic-service-real-pinned-sdk", strictModeDevelopment: "not executed", realAuth: "not executed" }, null, 2) + "\n");
  console.log("Verified both actual Next UI suites, original downloads, safe network ledger and owned process cleanup. Synthetic Auth only; development StrictMode and real Auth remain unverified.");
}

async function selfTest() {
  const a = new SyntheticAuth(), headers = { "x-client-info": "supabase-ssr/0.12.0 createBrowserClient", apikey: PUBLIC_KEY };
  const token = await a.handle("POST", new URL(AUTH + "/auth/v1/token?grant_type=password", ORIGIN), headers,
    encode({ email: "synthetic-a@get443.invalid", password: "get443-synthetic-fixture-input", gotrue_meta_security: {} }));
  assert.equal(token.status, 200); const session = JSON.parse(token.bytes); headers.authorization = "Bearer " + session.access_token;
  a.holdOwner = "A"; const held = a.handle("GET", new URL(AUTH + "/auth/v1/user", ORIGIN), headers); assert.equal(a.state().held, 1);
  const b = a.session("B"); assert.equal(a.issued.get(b.access_token), "B"); a.release(); assert.equal(JSON.parse((await held).bytes).id, OWNERS.A);
  a.denyOwner = "A"; assert.equal((await a.handle("GET", new URL(AUTH + "/auth/v1/user", ORIGIN), headers)).status, 403);
  assert.equal((await a.handle("POST", new URL(AUTH + "/rest/v1/domains", ORIGIN), headers, encode({ body: "never accepted" }))).status, 403);
  const original = await fileMap(path.join(WEB, "tests/fixtures/file-exchange-reviews-v1/manual-review-fractional-root"));
  const changed = historicalDerivative(original), records = JSON.parse(changed.get("records.json"));
  assert.equal(records.notes.length, 1); assert.equal(records.reviews[0].sources.length, 2);
  assert.notEqual(records.notes[0].revision, records.reviews[0].sources[0].revision);
  assert.ok(changed.get(records.reviews[0].file).equals(original.get(records.reviews[0].file)));
  assert.equal(wireDigest(JSON.parse(changed.get("daypage-exchange.json"))), JSON.parse(changed.get("daypage-exchange.json")).content_sha256);
  const ledger = { browsers: [0, 1].map(phase => ({ phase, rows: [{ outcome: "allowed" }], errors: [] })) };
  assertBrowserLedgers(ledger);
  for (const phase of [0, 1]) {
    const rejected = structuredClone(ledger); rejected.browsers[phase].rows.push({ outcome: "rejected" }); assert.throws(() => assertBrowserLedgers(rejected));
    const failed = structuredClone(ledger); failed.browsers[phase].errors.push("synthetic-error"); assert.throws(() => assertBrowserLedgers(failed));
  }
  assert.throws(() => assertBrowserLedgers({ browsers: ledger.browsers.slice(1) }));
  assert.equal(acceptedNextExit({ code: 0, signal: null }, null), true);
  assert.equal(acceptedNextExit({ code: 0, signal: null }, "SIGTERM"), true);
  assert.equal(acceptedNextExit({ code: null, signal: "SIGTERM" }, "SIGTERM"), true);
  assert.equal(acceptedNextExit({ code: 143, signal: null }, "SIGTERM"), true);
  for (const value of [null, {}, { code: 1, signal: null }, { code: null, signal: null }, { code: null, signal: "SIGKILL" },
    { code: 0, signal: "SIGTERM" }, { code: "0", signal: null }, { code: 0 }, { code: 0, signal: null, spawnFailed: true }]) {
    assert.equal(acceptedNextExit(value, "SIGTERM"), false);
  }
  assert.equal(acceptedNextExit({ code: null, signal: "SIGTERM" }, null), false);
  assert.equal(acceptedNextExit({ code: null, signal: "SIGTERM" }, undefined), false);
  assert.equal(acceptedNextExit({ code: 0, signal: null }, "unknown"), false);
  assert.equal(acceptedNextExit({ code: 143, signal: null }, null), false);
  assert.equal(acceptedNextExit({ code: 143, signal: null }, undefined), false);
  assert.equal(acceptedNextExit({ code: 143, signal: null }, "SIGINT"), false);
  assert.equal(acceptedNextExit({ code: 143, signal: "SIGTERM" }, "SIGTERM"), false);
  assert.deepEqual(listenerEvidence("p3007\nf18\nf22\n", 3007), { owned: true, valid: true, fields: ["p3007", "f18", "f22"] });
  assert.equal(listenerEvidence("p3007\nf18\np4000\nf20\n", 3007).owned, false);
  assert.equal(listenerEvidence("p4000\nf18\n", 3007).owned, false);
  assert.equal(listenerEvidence("p3007\nf18u\n", 3007).owned, false);
  assert.equal(listenerEvidence("", 3007).owned, false);
  assert.deepEqual(listenerEvidence("p3007\nprivate path\n", 3007).fields, ["p3007", "[unrecognized-field]"]);
  const startup = startupOutput();
  startup.push("stderr", Buffer.from("Authorization: Bearer synthetic-partial"));
  startup.push("stderr", Buffer.from("-value\nFailed to handle request for http://127.0.0.1:13144/notebooks?private=synthetic\n"));
  startup.push("stdout", Buffer.from("Ready in 500ms\n"));
  startup.push("stderr", Buffer.from("x".repeat(5000) + "\n"));
  const captured = startup.finish();
  assert.deepEqual(captured.lines, [{ stream: "stderr", text: "[redacted-sensitive-startup-line]" },
    { stream: "stderr", text: "Failed to handle request for http://127.0.0.1:13144/notebooks" }, { stream: "stdout", text: "Ready in 500ms" }]);
  assert.equal(captured.dropped, 1); startup.push("stderr", Buffer.from("after-ready-session\n")); assert.deepEqual(startup.finish(), captured);
  const capped = startupOutput(); capped.push("stdout", Buffer.from("Ready\n".repeat(60))); assert.equal(capped.finish().lines.length, 48); assert.equal(capped.finish().dropped, 12);
  for (const input of ["cookie=value", "access_token=value", "user@example.invalid", "https://untrusted.invalid/path?private=value"]) {
    assert.equal(safeStartupLine(input).includes(input), false);
  }
  console.log("Fixture pure checks passed: prior Auth/bytes/network guards; exit0 and explicitly requested pinned-Next SIGTERM/143; unrequested/unknown exits denied; strict listener owner parser; bounded redacted pre-readiness output with split-line, query, oversized, line-cap and post-ready protections. No listener/Next/bundler/browser started.");
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv[2] === "--self-test") await selfTest();
  else if (process.argv[2] === "--serve") await serve();
  else if (process.argv[2] === "--verify-evidence") await verifyEvidence();
  else throw new Error("Use explicit --serve, --verify-evidence or pure --self-test");
}
