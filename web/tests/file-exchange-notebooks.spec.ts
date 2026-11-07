import { test, expect, chromium } from "@playwright/test";
import type { BrowserContext, Page, Request as BrowserRequest, TestInfo } from "@playwright/test";
import { createHash, randomUUID } from "node:crypto";
import { readFile, writeFile, mkdir, mkdtemp, rm, access } from "node:fs/promises";
import { readFileSync } from "node:fs";
import path from "node:path";

const ORIGIN = "http://127.0.0.1:13143", AUTH = "/__get443_supabase", CONTROL = "/__get443_control";
const OWNER_A = "aaaaaaaa-0000-4000-8000-000000000001", OWNER_B = "bbbbbbbb-0000-4000-8000-000000000002";
const hash = (bytes: Uint8Array | string) => createHash("sha256").update(bytes).digest("hex");
const artifact = process.env.GET443_NOTEBOOKS_ARTIFACT_DIR;
if (process.env.GET443_NOTEBOOKS_RUN !== "1" || !artifact || !path.isAbsolute(artifact)) throw new Error("Explicit task artifact required");
const ROOT: string = artifact;
type FileProof = { path: string; bytes: number; sha256: string; kind: "screenshot" | "dom" | "readback" | "download" | "ledger" };
type FixtureInfo = { directory: string; exportID: string; notes: number; reviews: number; files: { path: string; bytes: number; sha256: string }[] };
type ServiceInfo = { sourceSHA: string; fixtures: Record<"asset" | "review" | "historical", FixtureInfo> };
type ProcessIdentity = { pid: number; signature: string };
type BrowserExit = { pid: number; verifiedExit: boolean; forced: boolean; profileRemoved: boolean; processCount: number };
type StoredRow = { realm: string; uid: string; namespace: string; exportID?: string; status?: string; path?: string; bytes?: number; sha256?: string; valueSHA256?: string };
type Readback = Record<"jobs" | "files" | "items" | "receipts", StoredRow[]>;

function sanitize(value: string) {
  return value.replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g, "[redacted-token]")
    .replace(/(?:authorization|cookie|refresh_token|access_token)\s*[:=].*/gi, "[redacted-auth-field]").slice(0, 1600);
}
function processIdentity(pid: number): string | null {
  // Hosted Linux only: kernel start ticks avoid matching a recycled PID. PIDs
  // enter this list solely through the CDP connection to our owned profile.
  if (process.platform !== "linux") throw new Error("This isolated UI runner requires Linux process identity evidence");
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    const fields = stat.slice(stat.lastIndexOf(")") + 2).trim().split(/\s+/);
    if (!/^\d+$/.test(fields[19] ?? "")) throw new Error("Invalid owned process identity");
    return fields[19];
  } catch (error) {
    if (["ENOENT", "ESRCH"].includes((error as NodeJS.ErrnoException).code ?? "")) return null;
    throw error;
  }
}
async function jsonControl<T>(context: BrowserContext, suffix: string, value?: unknown): Promise<T> {
  const response = value === undefined ? await context.request.get(ORIGIN + CONTROL + suffix) : await context.request.post(ORIGIN + CONTROL + suffix, { data: value });
  expect(response.ok(), "Synthetic control must work without a product/auth bypass").toBe(true);
  return await response.json() as T;
}
async function mode(context: BrowserContext, value: { hold?: "A" | "B" | null; deny?: "A" | "B" | null; release?: boolean }) {
  return jsonControl<{ held: number; released: number }>(context, "/mode", value);
}
async function readFixture(info: FixtureInfo): Promise<Map<string, Buffer>> {
  const files = new Map<string, Buffer>();
  for (const file of info.files) {
    const target = path.resolve(info.directory, file.path);
    expect(target.startsWith(info.directory + path.sep)).toBe(true);
    const bytes = await readFile(target); expect(bytes.length).toBe(file.bytes); expect(hash(bytes)).toBe(file.sha256); files.set(file.path, bytes);
  }
  return files;
}

// Independent bounded STORE-ZIP reader: does not import the production writer.
function readOriginalZip(bytes: Buffer): Map<string, Buffer> {
  expect(bytes.length).toBeLessThan(2 * 1024 * 1024); expect(bytes.length).toBeGreaterThanOrEqual(22);
  const end = bytes.length - 22; expect(bytes.readUInt32LE(end)).toBe(0x06054b50);
  expect(bytes.readUInt32LE(end + 4)).toBe(0); expect(bytes.readUInt16LE(end + 20)).toBe(0);
  const count = bytes.readUInt16LE(end + 8); expect(count).toBe(bytes.readUInt16LE(end + 10)); expect(count).toBeGreaterThan(0); expect(count).toBeLessThan(20);
  let central = bytes.readUInt32LE(end + 16), localEnd = 0;
  expect(central + bytes.readUInt32LE(end + 12)).toBe(end);
  const result = new Map<string, Buffer>(), text = new TextDecoder("utf-8", { fatal: true });
  function crc32(value: Buffer) {
    let crc = 0xffffffff;
    for (const byte of value) { crc ^= byte; for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0); }
    return (crc ^ 0xffffffff) >>> 0;
  }
  for (let n = 0; n < count; n++) {
    expect(central + 46).toBeLessThanOrEqual(end); expect(bytes.readUInt32LE(central)).toBe(0x02014b50);
    expect(bytes.readUInt16LE(central + 8)).toBe(0x0800); expect(bytes.readUInt16LE(central + 10)).toBe(0);
    const size = bytes.readUInt32LE(central + 20), nameLength = bytes.readUInt16LE(central + 28);
    expect(size).toBe(bytes.readUInt32LE(central + 24)); expect(size).toBeLessThan(1024 * 1024);
    expect(nameLength).toBeGreaterThan(0); expect(nameLength).toBeLessThanOrEqual(512);
    expect(bytes.readUInt32LE(central + 30)).toBe(0); expect(central + 46 + nameLength).toBeLessThanOrEqual(end);
    const nameBytes = bytes.subarray(central + 46, central + 46 + nameLength), name = text.decode(nameBytes);
    expect(name.split("/").every(piece => piece && piece !== "." && piece !== "..")).toBe(true); expect(result.has(name)).toBe(false);
    const local = bytes.readUInt32LE(central + 42); expect(local).toBe(localEnd); expect(bytes.readUInt32LE(local)).toBe(0x04034b50);
    expect(bytes.readUInt16LE(local + 6)).toBe(0x0800); expect(bytes.readUInt16LE(local + 8)).toBe(0);
    expect(bytes.readUInt16LE(local + 26)).toBe(nameLength); expect(bytes.readUInt16LE(local + 28)).toBe(0);
    expect(bytes.subarray(local + 30, local + 30 + nameLength).equals(nameBytes)).toBe(true);
    const value = bytes.subarray(local + 30 + nameLength, local + 30 + nameLength + size);
    expect(value.length).toBe(size); expect(bytes.readUInt32LE(local + 18)).toBe(size); expect(bytes.readUInt32LE(local + 22)).toBe(size);
    expect(crc32(value)).toBe(bytes.readUInt32LE(local + 14)); expect(crc32(value)).toBe(bytes.readUInt32LE(central + 16));
    result.set(name, Buffer.from(value)); localEnd = local + 30 + nameLength + size; central += 46 + nameLength;
  }
  expect(central).toBe(end); expect(localEnd).toBe(bytes.readUInt32LE(end + 16)); return result;
}

async function stored(page: Page): Promise<Readback> {
  return page.evaluate(async () => {
    const names = ["jobs", "files", "items", "receipts"] as const;
    const all = await indexedDB.databases();
    if (!all.some(value => value.name === "daypage-file-exchange-local-v1")) return { jobs: [], files: [], items: [], receipts: [] };
    const db = await new Promise<IDBDatabase>((resolve, reject) => {
      const request = indexedDB.open("daypage-file-exchange-local-v1");
      request.onupgradeneeded = () => { request.transaction?.abort(); reject(new Error("Readback must not create storage")); };
      request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
    });
    try {
      const tx = db.transaction([...names], "readonly");
      const values = await Promise.all(names.map(name => new Promise<unknown[]>((resolve, reject) => {
        const request = tx.objectStore(name).getAll(); request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
      })));
      const digest = async (bytes: Uint8Array) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", Uint8Array.from(bytes).buffer)), b => b.toString(16).padStart(2, "0")).join("");
      const output: Record<string, object[]> = {};
      for (let index = 0; index < names.length; index++) {
        output[names[index]] = await Promise.all(values[index].map(async item => {
          const row = item as { realm: string; uid: string; namespace: string; exportID?: string; status?: string; path?: string; blob?: Blob; value?: unknown };
          return { realm: row.realm, uid: row.uid, namespace: row.namespace, exportID: row.exportID, status: row.status, path: row.path,
            ...(row.blob ? { bytes: row.blob.size, sha256: await digest(new Uint8Array(await row.blob.arrayBuffer())) } : {}),
            ...(row.value ? { valueSHA256: await digest(new TextEncoder().encode(JSON.stringify(row.value))) } : {}) };
        }));
        output[names[index]].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
      }
      return output as Readback;
    } finally { db.close(); }
  });
}

class Boundary {
  rows: { method: string; path: string; outcome: string }[] = [];
  errors: string[] = [];
  events = new Map<Page, string[]>();
  userRequests = new Set<BrowserRequest>();
  expectedAuthError = false;
  closing = false;
  gate: { page: Page; release: () => void; wait: Promise<void>; count: number } | null = null;
  constructor(private context: BrowserContext, private markers: string[]) {}
  async arm() {
    await this.context.addInitScript(({ a, b }) => {
      // Passive native observations only. No callback invocation, SDK patch,
      // product/global debug handle, DOM mutation or auth/store authority.
      const channel = new BroadcastChannel("sb-127-auth-token");
      channel.addEventListener("message", event => {
        const value = event.data as { event?: string; session?: { user?: { id?: string } } };
        if (["SIGNED_IN", "SIGNED_OUT"].includes(value.event ?? "")) {
          const id = value.session?.user?.id;
          console.debug("GET443_NATIVE_AUTH:" + value.event + ":" + (id === a ? "A" : id === b ? "B" : "none"));
        }
      });
      window.addEventListener("focus", () => console.debug("GET443_PASSIVE:focus"));
      window.addEventListener("blur", () => console.debug("GET443_PASSIVE:blur"));
      document.addEventListener("visibilitychange", () => console.debug("GET443_PASSIVE:visibility:" + document.visibilityState));
      window.addEventListener("pagehide", () => channel.close(), { once: true });
    }, { a: OWNER_A, b: OWNER_B });
    const watch = (page: Page) => {
      this.events.set(page, []);
      page.on("console", message => {
        const value = message.text();
        if (value.startsWith("GET443_")) { this.events.get(page)?.push(value); return; }
        if (message.type() !== "error") return;
        const where = message.location().url;
        if (this.expectedAuthError && where.startsWith(ORIGIN + AUTH + "/auth/v1/user") && value.includes("Failed to load resource")) return;
        this.errors.push(sanitize(value));
      });
      page.on("pageerror", error => this.errors.push(sanitize(error.name + ":" + error.message)));
    };
    this.context.on("page", watch); for (const page of this.context.pages()) watch(page);
    this.context.on("request", request => { if (request.url() === ORIGIN + AUTH + "/auth/v1/user") this.userRequests.add(request); });
    this.context.on("requestfinished", request => this.userRequests.delete(request));
    this.context.on("requestfailed", request => this.userRequests.delete(request));
    await this.context.routeWebSocket("**/*", socket => { this.rows.push({ method: "WS", path: "[websocket]", outcome: "rejected" }); socket.close(); });
    await this.context.route("**/*", async route => {
      const request = route.request(), url = new URL(request.url()), method = request.method();
      if (["blob:", "data:", "about:"].includes(url.protocol)) return route.continue();
      const text = request.url() + "\n" + JSON.stringify(request.headers()) + "\n" + (request.postData() ?? "");
      const leaked = this.markers.some(marker => marker.length >= 8 && text.includes(marker));
      const identity = url.pathname.startsWith(AUTH + "/auth/v1/");
      const allowed = url.origin === ORIGIN && !leaked &&
        ((identity && ["GET", "POST"].includes(method)) || (["GET", "HEAD"].includes(method) && !url.pathname.startsWith("/api/") && !/\/(?:storage|agent|telemetry)\b/i.test(url.pathname)));
      this.rows.push({ method, path: leaked ? "[selected-data]" : url.origin === ORIGIN ? url.pathname : "[off-origin]", outcome: allowed ? "allowed" : "rejected" });
      if (!allowed) return route.abort("blockedbyclient");
      if (this.gate && request.resourceType() === "script" && request.frame().page() === this.gate.page && url.pathname.startsWith("/_next/static/")) {
        this.gate.count++; await this.gate.wait;
      }
      try { await route.continue(); } catch { if (!this.closing) this.errors.push("A guarded request could not continue"); }
    });
    this.context.on("response", response => {
      const url = new URL(response.url());
      if (response.status() >= 400 && !(url.pathname.startsWith(AUTH + "/auth/v1/") && this.expectedAuthError)) this.errors.push("HTTP " + response.status() + " " + url.pathname);
    });
  }
  scriptGate(page: Page) {
    let release!: () => void;
    const wait = new Promise<void>(resolve => { release = resolve; });
    this.gate = { page, release, wait, count: 0 };
  }
  releaseScripts() { this.gate?.release(); this.gate = null; }
  async foreground(page: Page) {
    await page.bringToFront(); await page.waitForFunction(() => document.visibilityState === "visible" && document.hasFocus());
    this.events.set(page, []);
  }
  assertNoFocusFallback(page: Page) {
    expect(this.events.get(page)?.filter(value => value.startsWith("GET443_PASSIVE:")) ?? []).toEqual([]);
  }
}

test("actual Next notebooks: picker, persistence, original bytes and real SDK identity fences", async ({}, info: TestInfo) => {
  const project = info.project.name;
  expect(["desktop", "narrow"]).toContain(project);
  info.annotations.push({ type: "acceptance-boundary", description: "Actual production Next and pinned SDK with synthetic Auth; real Auth and development StrictMode are not executed." });
  const viewport = project === "desktop" ? { width: 1440, height: 900 } : { width: 375, height: 812 };
  const output = path.join(ROOT, "ui", project), profileParent = path.join(ROOT, "profiles");
  await mkdir(output, { recursive: true }); await mkdir(profileParent, { recursive: true });
  const profile = await mkdtemp(path.join(profileParent, project + "-"));
  const files: FileProof[] = [], browserExits: BrowserExit[] = [], boundaries: Boundary[] = [], assertions: Record<string, boolean> = {};
  let context: BrowserContext | undefined, guard: Boundary | undefined, page!: Page, peer!: Page, service: ServiceInfo;
  let processes: ProcessIdentity[] = [], pid = 0, passed = false;
  let serverSnapshot: unknown = null;
  const markers: string[] = [];
  async function proof(name: string, value: unknown) {
    const target = path.join(output, name); const bytes = Buffer.from(JSON.stringify(value, null, 2) + "\n"); await writeFile(target, bytes);
    const file: FileProof = { path: path.relative(ROOT, target), bytes: bytes.length, sha256: hash(bytes), kind: name.includes("network") ? "ledger" : "readback" };
    const existing = files.findIndex(value => value.path === file.path);
    if (existing === -1) files.push(file); else files[existing] = file;
  }
  async function screenshot(label: string) {
    const png = path.join(output, label + ".png"); await page.screenshot({ path: png, fullPage: true });
    const bytes = await readFile(png); files.push({ path: path.relative(ROOT, png), bytes: bytes.length, sha256: hash(bytes), kind: "screenshot" });
    const dom = await page.locator("body").innerText(); expect(/eyJ[\w-]+\.[\w-]+\.[\w-]+/.test(dom)).toBe(false);
    const target = path.join(output, label + ".dom.txt"); await writeFile(target, dom);
    files.push({ path: path.relative(ROOT, target), bytes: Buffer.byteLength(dom), sha256: hash(dom), kind: "dom" });
  }
  async function launch() {
    processes = []; pid = 0;
    context = await chromium.launchPersistentContext(profile, { channel: "chrome", chromiumSandbox: true, headless: true,
      viewport, serviceWorkers: "block", acceptDownloads: true, downloadsPath: path.join(output, "download-temp"),
      args: ["--disable-background-networking"] });
    const browser = context.browser(); expect(browser).not.toBeNull();
    const cdp = await browser!.newBrowserCDPSession();
    const data = await cdp.send("SystemInfo.getProcessInfo") as { processInfo: { id: number; type: string }[] };
    const own = data.processInfo.find(value => value.type === "browser"); expect(own).toBeDefined(); pid = own!.id;
    const command = await cdp.send("Browser.getBrowserCommandLine") as { arguments: string[] };
    expect(command.arguments.some(value => value === "--user-data-dir=" + profile)).toBe(true);
    processes = data.processInfo.map(value => ({ pid: value.id, signature: processIdentity(value.id) ?? "already-exited" }));
    await cdp.detach(); await proof("browser-" + browserExits.length + ".json", { pid, browserVersion: browser!.version(), commandLineHasOwnedProfile: true });
    guard = new Boundary(context, markers); boundaries.push(guard); await guard.arm();
    page = context.pages()[0] ?? await context.newPage(); await page.setViewportSize(viewport);
    peer = await context.newPage(); await peer.setViewportSize(viewport);
  }
  async function closeBrowser() {
    if (!context) return;
    const current = context; context = undefined; guard?.releaseScripts(); if (guard) guard.closing = true;
    const browser = current.browser(), diagnostics: string[] = [];
    try {
      if (browser?.isConnected()) {
        const cdp = await browser.newBrowserCDPSession();
        try {
          const data = await cdp.send("SystemInfo.getProcessInfo") as { processInfo: { id: number }[] };
          for (const value of data.processInfo) { const signature = processIdentity(value.id); if (signature) processes.push({ pid: value.id, signature }); }
        } finally { await cdp.detach(); }
      }
    } catch { diagnostics.push("Could not collect final owned process list"); }
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      await Promise.race([current.close(), new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error("owned-close-timeout")), 10_000); })]);
    } catch { diagnostics.push("Owned browser close failed or timed out"); }
    finally { clearTimeout(timer); }
    const alive = () => processes.filter(value => processIdentity(value.pid) === value.signature);
    let forced = false;
    try { await expect.poll(() => alive().length, { timeout: 10_000 }).toBe(0); }
    catch {
      // Cleanup only PIDs obtained through this task's CDP and whose kernel
      // start identity still matches. A forced cleanup can never pass the gate.
      forced = true;
      for (const value of alive()) {
        if (processIdentity(value.pid) === value.signature) {
          try { process.kill(value.pid, "SIGTERM"); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ESRCH") diagnostics.push("Owned SIGTERM failed"); }
        }
      }
      try { await expect.poll(() => alive().length, { timeout: 5_000 }).toBe(0); }
      catch { diagnostics.push("Owned process remains after SIGTERM"); }
    }
    const verifiedExit = pid > 0 && processes.some(value => value.pid === pid) && alive().length === 0;
    browserExits.push({ pid, verifiedExit, forced, profileRemoved: false, processCount: new Set(processes.map(value => value.pid)).size });
    await proof("browser-exits.json", browserExits);
    await proof("browser-close-diagnostics-" + (browserExits.length - 1) + ".json", { diagnostics, verifiedExit, forced });
    expect(diagnostics).toEqual([]); expect(forced).toBe(false); expect(verifiedExit).toBe(true);
  }
  const section = () => page.locator('section[aria-label="当前账户的本地笔记本"]');
  async function ready() { await expect(section()).toBeVisible(); await expect(page.getByText("正在读取本地列表…", { exact: true })).toBeHidden(); }
  async function peerSubmit(owner: "A" | "B" | "out") {
    // Deliberately submit the sibling's *DOM form* without moving focus off the
    // real page. Its listener calls the public pinned SDK; no auth callback or
    // product model is called by the test. Passive native events prove delivery.
    await peer.locator(owner === "out" ? "#sign-out" : "#sign-in-" + owner).evaluate(form => (form as HTMLFormElement).requestSubmit());
    await expect(peer.locator("#peer-status")).toHaveText(owner === "out" ? "Signed out local session" : "Signed in " + owner);
  }
  async function eventSeen(event: string) { await expect.poll(() => guard!.events.get(page)?.includes(event) ?? false).toBe(true); }
  async function choose(fixture: FixtureInfo) {
    const picker = page.getByLabel("选择交换文件夹", { exact: true }); await expect(picker).toHaveAttribute("webkitdirectory", "");
    const selected = page.waitForEvent("filechooser"); await picker.click(); const chooser = await selected; await chooser.setFiles(fixture.directory);
    await expect(page.getByRole("heading", { name: "导入预览：尚未保存", exact: true })).toBeVisible();
    const actual = await picker.evaluate(input => Array.from((input as HTMLInputElement).files ?? [], file => ({ name: file.name, relative: file.webkitRelativePath })));
    expect(actual).toHaveLength(fixture.files.length); expect(actual.every(file => file.relative.startsWith(path.basename(fixture.directory) + "/"))).toBe(true);
  }
  async function confirm() { await page.getByRole("button", { name: "确认保存到此浏览器", exact: true }).click(); await expect(page.getByRole("heading", { name: "已保存的本地副本", exact: true })).toBeVisible(); }
  async function open(fixture: FixtureInfo) {
    await ready(); const row = page.getByRole("article").filter({ hasText: "导出 " + fixture.exportID }); await expect(row).toHaveCount(1);
    await row.getByRole("button", { name: "打开全文与原文件", exact: true }).click(); await expect(page.getByRole("heading", { name: "已保存的本地副本", exact: true })).toBeVisible();
  }
  async function renderedBody(expected: string) {
    const body = page.getByRole("region", { name: "本地笔记本内容", exact: true }).locator("article > pre").first();
    await expect(body).toBeVisible(); expect(await body.textContent()).toBe(expected);
  }
  async function assertStoredOriginals(fixture: FixtureInfo, snapshot: Readback) {
    const receipt = snapshot.receipts.find(row => row.uid === OWNER_A && row.exportID === fixture.exportID); expect(receipt).toBeDefined();
    const saved = snapshot.files.filter(row => row.uid === OWNER_A && row.namespace === receipt!.namespace);
    expect(saved.map(row => row.path).sort()).toEqual(fixture.files.map(row => row.path).sort());
    for (const expected of fixture.files) { const row = saved.find(value => value.path === expected.path); expect(row?.bytes).toBe(expected.bytes); expect(row?.sha256).toBe(expected.sha256); }
  }
  async function download(name: string, expected: Buffer, label: string) {
    const link = page.getByRole("link", { name: "保存 " + name, exact: true }); await expect(link).toBeVisible();
    const incoming = page.waitForEvent("download"); await link.click(); const item = await incoming; expect(await item.failure()).toBeNull();
    const target = path.join(output, label); await item.saveAs(target); const bytes = await readFile(target);
    expect(bytes.equals(expected)).toBe(true); files.push({ path: path.relative(ROOT, target), bytes: bytes.length, sha256: hash(bytes), kind: "download" });
    await page.getByRole("button", { name: "关闭下载链接", exact: true }).click();
  }
  try {
    await launch(); service = await jsonControl<ServiceInfo>(context!, "/info");
    const sources = Object.fromEntries(await Promise.all(Object.entries(service.fixtures).map(async ([name, value]) => [name, await readFixture(value)]))) as Record<string, Map<string, Buffer>>;
    for (const source of Object.values(sources)) for (const [name, bytes] of source) {
      const text = bytes.toString("utf8"); markers.push(name, hash(bytes), text, encodeURIComponent(text), JSON.stringify(text).slice(1, -1));
      if (name === "records.json") for (const row of [...JSON.parse(text).notes, ...JSON.parse(text).reviews] as { body: string }[]) markers.push(row.body, encodeURIComponent(row.body));
    }
    await mode(context!, { release: true }); await peer.goto(ORIGIN + "/__get443_sdk/peer");
    await expect(peer.locator("#peer-event")).toHaveText("INITIAL_SESSION:none");
    await peer.getByRole("button", { name: "Sign in synthetic A", exact: true }).click(); await expect(peer.locator("#peer-status")).toHaveText("Signed in A");
    await page.goto(ORIGIN + "/notebooks"); await ready();
    await expect(page.getByRole("heading", { name: "本地笔记本", exact: true })).toBeVisible();
    if (project === "narrow") {
      await page.getByRole("button", { name: "Open navigation menu", exact: true }).click();
      await expect(page.getByRole("dialog", { name: "Navigation menu" }).getByRole("link", { name: "本地笔记本", exact: true })).toHaveAttribute("href", "/notebooks");
      await page.getByRole("button", { name: "Close navigation menu", exact: true }).click();
    } else await expect(page.getByRole("navigation", { name: "Main navigation" }).getByRole("link", { name: "本地笔记本", exact: true })).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)).toBe(true);
    const empty = await stored(page); expect(Object.values(empty).every(value => value.length === 0)).toBe(true);
    await choose(service.fixtures.asset); assertions.picker = true;
    expect(await stored(page)).toEqual(empty); assertions.previewNoWrites = true;
    await page.getByRole("button", { name: "取消预览", exact: true }).click(); expect(await stored(page)).toEqual(empty); assertions.cancelNoWrites = true;
    const assetRecords = JSON.parse(sources.asset.get("records.json")!.toString()), reviewRecords = JSON.parse(sources.review.get("records.json")!.toString());
    await choose(service.fixtures.asset); await confirm(); await assertStoredOriginals(service.fixtures.asset, await stored(page));
    await renderedBody(assetRecords.notes[0].body); assertions.confirmedReadback = true;
    await screenshot("confirmed");
    const assetManifest = JSON.parse(sources.asset.get("daypage-exchange.json")!.toString());
    const assetPath = (assetManifest.files as { path: string; kind: string }[]).find(row => row.kind === "asset")!.path;
    const detail = page.getByRole("region", { name: "本地笔记本内容", exact: true });
    await detail.getByRole("button", { name: "在本机预览", exact: true }).first().click();
    await expect(page.getByRole("region", { name: "仅本机的附件预览", exact: true })).toContainText(sources.asset.get(assetPath)!.toString("utf8"));
    await page.getByRole("button", { name: "关闭预览", exact: true }).click();
    await detail.getByRole("button", { name: "下载全部原文件 ZIP", exact: true }).click();
    const zipLink = page.getByRole("link", { name: "保存 daypage-originals-" + service.fixtures.asset.exportID + ".zip", exact: true });
    const zipEvent = page.waitForEvent("download"); await zipLink.click(); const zipDownload = await zipEvent; expect(await zipDownload.failure()).toBeNull();
    const zipPath = path.join(output, "originals.zip"); await zipDownload.saveAs(zipPath); const zip = await readFile(zipPath), unzipped = readOriginalZip(zip);
    expect([...unzipped.keys()].sort()).toEqual([...sources.asset.keys()].sort());
    for (const [name, bytes] of sources.asset) expect(unzipped.get(name)?.equals(bytes)).toBe(true);
    files.push({ path: path.relative(ROOT, zipPath), bytes: zip.length, sha256: hash(zip), kind: "download" }); assertions.zipOriginalBytes = true;
    await page.getByRole("button", { name: "关闭下载链接", exact: true }).click();
    await detail.getByRole("button", { name: "下载原附件", exact: true }).click(); await download(path.basename(assetPath), sources.asset.get(assetPath)!, "original-asset.txt"); assertions.assetOriginalBytes = true;
    await choose(service.fixtures.review); await confirm(); await page.getByRole("button", { name: "手动回顾 (1)", exact: true }).click();
    await renderedBody(reviewRecords.reviews[0].body);
    await expect(page.getByText("来源版本一致", { exact: false })).toHaveCount(2);
    const reviewPath = reviewRecords.reviews[0].file as string;
    await page.getByRole("button", { name: "下载原回顾文件", exact: true }).click(); await download(path.basename(reviewPath), sources.review.get(reviewPath)!, "original-review.md"); assertions.reviewOriginalBytes = true;
    await choose(service.fixtures.historical); await confirm(); await page.getByRole("button", { name: "手动回顾 (1)", exact: true }).click();
    await expect(page.getByText("来源已变化：当前副本不是原引用版本", { exact: false })).toHaveCount(1);
    await expect(page.getByText("来源未包含在此笔记本中", { exact: false })).toHaveCount(1);
    assertions.historicalSources = true; await screenshot("historical-review");
    const durable = await stored(page); expect(durable.jobs).toHaveLength(3); expect(durable.receipts).toHaveLength(3);
    for (const fixture of Object.values(service.fixtures)) await assertStoredOriginals(fixture, durable);
    await proof("durable-readback.json", durable);
    await page.reload(); await ready(); await open(service.fixtures.asset); await renderedBody(assetRecords.notes[0].body); expect(await stored(page)).toEqual(durable);
    await closeBrowser(); await launch(); await page.goto(ORIGIN + "/notebooks"); await ready(); await open(service.fixtures.asset);
    expect(await stored(page)).toEqual(durable); await renderedBody(assetRecords.notes[0].body); await screenshot("cold-reopen");
    await open(service.fixtures.review); await page.getByRole("button", { name: "手动回顾 (1)", exact: true }).click();
    await renderedBody(reviewRecords.reviews[0].body); assertions.coldReopen = true;
    await peer.goto(ORIGIN + "/__get443_sdk/peer");
    await expect(peer.locator("#peer-event")).toHaveText("INITIAL_SESSION:A");

    await guard!.foreground(page); await mode(context!, { hold: "B" }); await peerSubmit("B");
    await eventSeen("GET443_NATIVE_AUTH:SIGNED_IN:B");
    await expect.poll(async () => (await jsonControl<{ held: number }>(context!, "/state")).held).toBeGreaterThan(0);
    await expect(section()).toBeHidden(); guard!.assertNoFocusFallback(page);
    await mode(context!, { release: true }); await ready(); await expect(page.getByText("账户已更换，已切换到此账户的本地空间。", { exact: true })).toBeVisible();
    await expect(page.getByText("此账户尚未在当前浏览器保存笔记本。", { exact: true })).toBeVisible(); expect(await stored(page)).toEqual(durable);
    assertions.switchOwner = true;
    await peerSubmit("A"); await ready(); await open(service.fixtures.asset);
    await guard!.foreground(page); await mode(context!, { hold: "A" }); await page.getByRole("button", { name: "重新验证账户", exact: true }).click();
    await expect.poll(async () => (await jsonControl<{ held: number }>(context!, "/state")).held).toBeGreaterThan(0);
    await peerSubmit("B"); await eventSeen("GET443_NATIVE_AUTH:SIGNED_IN:B"); await ready();
    await expect(page.getByText("此账户尚未在当前浏览器保存笔记本。", { exact: true })).toBeVisible();
    await mode(context!, { release: true }); await expect.poll(() => guard!.userRequests.size).toBe(0);
    await expect(page.getByText("账户已更换，已切换到此账户的本地空间。", { exact: true })).toBeVisible();
    await expect(page.getByRole("heading", { name: "已保存的本地副本", exact: true })).toHaveCount(0); expect(await stored(page)).toEqual(durable);
    guard!.assertNoFocusFallback(page); assertions.lateOwnerFence = true;
    await peerSubmit("A"); await ready(); await open(service.fixtures.asset);
    await guard!.foreground(page); await peerSubmit("out"); await eventSeen("GET443_NATIVE_AUTH:SIGNED_OUT:none");
    await expect(section()).toBeHidden(); guard!.assertNoFocusFallback(page); expect(await stored(page)).toEqual(durable); assertions.crossTabSignOut = true;
    await peerSubmit("A"); await ready();

    guard!.scriptGate(page); const stale = await page.reload({ waitUntil: "commit" }); expect(stale).not.toBeNull();
    await stale!.finished(); expect((await stale!.text()).includes(OWNER_A)).toBe(true);
    await expect.poll(() => guard!.gate?.count ?? 0).toBeGreaterThan(0);
    await context!.clearCookies(); guard!.releaseScripts();
    await expect(page.getByText("当前身份暂不可验证。本地内容保持锁定且未删除，请重新验证或登录。", { exact: true })).toBeVisible();
    await expect(section()).toBeHidden(); expect(await stored(page)).toEqual(durable); assertions.initialNullLocked = true; await screenshot("identity-locked");
    await peerSubmit("A"); await ready();
    // A fresh document runs the real subscription's INITIAL_SESSION/getUser
    // path. The browser-only denial leaves actual server getUser valid.
    guard!.expectedAuthError = true; await mode(context!, { deny: "A" }); await page.reload();
    await expect(page.getByText("当前身份暂不可验证。本地内容保持锁定且未删除，请重新验证或登录。", { exact: true })).toBeVisible();
    await expect(section()).toBeHidden(); expect(await stored(page)).toEqual(durable); assertions.initialDeniedLocked = true;
    await mode(context!, { release: true }); await page.getByRole("button", { name: "重新验证账户", exact: true }).click(); await ready(); guard!.expectedAuthError = false;
    await mode(context!, { hold: "A" }); const began = Date.now(); await page.getByRole("button", { name: "重新验证账户", exact: true }).click();
    await expect(page.getByText("正在验证当前账户，本地内容暂时锁定。", { exact: true })).toBeVisible();
    await expect.poll(async () => (await jsonControl<{ held: number }>(context!, "/state")).held).toBeGreaterThan(0);
    await expect(page.getByText("当前身份暂不可验证。本地内容保持锁定且未删除，请重新验证或登录。", { exact: true })).toBeVisible({ timeout: 20_000 });
    expect(Date.now() - began).toBeGreaterThanOrEqual(14_000);
    await mode(context!, { release: true }); await expect.poll(() => guard!.userRequests.size).toBe(0);
    await expect(section()).toBeHidden(); expect(await stored(page)).toEqual(durable); assertions.deadlineLateLocked = true;
    await page.getByRole("button", { name: "重新验证账户", exact: true }).click(); await ready(); await open(service.fixtures.asset);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)).toBe(true);
    const server = await jsonControl<{ authLedger: { outcome: string; client: string; path: string }[]; network: { outcome: string }[] }>(context!, "/state");
    serverSnapshot = server;
    expect(server.network.every(row => row.outcome === "next")).toBe(true); expect(server.authLedger.every(row => ["allowed", "released", "synthetic-denied"].includes(row.outcome))).toBe(true);
    expect(server.authLedger.some(row => row.client === "server" && row.path === AUTH + "/rest/v1/domains")).toBe(true);
    await closeBrowser();
    expect(boundaries).toHaveLength(2);
    for (const boundary of boundaries) { expect(boundary.rows.length).toBeGreaterThan(0); expect(boundary.rows.every(row => row.outcome === "allowed")).toBe(true); expect(boundary.errors).toEqual([]); }
    assertions.networkBoundary = true;
    passed = true;
  } finally {
    try {
      if (context) {
        try { if (page!) await screenshot("failure"); } catch { /* Preserve available diagnostics without auth data. */ }
        await closeBrowser();
      }
    } finally {
      await proof("network-ledger.json", { browsers: boundaries.map((boundary, phase) => ({ phase, rows: boundary.rows, errors: boundary.errors })), server: serverSnapshot });
      if (browserExits.length > 0 && browserExits.every(value => value.verifiedExit)) {
        await rm(profile, { recursive: true, force: true }); await expect(access(profile)).rejects.toThrow();
        for (const value of browserExits) value.profileRemoved = true;
      }
      // Unverified live-process profiles stay quarantined and must never be
      // uploaded. The final verifier rejects any missing removal/exit proof.
      await proof("browser-exits.json", browserExits);
    }
  }
  expect(passed).toBe(true); expect(browserExits).toHaveLength(2); expect(browserExits[0].pid).not.toBe(browserExits[1].pid);
  await proof("acceptance.json", { passed, sourceSHA: service!.sourceSHA, project, viewport, assertions, browserExits, files,
    authMode: "synthetic-service-real-pinned-sdk", strictModeDevelopment: "not executed", realAuth: "not executed", profileReference: hash(profile + randomUUID()) });
});
