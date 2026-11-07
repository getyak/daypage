"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { EXCHANGE_LIMITS, previewExchange } from "@/lib/file-exchange/preview";
import type { ExchangePreview } from "@/lib/file-exchange/preview";
import { OwnerEpoch } from "@/lib/file-exchange-local/epoch";
import type { OwnerLease } from "@/lib/file-exchange-local/epoch";
import { makeOwner, projectRealm, selectionPaths, LocalExchangeError } from "@/lib/file-exchange-local/model";
import type { LocalOwner } from "@/lib/file-exchange-local/model";
import { BrowserNotebookStore } from "@/lib/file-exchange-local/store";
import type { LocalNotebook, NotebookSummary } from "@/lib/file-exchange-local/store";
import { localPresentation } from "@/lib/file-exchange-local/presentation";
import { NotebookDetail } from "./NotebookDetail";
import styles from "./notebooks.module.css";

type AssetView = { path: string; mime: string; url?: string; text?: string };
function errorText(error: unknown) {
  if (error instanceof DOMException && error.name === "QuotaExceededError") return "浏览器空间不足，没有发布新笔记本。已建立的待完成记录会保留；请保留原导出，释放空间后重试。";
  if (error instanceof DOMException && error.name === "AbortError") return "操作已停止。已建立的待完成记录会保留；若保存恰已完成，可重新打开列表核对。";
  if (error instanceof LocalExchangeError && error.code === "source-conflict") return "同一导出 ID 的内容、原始清单或解析版本不同，已拒绝写入。请重新选择同一原导出。";
  if (error instanceof LocalExchangeError && /local-originals|local-items/.test(error.code)) return "本机副本的原文件或派生记录未通过完整性检查。现有记录没有被删除；请保留并检查原导出。";
  return "本次操作未完成。请确认原导出目录完整、身份可验证且浏览器允许本地存储。没有上传文件。";
}
function deadline<T>(operation: Promise<T>, ms = 15_000): Promise<T> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("auth-verification-timeout")), ms);
    operation.then(value => { clearTimeout(timer); resolve(value); }, error => { clearTimeout(timer); reject(error); });
  });
}

export function NotebooksClient({ initialUID, realm }: { initialUID: string; realm: string }) {
  const [client] = useState(() => createClient());
  const [epoch] = useState(() => new OwnerEpoch());
  const [store] = useState(() => new BrowserNotebookStore());
  const [ready, setReady] = useState(false), [busy, setBusy] = useState(false);
  const [identityMessage, setIdentityMessage] = useState("正在验证当前账户，本地内容暂时锁定。");
  const [message, setMessage] = useState(""), [jobs, setJobs] = useState<NotebookSummary[]>([]);
  const [listStatus, setListStatus] = useState<"loading" | "ready" | "error">("loading");
  const [preview, setPreview] = useState<ExchangePreview | null>(null), [notebook, setNotebook] = useState<LocalNotebook | null>(null);
  const [resume, setResume] = useState<string | undefined>(), [asset, setAsset] = useState<AssetView | null>(null);
  const [downloadReady, setDownloadReady] = useState<{ url: string; name: string; owner: LocalOwner } | null>(null);
  const [progress, setProgress] = useState(""), [discard, setDiscard] = useState<string | null>(null);
  const content = useRef<HTMLElement>(null), picker = useRef<HTMLInputElement>(null), previewHeading = useRef<HTMLHeadingElement>(null);
  const active = useRef<OwnerLease | null>(null), operation = useRef(0), authGeneration = useRef(0), inFlight = useRef(false);
  const urls = useRef(new Set<string>()), channel = useRef<BroadcastChannel | null>(null);
  const clearURLs = useCallback(() => { for (const url of urls.current) URL.revokeObjectURL(url); urls.current.clear(); setDownloadReady(null); }, []);
  const lock = useCallback(() => {
    // Hide synchronously, before React scheduling or any asynchronous auth request.
    if (content.current) content.current.hidden = true;
    epoch.revoke(); authGeneration.current++; operation.current++; active.current = null; inFlight.current = false;
    clearURLs(); setReady(false); setBusy(false); setJobs([]); setPreview(null); setNotebook(null); setAsset(null);
    setResume(undefined); setDiscard(null); setProgress(""); setMessage("");
    if (picker.current) picker.current.value = "";
  }, [clearURLs, epoch]);
  const refresh = useCallback(async () => {
    if (!epoch.owner) return;
    const lease = epoch.lease(); setListStatus("loading");
    try { const values = await store.list(lease); lease.check(); setJobs(values); setListStatus("ready"); }
    catch (error) { if (!lease.signal.aborted) { setMessage(errorText(error)); setListStatus("error"); } }
    finally { lease.close(); }
  }, [epoch, store]);
  const verify = useCallback(async () => {
    lock(); const generation = authGeneration.current;
    setIdentityMessage("正在验证当前账户，本地内容暂时锁定。");
    try {
      const configuredRealm = projectRealm(process.env.NEXT_PUBLIC_SUPABASE_URL ?? "");
      if (configuredRealm !== realm) throw new Error("project-realm-mismatch");
      const { data: { user }, error } = await deadline(client.auth.getUser());
      if (generation !== authGeneration.current) return;
      if (error || !user) throw new Error("owner-unverified");
      epoch.authorize(makeOwner(configuredRealm, user.id));
      setIdentityMessage(user.id === initialUID ? "当前账户已验证。" : "账户已更换，已切换到此账户的本地空间。");
      setReady(true); if (content.current) content.current.hidden = false;
      await refresh();
    } catch {
      if (generation === authGeneration.current) setIdentityMessage("当前身份暂不可验证。本地内容保持锁定且未删除，请重新验证或登录。");
    }
  }, [client, epoch, initialUID, lock, realm, refresh]);
  const verifyCurrent = useCallback(async () => {
    if (!epoch.owner) return;
    const lease = epoch.lease();
    try {
      const { data: { user }, error } = await deadline(client.auth.getUser()); lease.check();
      if (error || !user || user.id !== lease.owner.uid) {
        lock(); setIdentityMessage("当前身份暂不可验证。本地内容已锁定且未删除。");
      } else { setReady(true); if (content.current) content.current.hidden = false; }
    } catch { if (!lease.signal.aborted) { lock(); setIdentityMessage("当前身份暂不可验证。本地内容已锁定且未删除。"); } }
    finally { lease.close(); }
  }, [client, epoch, lock]);
  useEffect(() => {
    let mounted = true;
    picker.current?.setAttribute("webkitdirectory", "");
    const { data: { subscription } } = client.auth.onAuthStateChange((event, session) => {
      // Same-owner refresh/focus events grant no new ownership. Each action
      // still verifies getUser; do not cancel an import merely for token refresh.
      if (event !== "SIGNED_OUT" && epoch.owner && session?.user.id === epoch.owner.uid) return;
      lock();
      // Do not await another Supabase method inside its synchronous auth callback.
      setTimeout(() => { if (mounted) void verify(); }, 0);
    });
    const hide = () => { if (content.current) content.current.hidden = true; setReady(false); };
    const focus = () => {
      hide();
      if (document.visibilityState === "visible") { if (epoch.owner) void verifyCurrent(); else void verify(); }
    };
    // A frozen/back-forward cached document must not reappear with a stale UID.
    // Same-owner verification preserves selected bytes and in-flight local work.
    window.addEventListener("focus", focus); window.addEventListener("pageshow", focus);
    window.addEventListener("pagehide", hide); document.addEventListener("visibilitychange", focus);
    void verify();
    if (typeof BroadcastChannel !== "undefined") {
      const local = new BroadcastChannel("daypage-local-notebooks-changed-v1"); channel.current = local;
      local.onmessage = () => { if (!inFlight.current) void refresh(); };
    }
    return () => {
      mounted = false; authGeneration.current++; epoch.revoke(); operation.current++; clearURLs(); store.close(); subscription.unsubscribe();
      window.removeEventListener("focus", focus); window.removeEventListener("pageshow", focus);
      window.removeEventListener("pagehide", hide); document.removeEventListener("visibilitychange", focus);
      channel.current?.close(); channel.current = null;
    };
  }, [client, clearURLs, epoch, lock, refresh, store, verify, verifyCurrent]);

  async function run(action: (lease: OwnerLease) => Promise<void>, recheckIdentity = true) {
    if (!epoch.owner || inFlight.current) return;
    inFlight.current = true; setBusy(true); setMessage(""); const id = ++operation.current;
    const lease = epoch.lease(); active.current = lease;
    try {
      if (recheckIdentity) {
        try {
          const { data: { user }, error } = await deadline(client.auth.getUser()); lease.check();
          if (error || !user || user.id !== lease.owner.uid) throw new Error("owner-unverified");
        } catch (error) {
          // A failed identity check must lock. Cancellation or an older result
          // must not lock a newer owner, and local-action errors stay separate.
          if (!lease.signal.aborted && id === operation.current) {
            lock(); setIdentityMessage("当前身份暂不可验证。本地内容已锁定且未删除。");
          }
          throw error;
        }
      }
      await action(lease); lease.check();
    } catch (error) { if (id === operation.current) setMessage(errorText(error)); }
    finally {
      lease.close();
      if (id === operation.current) { active.current = null; inFlight.current = false; setBusy(false); setProgress(""); void refresh(); }
    }
  }
  function cancel() {
    active.current?.cancel(); operation.current++; active.current = null; inFlight.current = false;
    setBusy(false); setPreview(null); setProgress("");
    setMessage("操作已停止。已建立的待完成记录保留；若保存恰已完成，请在列表核对。"); void refresh();
  }
  async function select(files: File[]) {
    await run(async lease => {
      setPreview(null); setNotebook(null); setAsset(null); clearURLs();
      const paths = selectionPaths(files);
      const result = await previewExchange(files.map((file, index) => ({ path: paths[index], size: file.size,
        read: async () => new Uint8Array(await file.arrayBuffer()) })), lease.signal);
      lease.check(); setPreview(result); setMessage("预览完成，尚未保存。只有确认后才建立本地待完成记录。");
      setTimeout(() => { if (epoch.owner === lease.owner && !content.current?.hidden) previewHeading.current?.focus(); }, 0);
    });
  }
  function notify() { channel.current?.postMessage("changed"); }
  function download(bytes: Uint8Array, name: string, mime: string, lease: OwnerLease) {
    lease.check(); const url = URL.createObjectURL(new Blob([Uint8Array.from(bytes).buffer], { type: mime })); urls.current.add(url);
    if (downloadReady) { URL.revokeObjectURL(downloadReady.url); urls.current.delete(downloadReady.url); }
    // A real link keeps the final save under a fresh user gesture, including
    // browsers that do not allow a scripted download after asynchronous work.
    setDownloadReady({ url, name, owner: lease.owner }); setMessage("原文件已在本机准备好，请点击下方保存链接。没有上传文件。");
  }
  function assertNotebookOwner(value: LocalNotebook, lease: OwnerLease) {
    lease.check(); if (value.job.realm !== lease.owner.realm || value.job.uid !== lease.owner.uid) throw new Error("owner-changed");
  }
  function chooseAsset(path: string, show: boolean) {
    const selected = notebook; if (!selected) return;
    void run(async lease => {
      assertNotebookOwner(selected, lease);
      const bytes = path === "daypage-exchange.json" ? selected.preview.manifestBytes : selected.preview.files.get(path);
      if (!bytes) throw new Error("original-unavailable");
      if (!show) { download(bytes, path.split("/").at(-1) ?? "original", "application/octet-stream", lease); return; }
      const mime = localPresentation(path, bytes); if (!mime) throw new Error("preview-unavailable");
      if (asset?.url) { URL.revokeObjectURL(asset.url); urls.current.delete(asset.url); }
      if (mime === "text/plain") setAsset({ path, mime, text: new TextDecoder("utf-8", { fatal: true }).decode(bytes) });
      else {
        const url = URL.createObjectURL(new Blob([Uint8Array.from(bytes).buffer], { type: mime })); urls.current.add(url);
        lease.check(); setAsset({ path, mime, url });
      }
    });
  }
  return <div className={styles.page}>
    <h1>本地笔记本</h1>
    <p>通过 DayPage 交换文件保存只读副本。文件、正文和附件只保存在当前浏览器，不会上传到服务器或发送给 AI。</p>
    <p className={styles.muted}>按当前项目和已验证账户隔离；浏览器清理、隐私模式或空间回收仍可能删除本机数据。这里不是云备份，也不是浏览器设备所有者之间的加密隔离，请保留原导出。</p>
    <p role="status">{identityMessage}</p>
    <button className="btn btn--soft btn--sm" onClick={() => void verify()}>重新验证账户</button>
    <section ref={content} hidden={!ready} aria-label="当前账户的本地笔记本">
      <section className={styles.card} aria-label="导入交换文件夹">
        <h2>选择 DayPage 导出文件夹</h2>
        <p>选择包含 daypage-exchange.json 的完整文件夹。预览阶段不写入笔记本；来源文件从不修改。需要支持文件夹选择的浏览器。</p>
        <input ref={picker} type="file" multiple disabled={busy || !ready} aria-label="选择交换文件夹"
          onChange={event => {
            if ((event.target.files?.length ?? 0) > EXCHANGE_LIMITS.files + 1) { setMessage("所选目录超出交换文件数量上限，请选择原导出的完整目录。"); return; }
            const files = Array.from(event.target.files ?? []); if (files.length) void select(files);
          }} />
        {resume ? <div className={styles.warning}><p>正在恢复待完成导入。必须选择同一导出 ID、内容和原始清单；不同来源会被拒绝。</p>
          <button className="btn btn--soft btn--sm" disabled={busy} onClick={() => { setResume(undefined); setPreview(null); if (picker.current) picker.current.value = ""; }}>退出恢复模式，保留待完成副本</button>
        </div> : null}
        {preview ? <div className={styles.card}>
          <h3 ref={previewHeading} tabIndex={-1}>导入预览：尚未保存</h3>
          <p>{preview.records.notes.length} 条笔记 · {preview.records.reviews.length} 份回顾 · {preview.manifest.files.length + 1} 个原文件 · {preview.bytes} bytes（另含清单）</p>
          <p>导出 ID：{preview.manifest.export_id}</p>
          <p className={styles.muted}>引用缺失或版本已变化会按原状态保留，不会补造来源。确认后写入此浏览器当前账户的本地空间。</p>
          <div className={styles.row}>
            <button className="btn btn--primary btn--sm" disabled={busy} onClick={() => {
              const selected = preview, expectedNamespace = resume;
              void run(async lease => {
                const receipt = await store.import(selected, lease, { expectedNamespace,
                  progress: (done, total) => { lease.check(); setProgress(`正在核对本地原文件：${done} / ${total}`); } });
                lease.check(); notify(); const value = await store.load(receipt.namespace, lease); lease.check();
                setNotebook(value); setPreview(null); setResume(undefined); setMessage("已保存并读回核对本地笔记本。原文件 ZIP 可随时下载。");
              });
            }}>{resume ? "确认继续保存到此浏览器" : "确认保存到此浏览器"}</button>
            <button className="btn btn--soft btn--sm" disabled={busy} onClick={() => { setPreview(null); setResume(undefined); if (picker.current) picker.current.value = ""; }}>取消预览</button>
          </div>
        </div> : null}
      </section>
      {busy ? <div className={styles.row}><span>{progress || "正在处理本地操作…"}</span><button className="btn btn--soft btn--sm" onClick={cancel}>停止本次操作</button></div> : null}
      <div className={styles.status} role="status" aria-live="polite">{message}</div>
      <h2 style={{ marginTop: 28 }}>此账户在当前浏览器保存的内容</h2>
      <button className="btn btn--soft btn--sm" disabled={busy} onClick={() => void refresh()}>刷新本地列表</button>
      {listStatus === "loading" ? <p className={styles.muted}>正在读取本地列表…</p> : listStatus === "error" ?
        <p className={styles.warning}>本地列表未读取成功，不能据此判断内容为空。现有数据未被删除。</p> :
        !jobs.length ? <p className={styles.muted}>此账户尚未在当前浏览器保存笔记本。</p> : null}
      <div className={styles.cards}>
        {jobs.map(job => <article className={styles.card} key={job.namespace}>
          <h3>{job.status === "committed" ? "已保存" : "待完成：尚未发布"}</h3>
          <p className={styles.muted}>导出 {job.exportID}</p><p>{job.notes} 条笔记 · {job.reviews} 份回顾 · {job.savedFiles}/{job.totalFiles} 个原文件</p>
          {job.status === "committed" ? <button className="btn btn--soft btn--sm" disabled={busy} onClick={() => void run(async lease => {
            const value = await store.load(job.namespace, lease); lease.check(); clearURLs(); setAsset(null); setNotebook(value); setPreview(null);
          })}>打开全文与原文件</button> : <div className={styles.row}>
            <button className="btn btn--soft btn--sm" disabled={busy} onClick={() => { setResume(job.namespace); setPreview(null); if (picker.current) { picker.current.value = ""; picker.current.click(); } }}>重新选择同一导出继续</button>
            <button className="btn btn--soft btn--sm" disabled={busy} onClick={() => setDiscard(job.namespace)}>丢弃此待完成副本</button>
          </div>}
          {discard === job.namespace ? <div className={styles.warning}><p>仅删除此账户的这一份未发布本地副本；不会修改原导出或其他笔记本。</p>
            <button className="btn btn--soft btn--sm" disabled={busy} onClick={() => void run(async lease => {
              await store.discardPending(job.namespace, lease); lease.check(); notify(); setDiscard(null); setResume(undefined); setPreview(null); setMessage("已丢弃此待完成副本，原导出未改变。");
            })}>确认丢弃</button> <button className="btn btn--soft btn--sm" onClick={() => setDiscard(null)}>保留</button>
          </div> : null}
        </article>)}
      </div>
      {notebook ? <NotebookDetail key={notebook.job.namespace} notebook={notebook} disabled={busy} onAsset={chooseAsset} onZip={() => {
        const selected = notebook;
        void run(async lease => { assertNotebookOwner(selected, lease); const bytes = await store.originalsZip(selected.job.namespace, lease);
          download(bytes, `daypage-originals-${selected.job.exportID}.zip`, "application/zip", lease); });
      }} /> : null}
      {downloadReady ? <section className={styles.card} aria-label="原文件下载已准备好">
        <h2>原文件已准备好</h2><p>点击保存到设备；内容直接来自本机副本。</p>
        <a className="btn btn--primary btn--sm" href={downloadReady.url} download={downloadReady.name}
          onClick={event => { if (!ready || epoch.owner !== downloadReady.owner) event.preventDefault(); }}>保存 {downloadReady.name}</a>
        <button className="btn btn--soft btn--sm" onClick={() => { URL.revokeObjectURL(downloadReady.url); urls.current.delete(downloadReady.url); setDownloadReady(null); }}>关闭下载链接</button>
      </section> : null}
      {asset ? <section className={styles.card} aria-label="仅本机的附件预览">
        <h2>本机附件预览</h2><p className={styles.muted}>{asset.path}</p>
        <button className="btn btn--soft btn--sm" onClick={() => { if (asset.url) { URL.revokeObjectURL(asset.url); urls.current.delete(asset.url); } setAsset(null); }}>关闭预览</button>
        {asset.text !== undefined ? <pre className={styles.text}>{asset.text}</pre> : asset.mime.startsWith("image/") ?
          // Blob-only explicit preview: Next image optimization must not proxy these private bytes.
          // eslint-disable-next-line @next/next/no-img-element
          <img className={styles.media} src={asset.url} alt="显式打开的本地附件" /> :
          <audio className={styles.media} src={asset.url} controls preload="none" />}
      </section> : null}
    </section>
  </div>;
}
