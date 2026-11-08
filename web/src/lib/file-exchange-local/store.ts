import { previewExchange, sha256 } from "../file-exchange/preview.ts";
import type { ExchangePreview } from "../file-exchange/preview.ts";
import type { ExchangeNote, ExchangeRecords, ExchangeReview } from "../file-exchange/contract.ts";
import type { OwnerLease } from "./epoch.ts";
import { assertSameSource, localReject, ownerKey } from "./model.ts";
import type { ImportJob, ImportReceipt, LocalFileDescriptor } from "./model.ts";
import { prepareImport } from "./prepare.ts";
import type { PreparedImport } from "./prepare.ts";
import { storeZip } from "./zip.ts";

const DATABASE = "daypage-file-exchange-local-v1";
type StoreName = "jobs" | "files" | "items" | "receipts";
interface FileRow extends LocalFileDescriptor {
  realm: string; uid: string; namespace: string; jobGeneration: string; generation: string; blob: Blob;
}
interface ItemRow {
  realm: string; uid: string; namespace: string; generation: string;
  kind: "note" | "review"; identity: string; value: ExchangeNote | ExchangeReview;
}
export interface NotebookSummary {
  namespace: string; exportID: string; status: ImportJob["status"]; createdAt: string;
  notes: number; reviews: number; totalFiles: number; savedFiles: number; bytes: number;
}
export interface LocalNotebook { job: ImportJob; receipt: ImportReceipt; preview: ExchangePreview }
interface TransactionContext<T> {
  store(name: StoreName): IDBObjectStore;
  read<V>(request: IDBRequest<V>, success: (value: V) => void): void;
  result(value: T): void;
}
function sameFile(row: FileRow | undefined, expected: LocalFileDescriptor, job: ImportJob): row is FileRow {
  return Boolean(row && row.realm === job.realm && row.uid === job.uid && row.namespace === job.namespace &&
    row.jobGeneration === job.generation && typeof row.generation === "string" && row.generation.length > 0 &&
    row.path === expected.path && row.kind === expected.kind && row.bytes === expected.bytes && row.sha256 === expected.sha256 &&
    row.blob instanceof Blob && row.blob.size === expected.bytes);
}
function itemsFor(job: ImportJob, records: ExchangeRecords): ItemRow[] {
  const prefix = { realm: job.realm, uid: job.uid, namespace: job.namespace, generation: job.generation };
  return [...records.notes.map(value => ({ ...prefix, kind: "note" as const,
    identity: value.namespace.toLowerCase() + "\0" + value.original_id.toLowerCase(), value })),
  ...records.reviews.map(value => ({ ...prefix, kind: "review" as const,
    identity: value.namespace.toLowerCase() + "\0" + value.generation_id.toLowerCase(), value }))];
}

/** Four real IDB stores. Transactions contain only synchronous request scheduling. */
export class BrowserNotebookStore {
  private factory?: IDBFactory;
  private opening?: Promise<IDBDatabase>;
  private openGeneration = 0;
  constructor(factory?: IDBFactory) { this.factory = factory; }
  close() { this.openGeneration++; const opening = this.opening; this.opening = undefined; void opening?.then(db => db.close(), () => {}); }
  private database(): Promise<IDBDatabase> {
    let factory: IDBFactory;
    try { factory = this.factory ?? globalThis.indexedDB; } catch { return Promise.reject(new Error("local-storage-unavailable")); }
    if (!factory) return Promise.reject(new Error("local-storage-unavailable"));
    if (!this.opening) {
      const generation = this.openGeneration;
      this.opening = new Promise<IDBDatabase>((resolve, reject) => {
      let refused = false;
      const request = factory.open(DATABASE, 1);
      request.onblocked = () => { refused = true; reject(new Error("local-storage-blocked")); };
      request.onerror = () => { if (generation === this.openGeneration) this.opening = undefined; reject(request.error ?? new Error("local-storage-unavailable")); };
      request.onupgradeneeded = () => {
        const db = request.result;
        const jobs = db.createObjectStore("jobs", { keyPath: ["realm", "uid", "namespace"] });
        jobs.createIndex("owner", ["realm", "uid"]); jobs.createIndex("export", ["realm", "uid", "exportID"], { unique: true });
        const files = db.createObjectStore("files", { keyPath: ["realm", "uid", "namespace", "path"] });
        files.createIndex("notebook", ["realm", "uid", "namespace"]);
        const items = db.createObjectStore("items", { keyPath: ["realm", "uid", "namespace", "kind", "identity"] });
        items.createIndex("notebook", ["realm", "uid", "namespace"]);
        const receipts = db.createObjectStore("receipts", { keyPath: ["realm", "uid", "namespace"] });
        receipts.createIndex("owner", ["realm", "uid"]); receipts.createIndex("export", ["realm", "uid", "exportID"], { unique: true });
      };
      request.onsuccess = () => {
        const db = request.result;
        if (refused || generation !== this.openGeneration) { db.close(); reject(new Error("local-storage-unavailable")); return; }
        db.onversionchange = () => { db.close(); if (generation === this.openGeneration) { this.openGeneration++; this.opening = undefined; } };
        resolve(db);
      };
      }).catch(error => { if (generation === this.openGeneration) this.opening = undefined; throw error; });
    }
    return this.opening;
  }
  private async transaction<T>(names: StoreName[], mode: IDBTransactionMode, lease: OwnerLease,
    schedule: (context: TransactionContext<T>) => void): Promise<T> {
    const db = await this.database(); lease.check();
    return new Promise<T>((resolve, reject) => {
      const tx = db.transaction(names, mode, mode === "readwrite" ? { durability: "strict" } : undefined);
      const release = lease.track(tx); let value: T; let assigned = false; let failure: unknown;
      const fail = (error: unknown) => { failure = error; try { tx.abort(); } catch { reject(error); } };
      const safe = (body: () => void) => { try { lease.check(); body(); } catch (error) { fail(error); } };
      tx.onabort = () => { release(); reject(failure ?? tx.error ?? new DOMException("Operation stopped", "AbortError")); };
      tx.oncomplete = () => {
        release();
        try { lease.check(); if (!assigned) localReject("incomplete-local-transaction"); resolve(value); } catch (error) { reject(error); }
      };
      safe(() => schedule({ store: name => tx.objectStore(name),
        read: (request, success) => { request.onsuccess = () => safe(() => success(request.result)); },
        result: result => { value = result; assigned = true; } }));
    });
  }
  private async start(prepared: PreparedImport, lease: OwnerLease, expectedNamespace?: string): Promise<{ job: ImportJob } | { receipt: ImportReceipt }> {
    const owner = lease.owner;
    const candidate: ImportJob = { ...owner, ...prepared.identity, namespace: crypto.randomUUID(), generation: crypto.randomUUID(),
      status: "pending", createdAt: new Date().toISOString(), manifest: prepared.preview.manifest, expected: prepared.expected };
    return this.transaction(["jobs", "receipts"], "readwrite", lease, c => {
      const exportKey = ownerKey(owner, prepared.identity.exportID);
      c.read<ImportReceipt | undefined>(c.store("receipts").index("export").get(exportKey), receipt => {
        if (receipt) {
          assertSameSource(receipt, prepared.identity);
          if (expectedNamespace && receipt.namespace !== expectedNamespace) localReject("source-conflict");
          c.result({ receipt }); return;
        }
        c.read<ImportJob | undefined>(c.store("jobs").index("export").get(exportKey), job => {
          if (job) {
            assertSameSource(job, prepared.identity);
            if (job.status !== "pending" || (expectedNamespace && job.namespace !== expectedNamespace)) localReject("source-conflict");
            c.result({ job });
          } else {
            if (expectedNamespace) localReject("pending-import-unavailable");
            c.store("jobs").add(candidate); c.result({ job: candidate });
          }
        });
      });
    });
  }
  private async stage(job: ImportJob, expected: LocalFileDescriptor, bytes: Uint8Array, lease: OwnerLease): Promise<ImportReceipt | undefined> {
    const blob = new Blob([Uint8Array.from(bytes).buffer]);
    const row: FileRow = { ...lease.owner, ...expected, namespace: job.namespace, jobGeneration: job.generation,
      generation: crypto.randomUUID(), blob };
    return this.transaction(["jobs", "files", "receipts"], "readwrite", lease, c => {
      c.read<ImportJob | undefined>(c.store("jobs").get(ownerKey(lease.owner, job.namespace)), current => {
        if (!current || current.generation !== job.generation) localReject("pending-import-changed");
        assertSameSource(current, job);
        if (current.status === "committed") {
          c.read<ImportReceipt | undefined>(c.store("receipts").get(ownerKey(lease.owner, job.namespace)), receipt => {
            if (!receipt || receipt.generation !== job.generation) localReject("notebook-unavailable");
            assertSameSource(receipt, job); c.result(receipt);
          });
          return;
        }
        c.read<FileRow | undefined>(c.store("files").get(ownerKey(lease.owner, job.namespace, expected.path)), existing => {
          if (existing && !sameFile(existing, expected, job)) localReject("immutable-file-conflict");
          if (!existing) c.store("files").add(row);
          c.result(undefined);
        });
      });
    });
  }
  private readRows(job: ImportJob, lease: OwnerLease): Promise<FileRow[]> {
    return this.transaction(["files"], "readonly", lease, c => {
      c.read<FileRow[]>(c.store("files").index("notebook").getAll(IDBKeyRange.only(ownerKey(lease.owner, job.namespace))), rows => c.result(rows));
    });
  }
  private async verifyRows(job: ImportJob, rows: FileRow[], lease: OwnerLease) {
    if (rows.length !== job.expected.length) localReject("local-originals-incomplete");
    const lookup = new Map(rows.map(row => [row.path, row])), originals = new Map<string, Uint8Array>();
    for (const expected of job.expected) {
      lease.check(); const row = lookup.get(expected.path);
      if (!sameFile(row, expected, job)) localReject("local-originals-changed");
      const bytes = new Uint8Array(await row.blob.arrayBuffer()); lease.check();
      if (bytes.byteLength !== expected.bytes || await sha256(bytes) !== expected.sha256) localReject("local-originals-changed");
      lease.check(); originals.set(expected.path, bytes);
    }
    return originals;
  }
  /** Explicit confirmation is the sole caller of this write boundary. */
  async import(selected: ExchangePreview, lease: OwnerLease,
    options: { expectedNamespace?: string; progress?: (done: number, total: number) => void } = {}): Promise<ImportReceipt> {
    const prepared = await prepareImport(selected, lease.signal); lease.check();
    const started = await this.start(prepared, lease, options.expectedNamespace); lease.check();
    if ("receipt" in started) return started.receipt;
    const job = started.job;
    for (let i = 0; i < job.expected.length; i++) {
      const expected = job.expected[i], bytes = prepared.originals.get(expected.path);
      if (!bytes) localReject("selected-original-missing");
      const published = await this.stage(job, expected, bytes, lease); lease.check();
      if (published) return published; // Another tab completed this exact job while copying.
      // Read back each immutable Blob before acknowledging progress; hashes never run in the IDB transaction.
      const row = await this.transaction<FileRow | undefined>(["files"], "readonly", lease, c => {
        c.read(c.store("files").get(ownerKey(lease.owner, job.namespace, expected.path)), row => c.result(row));
      });
      if (!sameFile(row, expected, job) || await sha256(new Uint8Array(await row.blob.arrayBuffer())) !== expected.sha256) localReject("local-originals-changed");
      lease.check(); options.progress?.(i + 1, job.expected.length);
    }
    const verified = await this.readRows(job, lease);
    await this.verifyRows(job, verified, lease); lease.check();
    const generation = new Map(verified.map(row => [row.path, row.generation]));
    const items = itemsFor(job, prepared.preview.records);
    const receipt: ImportReceipt = { ...lease.owner, ...prepared.identity, namespace: job.namespace, generation: job.generation,
      committedAt: new Date().toISOString(), notes: prepared.preview.records.notes.length, reviews: prepared.preview.records.reviews.length,
      files: job.expected.length, bytes: job.expected.reduce((sum, file) => sum + file.bytes, 0) };
    return this.transaction(["jobs", "files", "items", "receipts"], "readwrite", lease, c => {
      c.read<ImportJob | undefined>(c.store("jobs").get(ownerKey(lease.owner, job.namespace)), current => {
        if (!current || current.generation !== job.generation) localReject("pending-import-changed");
        assertSameSource(current, prepared.identity);
        c.read<ImportReceipt | undefined>(c.store("receipts").get(ownerKey(lease.owner, job.namespace)), existing => {
          if (existing) { assertSameSource(existing, prepared.identity); c.result(existing); return; }
          if (current.status !== "pending") localReject("pending-import-changed");
          let remaining = job.expected.length;
          for (const expected of job.expected) c.read<FileRow | undefined>(c.store("files").get(ownerKey(lease.owner, job.namespace, expected.path)), row => {
            if (!sameFile(row, expected, job) || row.generation !== generation.get(expected.path)) localReject("local-originals-changed");
            if (--remaining === 0) {
              for (const item of items) c.store("items").add(item);
              c.store("receipts").add(receipt);
              c.store("jobs").put({ ...current, status: "committed" }); c.result(receipt);
            }
          });
        });
      });
    });
  }
  list(lease: OwnerLease): Promise<NotebookSummary[]> {
    return this.transaction(["jobs", "files"], "readonly", lease, c => {
      c.read<ImportJob[]>(c.store("jobs").index("owner").getAll(IDBKeyRange.only(ownerKey(lease.owner))), jobs => {
        if (!jobs.length) { c.result([]); return; }
        const result: NotebookSummary[] = []; let remaining = jobs.length;
        for (const job of jobs) c.read(c.store("files").index("notebook").count(IDBKeyRange.only(ownerKey(lease.owner, job.namespace))), savedFiles => {
          result.push({ namespace: job.namespace, exportID: job.exportID, status: job.status, createdAt: job.createdAt,
            notes: job.manifest.notes_count, reviews: job.manifest.reviews_count, totalFiles: job.expected.length, savedFiles,
            bytes: job.expected.reduce((sum, file) => sum + file.bytes, 0) });
          if (--remaining === 0) c.result(result.sort((a, b) => b.createdAt.localeCompare(a.createdAt)));
        });
      });
    });
  }
  async load(namespace: string, lease: OwnerLease): Promise<LocalNotebook> {
    const snapshot = await this.transaction<{ job: ImportJob; receipt: ImportReceipt; items: ItemRow[] }>(["jobs", "receipts", "items"], "readonly", lease, c => {
      c.read<ImportJob | undefined>(c.store("jobs").get(ownerKey(lease.owner, namespace)), job => {
        if (!job || job.status !== "committed") localReject("notebook-unavailable");
        c.read<ImportReceipt | undefined>(c.store("receipts").get(ownerKey(lease.owner, namespace)), receipt => {
          if (!receipt || receipt.generation !== job.generation) localReject("notebook-unavailable");
          assertSameSource(receipt, job);
          c.read<ItemRow[]>(c.store("items").index("notebook").getAll(IDBKeyRange.only(ownerKey(lease.owner, namespace))), items => c.result({ job, receipt, items }));
        });
      });
    });
    const { job, receipt, items } = snapshot;
    const originals = await this.verifyRows(job, await this.readRows(job, lease), lease);
    const preview = await previewExchange([...originals].map(([path, bytes]) => ({ path, size: bytes.length, read: async () => bytes })), lease.signal);
    if (await sha256(preview.manifestBytes) !== job.manifestDigest || preview.manifest.content_sha256 !== job.contentDigest) localReject("local-originals-changed");
    const derived = itemsFor(job, preview.records), stored = new Map(items.map(item => [item.kind + "\0" + item.identity, item]));
    if (stored.size !== derived.length || derived.some(item => JSON.stringify(stored.get(item.kind + "\0" + item.identity)) !== JSON.stringify(item))) localReject("local-items-changed");
    lease.check(); return { job, receipt, preview };
  }
  async originalsZip(namespace: string, lease: OwnerLease): Promise<Uint8Array> {
    const notebook = await this.load(namespace, lease); lease.check();
    const entries = [{ path: "daypage-exchange.json", bytes: notebook.preview.manifestBytes },
      ...[...notebook.preview.files].map(([path, bytes]) => ({ path, bytes }))];
    const bytes = storeZip(entries); lease.check(); return bytes;
  }
  discardPending(namespace: string, lease: OwnerLease): Promise<void> {
    return this.transaction(["jobs", "files", "items", "receipts"], "readwrite", lease, c => {
      c.read<ImportJob | undefined>(c.store("jobs").get(ownerKey(lease.owner, namespace)), job => {
        if (!job || job.status !== "pending") localReject("pending-import-unavailable");
        c.read(c.store("receipts").get(ownerKey(lease.owner, namespace)), receipt => {
          if (receipt) localReject("published-notebook-is-immutable");
          for (const name of ["files", "items"] as const) {
            const request = c.store(name).index("notebook").openKeyCursor(IDBKeyRange.only(ownerKey(lease.owner, namespace)));
            c.read(request, function remove(cursor) {
              if (!cursor) return;
              c.store(name).delete(cursor.primaryKey); cursor.continue();
            });
          }
          c.store("jobs").delete(ownerKey(lease.owner, namespace)); c.result(undefined);
        });
      });
    });
  }
}
