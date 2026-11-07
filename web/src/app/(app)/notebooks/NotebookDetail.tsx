"use client";

import { useState } from "react";
import type { LocalNotebook } from "@/lib/file-exchange-local/store";
import { localPresentation } from "@/lib/file-exchange-local/presentation";
import styles from "./notebooks.module.css";

export function NotebookDetail({ notebook, disabled, onAsset, onZip }: {
  notebook: LocalNotebook; disabled: boolean; onAsset(path: string, preview: boolean): void; onZip(): void;
}) {
  const [kind, setKind] = useState<"note" | "review">(notebook.preview.records.notes.length ? "note" : "review");
  const [position, setPosition] = useState(0);
  const { notes, reviews } = notebook.preview.records;
  const values = kind === "note" ? notes : reviews, index = Math.min(position, Math.max(0, values.length - 1));
  const note = kind === "note" ? notes[index] : undefined, review = kind === "review" ? reviews[index] : undefined;
  const pageStart = Math.floor(index / 20) * 20;
  return <section className={styles.card} aria-label="本地笔记本内容">
    <h2>已保存的本地副本</h2>
    <p className={styles.muted}>导出 ID：{notebook.receipt.exportID} · {notes.length} 条笔记 · {reviews.length} 份手动回顾</p>
    <button className="btn btn--soft btn--sm" disabled={disabled} onClick={onZip}>下载全部原文件 ZIP</button>
    <p className={styles.muted}>ZIP 保留原始清单、路径和字节。没有上传、合并到云端或触发 AI。</p>
    <div className={styles.row}>
      <button className="btn btn--soft btn--sm" aria-pressed={kind === "note"} onClick={() => { setKind("note"); setPosition(0); }}>笔记 ({notes.length})</button>
      <button className="btn btn--soft btn--sm" aria-pressed={kind === "review"} onClick={() => { setKind("review"); setPosition(0); }}>手动回顾 ({reviews.length})</button>
    </div>
    <div className={styles.list} aria-label="选择内容">
      {values.slice(pageStart, pageStart + 20).map((_, offset) => <button key={pageStart + offset} className="btn btn--soft btn--sm"
        aria-pressed={index === pageStart + offset} onClick={() => setPosition(pageStart + offset)}>{kind === "note" ? "笔记" : "回顾"} {pageStart + offset + 1}</button>)}
    </div>
    {values.length > 20 ? <div className={styles.row}>
      <button className="btn btn--soft btn--sm" disabled={pageStart === 0} onClick={() => setPosition(Math.max(0, pageStart - 20))}>上一组</button>
      <span>{pageStart + 1}–{Math.min(pageStart + 20, values.length)} / {values.length}</span>
      <button className="btn btn--soft btn--sm" disabled={pageStart + 20 >= values.length} onClick={() => setPosition(pageStart + 20)}>下一组</button>
    </div> : null}
    {note ? <article>
      <h3>{note.day} · {note.type}</h3>
      {note.body ? <pre className={styles.text}>{note.body}</pre> : <p className={styles.muted}>此笔记的正文为空。</p>}
      {note.attachments.map((attachment, i) => <div className={styles.file} key={attachment.file + i}>
        <div>{attachment.kind} · {attachment.file} · {attachment.bytes} bytes</div>
        <button className="btn btn--soft btn--sm" disabled={disabled} onClick={() => onAsset(attachment.file, false)}>下载原附件</button>
        {localPresentation(attachment.file, notebook.preview.files.get(attachment.file) ?? new Uint8Array()) ?
          <button className="btn btn--soft btn--sm" disabled={disabled} onClick={() => onAsset(attachment.file, true)}>在本机预览</button> :
          <span className={styles.muted}> 此格式仅提供原文件下载</span>}
        {attachment.transcript !== undefined ? <details><summary>原转写文本</summary><pre className={styles.text}>{attachment.transcript}</pre></details> : null}
      </div>)}
      <details><summary>笔记原始字段</summary><pre className={styles.metadata}>{JSON.stringify(note, null, 2)}</pre></details>
    </article> : null}
    {review ? <article>
      <h3>{review.period_kind === "day" ? "日回顾" : "周回顾"} · {review.start} — {review.end}</h3>
      <pre className={styles.text}>{review.body}</pre>
      <h4>原引用与当前副本</h4>
      {review.sources.map((citation, citationIndex) => {
        const found = notes.findIndex(note => note.namespace.toLowerCase() === citation.namespace.toLowerCase() && note.original_id.toLowerCase() === citation.memo_id.toLowerCase());
        const source = notes[found], current = source && source.day === citation.day && source.revision === citation.revision;
        return <div className={styles.file} key={citation.id + "\0" + citationIndex}>
          <div>{citation.day} · {source ? current ? "来源版本一致" : "来源已变化：当前副本不是原引用版本" : "来源未包含在此笔记本中"}</div>
          <button className="btn btn--soft btn--sm" disabled={!source} onClick={() => { setKind("note"); setPosition(found); }}>查看{current ? "来源" : "当前副本"}</button>
          <details><summary>原引用字段</summary><pre className={styles.metadata}>{JSON.stringify(citation, null, 2)}</pre></details>
        </div>;
      })}
      <button className="btn btn--soft btn--sm" disabled={disabled} onClick={() => onAsset(review.file, false)}>下载原回顾文件</button>
      <details><summary>回顾原始字段</summary><pre className={styles.metadata}>{JSON.stringify(review, null, 2)}</pre></details>
    </article> : null}
    {!values.length ? <p>此笔记本没有{kind === "note" ? "笔记" : "手动回顾"}。</p> : null}
    <details><summary>所有原文件（清单、records、raw、回顾与附件）</summary>
      {[{ path: "daypage-exchange.json", bytes: notebook.preview.manifestBytes.length }, ...notebook.preview.manifest.files].map(file => {
        const bytes = file.path === "daypage-exchange.json" ? notebook.preview.manifestBytes : notebook.preview.files.get(file.path);
        return <div className={styles.file} key={file.path}><div>{file.path} · {file.bytes} bytes</div>
          <button className="btn btn--soft btn--sm" disabled={disabled} onClick={() => onAsset(file.path, false)}>下载此原文件</button>
          {bytes && localPresentation(file.path, bytes) ? <button className="btn btn--soft btn--sm" disabled={disabled}
            onClick={() => onAsset(file.path, true)}>在本机预览</button> : null}
        </div>;
      })}
    </details>
  </section>;
}
