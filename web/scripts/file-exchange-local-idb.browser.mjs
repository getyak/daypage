// Real Chromium IndexedDB acceptance source. NOT part of the lightweight Node
// gate and NOT a memory fake. Run only in an approved browser/resource window.
// It compiles source modules in memory, opens an isolated browser context, and
// serves only synthetic fixture/modules on an ephemeral loopback port.
import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { createRequire } from "node:module";
import { readFile, readdir, mkdtemp, mkdir, rm, writeFile, statfs, access } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { isAbsolute, basename, join } from "node:path";
import { tmpdir, homedir } from "node:os";
import { createHash } from "node:crypto";

if (process.env.GET443_BROWSER_RUN !== "1") throw Error("Real browser gate is deferred; run explicitly with GET443_BROWSER_RUN=1 after resource checks.");
const toolchainPackage = process.env.GET443_TOOLCHAIN_PACKAGE ?? fileURLToPath(new URL("../package.json", import.meta.url));
if (!isAbsolute(toolchainPackage) || basename(toolchainPackage) !== "package.json") throw Error("GET443_TOOLCHAIN_PACKAGE must be an absolute package.json path");
const require = createRequire(toolchainPackage);
const { chromium } = require("@playwright/test"), ts = require("typescript");
const channel = process.env.GET443_BROWSER_CHANNEL;
if (channel && !["chrome", "chromium"].includes(channel)) throw Error("GET443_BROWSER_CHANNEL must be chrome or chromium");
const artifactRoot = process.env.GET443_ARTIFACT_DIR ?? await mkdtemp(join(tmpdir(), "daypage-local-idb-artifacts-"));
if (!isAbsolute(artifactRoot)) throw Error("GET443_ARTIFACT_DIR must be absolute");
await mkdir(artifactRoot, { recursive: true });
const web = new URL("../", import.meta.url), assets = new Map(), sourceModules = [];
for (const directory of ["file-exchange", "file-exchange-local"]) {
  const folder = new URL(`src/lib/${directory}/`, web);
  for (const name of await readdir(folder)) {
    if (name.endsWith(".ts")) {
      const source = await readFile(new URL(name, folder), "utf8");
      sourceModules.push({ path: `web/src/lib/${directory}/${name}`, sha256: createHash("sha256").update(source).digest("hex") });
      const js = ts.transpileModule(source, { fileName: name,
        compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext } }).outputText
        .replace(/(from\s*["'][^"']+)\.ts(["'])/g, "$1.js$2");
      assets.set(`/${directory}/${name.slice(0, -3)}.js`, ["text/javascript", js]);
    } else if (name === "schema.json") {
      const bytes = await readFile(new URL(name, folder)); assets.set(`/${directory}/${name}`, ["application/json", bytes]);
      sourceModules.push({ path: `web/src/lib/${directory}/${name}`, sha256: createHash("sha256").update(bytes).digest("hex") });
    }
  }
}
assets.set("/", ["text/html", "<!doctype html><title>Synthetic local IndexedDB check</title>"]);
assets.set("/favicon.ico", ["image/x-icon", Buffer.alloc(0)]);
// Catch fixture-server packaging failures before launching a browser.
for (const [path, [mime, source]] of assets) if (mime === "text/javascript") {
  for (const dependency of ts.preProcessFile(source, true, true).importedFiles) {
    const resolved = new URL(dependency.fileName, "http://fixture.invalid" + path);
    assert.equal(resolved.origin, "http://fixture.invalid", "Harness modules cannot import external code");
    assert.ok(assets.has(resolved.pathname), "Harness dependency must be served: " + resolved.pathname);
  }
}
const fixtureRoot = new URL("tests/fixtures/file-exchange-v1/", web);
const manifestBytes = await readFile(new URL("daypage-exchange.json", fixtureRoot));
const manifest = JSON.parse(manifestBytes), fixture = [["daypage-exchange.json", [...manifestBytes]]];
for (const file of manifest.files) {
  const source = new URL(file.path, fixtureRoot);
  assert.ok(fileURLToPath(source).startsWith(fileURLToPath(fixtureRoot)), "Fixture cannot escape its root");
  fixture.push([file.path, [...await readFile(source)]]);
}
const reviewRoot = new URL("tests/fixtures/file-exchange-reviews-v1/manual-review-nested-citations/", web);
const reviewManifestBytes = await readFile(new URL("daypage-exchange.json", reviewRoot)), reviewManifest = JSON.parse(reviewManifestBytes);
const reviewFixture = [["daypage-exchange.json", [...reviewManifestBytes]]];
for (const file of reviewManifest.files) {
  const source = new URL(file.path, reviewRoot); assert.ok(fileURLToPath(source).startsWith(fileURLToPath(reviewRoot)));
  reviewFixture.push([file.path, [...await readFile(source)]]);
}
const reviewRecords = JSON.parse(await readFile(new URL("records.json", reviewRoot), "utf8"));
async function bootstrap(page, exportID, selectedFixture = fixture) {
  await page.evaluate(async ({ fixture, exportID }) => {
    const { BrowserNotebookStore } = await import("/file-exchange-local/store.js");
    const { OwnerEpoch } = await import("/file-exchange-local/epoch.js");
    const { makeOwner } = await import("/file-exchange-local/model.js");
    const { previewExchange } = await import("/file-exchange/preview.js");
    const bytes = new Map(fixture.map(([path, values]) => [path, new Uint8Array(values)]));
    if (exportID) {
      const manifest = JSON.parse(new TextDecoder().decode(bytes.get("daypage-exchange.json")));
      manifest.export_id = exportID; bytes.set("daypage-exchange.json", new TextEncoder().encode(JSON.stringify(manifest)));
    }
    const preview = await previewExchange([...bytes].map(([path, value]) => ({ path, size: value.length, read: async () => value })));
    const epoch = new OwnerEpoch(); epoch.authorize(makeOwner("https://synthetic.supabase.co", "22222222-2222-4222-8222-222222222222"));
    window.localCase = { store: new BrowserNotebookStore(), epoch, preview, makeOwner, OwnerEpoch };
  }, { fixture: selectedFixture, exportID });
}
async function snapshot(page) {
  return page.evaluate(async () => {
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open("daypage-file-exchange-local-v1", 1); request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
    });
    const tx = db.transaction(["jobs", "files", "items", "receipts"], "readonly");
    const rows = await Promise.all(["jobs", "files", "items", "receipts"].map(name => new Promise((resolve, reject) => {
      const request = tx.objectStore(name).getAll(); request.onsuccess = () => resolve([name, request.result]); request.onerror = () => reject(request.error);
    })));
    db.close(); return Object.fromEntries(rows.map(([key, values]) => [key, values.map(value => ({ namespace: value.namespace, exportID: value.exportID, status: value.status, path: value.path }))]));
  });
}
function processExists(pid) {
  try { process.kill(pid, 0); return true; } catch (error) { if (error.code === "ESRCH") return false; throw error; }
}
async function waitForOwnedBrowserExit(pid) {
  const deadline = Date.now() + 10_000;
  while (processExists(pid) && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 50));
  assert.equal(processExists(pid), false, "The owned browser process must exit before reopening its profile");
}
const sha256 = bytes => createHash("sha256").update(bytes).digest("hex");
test("native IDB atomic publication, reopen, real quota, cross-tab replay/discard and owner abort", async () => {
  const assetRequests = [];
  const server = createServer((request, response) => {
    const asset = assets.get(request.url);
    assetRequests.push({ path: new URL(request.url, "http://fixture.invalid").pathname, status: asset ? request.url === "/favicon.ico" ? 204 : 200 : 404 });
    if (!asset) { response.writeHead(404); response.end(); return; }
    if (request.url === "/favicon.ico") { response.writeHead(204); response.end(); return; }
    // JSON module imports use connect-src in Chromium. Admit only this fixture
    // origin; the route below still rejects every non-static/query/write request.
    response.writeHead(200, { "Content-Type": asset[0], "Cache-Control": "no-store", "Content-Security-Policy": "default-src 'self'; connect-src 'self'" }); response.end(asset[1]);
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const runDir = await mkdtemp(join(artifactRoot, "idb-run-")), profile = await mkdtemp(join(runDir, "browser-profile-"));
  const evidence = { flow: "Synthetic native-IDB adapter only; no Next app, product UI, auth or provider validation",
    browserRouting: "Browser plugin not available; regular Playwright explicitly authorized", toolchain: { package: toolchainPackage,
      playwright: require("@playwright/test/package.json").version, typescript: ts.version, channel: channel ?? "default" },
    harnessSHA256: sha256(await readFile(fileURLToPath(import.meta.url))),
    origin, profile, sourceModules, browserProcesses: [], stages: {}, outcome: "running", cleanup: {} };
  const escaped = [], pageErrors = [], consoleErrors = [], requestFailures = []; let context, browserPID, launchIncomplete = false;
  let mainFailed = false;
  async function launchOwnedBrowser(phase) {
    launchIncomplete = true;
    const disk = await statfs(profile), freeBytes = disk.bavail * disk.bsize;
    if (process.platform === "darwin") {
      let paused = false;
      try { await access(join(homedir(), ".agent-pause")); paused = true; } catch (error) { if (error.code !== "ENOENT") throw error; }
      assert.equal(paused, false, "No new owned browser starts under the host pause");
      assert.ok(freeBytes >= 10 * 1024 ** 3, "The Mac host requires10GiB before each browser launch");
    }
    evidence.stages[phase + "Resources"] = { freeBytes };
    const current = await chromium.launchPersistentContext(profile, { headless: true, ...(channel ? { channel } : {}) });
    context = current;
    await current.route("**/*", route => {
      const request = route.request(), url = new URL(request.url()), owned = url.origin === origin;
      if (owned && ["GET", "HEAD"].includes(request.method()) && !url.search && assets.has(url.pathname)) return route.continue();
      escaped.push({ ownedOrigin: owned, method: request.method(), path: url.pathname, hasQuery: Boolean(url.search) }); return route.abort();
    });
    const observe = page => {
      page.on("pageerror", error => pageErrors.push({ phase, name: error.name }));
      page.on("console", message => { if (message.type() === "error") consoleErrors.push({ phase, message: message.text().slice(0, 500) }); });
      page.on("requestfailed", request => requestFailures.push({ phase, path: new URL(request.url()).pathname, reason: request.failure()?.errorText }));
    };
    current.on("page", observe); for (const page of current.pages()) observe(page);
    const browser = current.browser(); assert.ok(browser, "Persistent context must expose its owned browser");
    const cdp = await browser.newBrowserCDPSession(), info = await cdp.send("SystemInfo.getProcessInfo");
    const pid = info.processInfo.find(item => item.type === "browser")?.id;
    assert.ok(Number.isSafeInteger(pid) && pid > 0, "CDP must identify the owned OS browser process");
    browserPID = pid; await cdp.detach(); evidence.browserProcesses.push({ phase, pid, version: browser.version(), exited: false }); launchIncomplete = false;
    return current;
  }
  async function closeOwnedBrowser() {
    if (!context) return;
    await context.close(); context = undefined;
    await waitForOwnedBrowserExit(browserPID);
    evidence.browserProcesses.at(-1).exited = true;
  }
  try {
    await launchOwnedBrowser("initial");
    const first = context.pages()[0] ?? await context.newPage(); await first.goto(origin);
    evidence.stages.pageIdentity = { url: first.url(), title: await first.title() };
    assert.equal(first.url(), origin + "/"); assert.equal(await first.title(), "Synthetic local IndexedDB check");
    const controlExport = "99999999-9999-4999-8999-999999999999";
    await bootstrap(first, controlExport);
    const controlReceipt = await first.evaluate(async () => {
      const { store, epoch, preview } = window.localCase, lease = epoch.lease();
      try { const before = await store.list(lease); if (before.length) throw Error("Preview must not create a job"); return await store.import(preview, lease); }
      finally { lease.close(); }
    });
    await bootstrap(first);
    const pending = await first.evaluate(async () => {
      const { store, epoch, preview } = window.localCase; const lease = epoch.lease();
      const before = await store.list(lease);
      let error;
      try { await store.import(preview, lease, { progress(done) { if (done === 1) lease.cancel(); } }); }
      catch (e) { error = e.name; } finally { lease.close(); }
      const read = epoch.lease(); try { return { before, error, jobs: await store.list(read) }; } finally { read.close(); }
    });
    assert.equal(pending.before.length, 1); assert.equal(pending.before[0].namespace, controlReceipt.namespace); assert.equal(pending.error, "AbortError");
    const pendingJob = pending.jobs.find(job => job.status === "pending"); assert.ok(pendingJob);
    assert.equal(pending.jobs.length, 2); assert.equal(pendingJob.savedFiles, 1);
    const before = await snapshot(first); assert.equal(before.receipts.length, 1);
    assert.equal(before.items.length, manifest.notes_count + manifest.reviews_count);
    assert.equal(before.files.length, manifest.files.length + 2);
    assert.ok(before.receipts.every(row => row.namespace === controlReceipt.namespace));
    assert.ok(before.items.every(row => row.namespace === controlReceipt.namespace));
    evidence.stages.pending = before;

    // Chromium's real storage quota, not a mocked transaction or fake IDB.
    const cdp = await context.newCDPSession(first);
    let quotaCheckError;
    try {
      const metadata = { before: await cdp.send("Storage.getUsageAndQuota", { origin }) };
      evidence.stages.quotaMetadata = metadata;
      await cdp.send("Storage.overrideQuotaForOrigin", { origin, quotaSize: 1 });
      metadata.overridden = await cdp.send("Storage.getUsageAndQuota", { origin });
      assert.equal(metadata.overridden.quota, 1); assert.equal(metadata.overridden.overrideActive, true);
      // Exact Chrome156 source: BucketContext caches an allowance decaying over
      //30s (.h kBucketSpaceCacheTimeLimit; .cc CheckCanUseDiskSpace). CDP
      // override does not invalidate that cache. Wait for expiry without writes.
      console.log("Quota override is active; awaiting the documented30s IDB allowance cache expiry.");
      const since = Date.now(); await new Promise(resolve => setTimeout(resolve, 31_000)); metadata.cacheWaitMs = Date.now() - since;
      metadata.afterCacheExpiry = await cdp.send("Storage.getUsageAndQuota", { origin });
      assert.equal(metadata.afterCacheExpiry.quota, 1); assert.equal(metadata.afterCacheExpiry.overrideActive, true);
      const quota = await first.evaluate(async () => {
        const { store, epoch, preview } = window.localCase, lease = epoch.lease();
        try { await store.import(preview, lease); return "unexpected-success"; } catch (e) { return e.name; } finally { lease.close(); }
      });
      const after = await snapshot(first);
      evidence.stages.quotaRefusal = { error: quota, snapshotUnchanged: JSON.stringify(after) === JSON.stringify(before), snapshot: after };
      assert.equal(quota, "QuotaExceededError"); assert.deepEqual(after, before);
    } catch (error) {
      quotaCheckError = error; evidence.stages.quotaAssertion = "fail; other independent adapter checks continue, then the test still fails";
    } finally { await cdp.send("Storage.overrideQuotaForOrigin", { origin }); }
    const receipt = await first.evaluate(async () => {
      const { store, epoch, preview } = window.localCase, lease = epoch.lease();
      try { return await store.import(preview, lease); } finally { lease.close(); }
    });
    assert.equal(receipt.namespace, pendingJob.namespace);
    const second = await context.newPage(); await second.goto(origin); await bootstrap(second);
    const restored = await second.evaluate(async namespace => {
      const { store, epoch } = window.localCase, lease = epoch.lease();
      try { const value = await store.load(namespace, lease); return { notes: value.preview.records.notes.length, reviews: value.preview.records.reviews.length, manifest: [...value.preview.manifestBytes] }; } finally { lease.close(); }
    }, receipt.namespace);
    assert.equal(restored.notes, manifest.notes_count); assert.equal(restored.reviews, manifest.reviews_count); assert.deepEqual(restored.manifest, [...manifestBytes]);
    const conflict = await second.evaluate(async () => {
      const { store, epoch, preview } = window.localCase, lease = epoch.lease();
      const value = JSON.parse(new TextDecoder().decode(preview.manifestBytes));
      value.created_at = value.created_at === "2026-11-06T00:00:00Z" ? "2026-11-05T00:00:00Z" : "2026-11-06T00:00:00Z";
      preview.manifestBytes = new TextEncoder().encode(JSON.stringify(value));
      try { await store.import(preview, lease); return "unexpected-success"; } catch (e) { return e.message; } finally { lease.close(); }
    });
    assert.equal(conflict, "source-conflict"); assert.equal((await snapshot(first)).receipts.length, 2);

    const nextExport = "44444444-4444-4444-8444-444444444444";
    await Promise.all([bootstrap(first, nextExport), bootstrap(second, nextExport)]);
    const concurrent = await Promise.all([first, second].map(page => page.evaluate(async () => {
      const { store, epoch, preview } = window.localCase, lease = epoch.lease();
      try { return await store.import(preview, lease); } finally { lease.close(); }
    })));
    assert.equal(concurrent[0].namespace, concurrent[1].namespace); assert.equal((await snapshot(first)).receipts.length, 3);
    const isolated = await first.evaluate(async namespace => {
      const { store, epoch, makeOwner } = window.localCase;
      epoch.authorize(makeOwner("https://synthetic.supabase.co", "33333333-3333-4333-8333-333333333333"));
      const lease = epoch.lease();
      try { const jobs = await store.list(lease); let rejected = false; try { await store.load(namespace, lease); } catch { rejected = true; } return { jobs, rejected }; } finally { lease.close(); }
    }, receipt.namespace);
    assert.deepEqual(isolated, { jobs: [], rejected: true });

    await bootstrap(first, "55555555-5555-4555-8555-555555555555");
    const toDiscard = await first.evaluate(async () => {
      const { store, epoch, preview } = window.localCase, lease = epoch.lease();
      try { await store.import(preview, lease, { progress() { lease.cancel(); } }); } catch {} finally { lease.close(); }
      const read = epoch.lease(); try { return (await store.list(read)).find(job => job.status === "pending").namespace; } finally { read.close(); }
    });
    await second.evaluate(async namespace => {
      const { store, epoch } = window.localCase, lease = epoch.lease(); try { await store.discardPending(namespace, lease); } finally { lease.close(); }
    }, toDiscard);
    const refused = await first.evaluate(async expectedNamespace => {
      const { store, epoch, preview } = window.localCase, lease = epoch.lease();
      try { await store.import(preview, lease, { expectedNamespace }); return false; } catch { return true; } finally { lease.close(); }
    }, toDiscard);
    assert.equal(refused, true); const final = await snapshot(first); assert.equal(final.jobs.length, 3); assert.equal(final.receipts.length, 3);
    assert.ok(final.files.every(file => file.namespace !== toDiscard));
    const actualAbort = await first.evaluate(async () => {
      const { epoch } = window.localCase, lease = epoch.lease();
      const db = await new Promise((resolve, reject) => {
        const request = indexedDB.open("daypage-file-exchange-local-v1", 1); request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
      });
      const original = await new Promise(resolve => {
        const request = db.transaction("jobs").objectStore("jobs").getAll(); request.onsuccess = () => resolve(request.result[0]);
      });
      const namespace = "66666666-6666-4666-8666-666666666666", tx = db.transaction("jobs", "readwrite");
      const release = lease.track(tx), outcome = new Promise(resolve => { tx.onabort = () => resolve("aborted"); tx.oncomplete = () => resolve("committed"); });
      tx.objectStore("jobs").add({ ...original, namespace, exportID: "77777777-7777-4777-8777-777777777777" });
      epoch.revoke(); const status = await outcome; release(); lease.close();
      const row = await new Promise(resolve => {
        const request = db.transaction("jobs").objectStore("jobs").get([original.realm, original.uid, namespace]); request.onsuccess = () => resolve(request.result);
      });
      db.close(); return { status, signalAborted: lease.signal.aborted, rowAbsent: row === undefined };
    });
    assert.deepEqual(actualAbort, { status: "aborted", signalAborted: true, rowAbsent: true });
    const reviewExport = "88888888-8888-4888-8888-888888888888";
    await bootstrap(first, reviewExport, reviewFixture);
    const reviewReceipt = await first.evaluate(async () => {
      const { store, epoch, preview } = window.localCase, lease = epoch.lease();
      try { return await store.import(preview, lease); } finally { lease.close(); store.close(); }
    });
    const beforeRestart = await snapshot(first); evidence.stages.beforeProcessRestart = beforeRestart;
    const firstPID = browserPID; await closeOwnedBrowser();
    await launchOwnedBrowser("restarted-same-profile"); assert.notEqual(browserPID, firstPID);
    const reopened = context.pages()[0] ?? await context.newPage(); await reopened.goto(origin); await bootstrap(reopened);
    const namespaces = [controlReceipt.namespace, receipt.namespace, concurrent[0].namespace, reviewReceipt.namespace];
    const recovered = await reopened.evaluate(async namespaces => {
      const { store, epoch } = window.localCase, result = [];
      for (const namespace of namespaces) {
        const lease = epoch.lease();
        try {
          const value = await store.load(namespace, lease);
          result.push({ namespace, receipt: value.receipt, notes: value.preview.records.notes, reviews: value.preview.records.reviews,
            originals: [["daypage-exchange.json", [...value.preview.manifestBytes]], ...[...value.preview.files].map(([path, bytes]) => [path, [...bytes]])] });
        } finally { lease.close(); }
      }
      return result;
    }, namespaces);
    const baseRecords = JSON.parse(await readFile(new URL("records.json", fixtureRoot), "utf8"));
    const changedManifest = (source, exportID) => [...Buffer.from(JSON.stringify({ ...source, export_id: exportID }))];
    const expectedFiles = (files, manifest) => files.map(([path, bytes]) => [path, path === "daypage-exchange.json" ? manifest : bytes]);
    const expected = [
      { receipt: controlReceipt, records: baseRecords, files: expectedFiles(fixture, changedManifest(manifest, controlExport)) },
      { receipt, records: baseRecords, files: fixture },
      { receipt: concurrent[0], records: baseRecords, files: expectedFiles(fixture, changedManifest(manifest, nextExport)) },
      { receipt: reviewReceipt, records: reviewRecords, files: expectedFiles(reviewFixture, changedManifest(reviewManifest, reviewExport)) },
    ];
    const restartProof = [];
    for (let i = 0; i < expected.length; i++) {
      const actual = recovered[i], source = expected[i]; assert.equal(actual.namespace, source.receipt.namespace);
      assert.deepEqual(actual.receipt, source.receipt); assert.deepEqual(actual.notes, source.records.notes); assert.deepEqual(actual.reviews, source.records.reviews);
      const files = new Map(actual.originals); assert.equal(files.size, source.files.length);
      for (const [path, bytes] of source.files) assert.deepEqual(files.get(path), bytes, "Exact original bytes must survive browser process restart");
      restartProof.push({ namespace: actual.namespace, notes: actual.notes.length, reviews: actual.reviews.length,
        originals: [...files].map(([path, bytes]) => ({ path, bytes: bytes.length, sha256: sha256(Buffer.from(bytes)) })) });
    }
    assert.ok(restartProof.some(row => row.reviews > 0)); assert.deepEqual(await snapshot(reopened), beforeRestart);
    assert.deepEqual(escaped, []); assert.deepEqual(pageErrors, []); assert.deepEqual(consoleErrors, []); assert.deepEqual(requestFailures, []);
    evidence.stages.processRestartReadback = restartProof;
    if (quotaCheckError) throw quotaCheckError;
    evidence.outcome = "pass";
  } catch (error) { mainFailed = true; evidence.outcome = "fail"; evidence.failure = { name: error.name, code: error.code ?? null }; throw error;
  } finally {
    const cleanupFailures = [];
    try { await closeOwnedBrowser(); evidence.cleanup.browser = "closed-and-exit-verified"; }
    catch (error) { evidence.cleanup.browser = "close-or-exit-not-verified"; cleanupFailures.push({ phase: "browser", error }); }
    try { await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve())); evidence.cleanup.server = "closed"; }
    catch (error) { evidence.cleanup.server = "close-not-verified"; cleanupFailures.push({ phase: "server", error }); }
    if (!launchIncomplete && evidence.browserProcesses.length > 0 && evidence.browserProcesses.every(row => row.exited)) {
      try { await rm(profile, { recursive: true }); evidence.cleanup.profile = "removed-owned-profile"; }
      catch (error) { evidence.cleanup.profile = "remove-not-verified"; cleanupFailures.push({ phase: "profile", error }); }
    } else { evidence.cleanup.profile = "retained-unverified-browser-exit"; cleanupFailures.push({ phase: "profile", error: new Error("Owned browser exit was not verified") }); }
    evidence.pageErrors = pageErrors; evidence.consoleErrors = consoleErrors; evidence.requestFailures = requestFailures;
    evidence.assetRequests = assetRequests; evidence.blockedUnexpectedRequests = escaped; evidence.nonLoopbackRequests = escaped.filter(row => !row.ownedOrigin).length;
    if (cleanupFailures.length) {
      evidence.outcome = "fail";
      evidence.cleanupFailures = cleanupFailures.map(({ phase, error }) => ({ phase, name: error.name, code: error.code ?? null }));
      if (!mainFailed) evidence.failure = { phase: "cleanup", ...evidence.cleanupFailures[0] };
    }
    try { await writeFile(join(runDir, "evidence.json"), JSON.stringify(evidence, null, 2) + "\n"); console.log("IDB adapter evidence:", join(runDir, "evidence.json")); }
    catch (error) { cleanupFailures.push({ phase: "evidence-write", error }); console.error("IDB evidence write failed:", error.name); }
    // Never turn an unverified cleanup into green, and never replace an earlier
    // test failure with a secondary cleanup/write error.
    if (!mainFailed && cleanupFailures.length) throw cleanupFailures[0].error;
  }
});
