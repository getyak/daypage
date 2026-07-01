"use client";

/**
 * Composer — DayPage Web 输入主体。
 *
 * 设计宪法（与 Mac App MacTodayView.Composer 同构）：
 *   - 视觉重心：文本框，不是工具栏
 *   - 边框：1px hairline，focus 时极轻 inner fill + 极轻 shadow，绝不用 accent stroke
 *   - 工具栏：底部 hairline 之下一条窄行，左侧只一个 [+]（全部高级输入收纳进去），右侧一个 send
 *   - Draft：输入即静默写 localStorage，无显式按钮，无 "Restored draft" 横幅
 *   - 字数：useMemo 缓存，不每键 split
 *   - 自动高度：CSS field-sizing: content，无 useEffect 写 height
 *
 * "+" 抽屉 (方案 a，全部收纳)：URL / Photo / File / Voice / Bookmarklet
 */

import {
  useCallback,
  useDeferredValue,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import {
  Plus,
  Send,
  Link2,
  Image as ImageIcon,
  FileText,
  Mic,
  Bookmark,
  X,
  Copy,
  Check,
  Bold,
  List,
  Hash,
} from "lucide-react";
import { Dialog } from "../_components/Dialog";

const DRAFT_KEY = "codex.add.draft.v1";
const URL_RE = /^https?:\/\//;
const isMac =
  typeof navigator !== "undefined" && /Mac|iPhone|iPad|iPod/.test(navigator.platform);

// ── types ────────────────────────────────────────────────────────────────────

interface MemoItem {
  id: string;
  body: string;
  type: string;
  compile_status: string;
  ingest_mode: string;
  created_at: string;
}

interface MemosCache {
  items: MemoItem[];
  next_cursor?: string | null;
  has_more?: boolean;
}

interface Attachment {
  id: string;
  file: File;
  previewUrl?: string;
}

async function createMemo(payload: { body: string; type: "text" | "url"; tempId: string }) {
  const res = await fetch("/api/memos", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ type: payload.type, body: payload.body, origin: "web" }),
  });
  if (!res.ok) {
    const data = (await res.json().catch(() => ({}))) as { error?: string };
    throw new Error(data.error ?? `Request failed (${res.status})`);
  }
  return res.json() as Promise<MemoItem>;
}

// ── component ────────────────────────────────────────────────────────────────

export function Composer() {
  const reduced = useReducedMotion();
  const [body, setBody] = useState("");
  const [focused, setFocused] = useState(false);
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [bookmarkletOpen, setBookmarkletOpen] = useState(false);
  // Slash menu: 只在当前行以 / 开头时浮现
  const [slashQuery, setSlashQuery] = useState<string | null>(null);
  const [slashIndex, setSlashIndex] = useState(0);

  const taRef = useRef<HTMLTextAreaElement>(null);
  const photoInputRef = useRef<HTMLInputElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const draftTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const queryClient = useQueryClient();

  // ── draft：静默 hydrate + debounce 保存 + 无 draft 时自动 focus (R5) ──────
  useEffect(() => {
    let hadDraft = false;
    try {
      const raw = localStorage.getItem(DRAFT_KEY);
      if (raw) {
        const parsed = JSON.parse(raw) as { text?: string };
        if (parsed.text) {
          setBody(parsed.text);
          hadDraft = true;
        }
      }
    } catch {
      /* ignore */
    }
    if (!hadDraft) {
      // 无草稿 → 自动 focus，让"打开页面 = 已经在写"
      queueMicrotask(() => taRef.current?.focus());
    }
  }, []);

  useEffect(() => {
    if (draftTimerRef.current) clearTimeout(draftTimerRef.current);
    draftTimerRef.current = setTimeout(() => {
      try {
        if (body.length === 0) {
          localStorage.removeItem(DRAFT_KEY);
        } else {
          localStorage.setItem(
            DRAFT_KEY,
            JSON.stringify({ text: body, mode: "text", attachmentRef: null, savedAt: new Date().toISOString() }),
          );
        }
      } catch {
        /* ignore */
      }
    }, 240);
    return () => {
      if (draftTimerRef.current) clearTimeout(draftTimerRef.current);
    };
  }, [body]);

  // ── 字数：useMemo 缓存 + useDeferredValue 让计数在空闲帧才更新 ─────────────
  // 这样按键的同步路径只触发 textarea 自身重渲，字数显示落到 idle frame。
  const deferredBody = useDeferredValue(body);
  const counts = useMemo(() => {
    const trimmed = deferredBody.trim();
    const chars = deferredBody.length;
    if (!trimmed) return { words: 0, chars };
    const words = trimmed.split(/\s+/).length;
    return { words, chars };
  }, [deferredBody]);

  const empty = body.trim().length === 0 && attachments.length === 0;

  // ── 附件 ────────────────────────────────────────────────────────────────
  const addFiles = useCallback((files: File[]) => {
    if (!files.length) return;
    const next: Attachment[] = files.map((file) => ({
      id: `${file.name}-${file.size}-${Math.random().toString(36).slice(2, 8)}`,
      file,
      previewUrl: file.type.startsWith("image/") ? URL.createObjectURL(file) : undefined,
    }));
    setAttachments((prev) => [...prev, ...next]);
  }, []);

  const removeAttachment = useCallback((id: string) => {
    setAttachments((prev) => {
      const target = prev.find((a) => a.id === id);
      if (target?.previewUrl) URL.revokeObjectURL(target.previewUrl);
      return prev.filter((a) => a.id !== id);
    });
  }, []);

  // 卸载时清 object URL
  const attachmentsRef = useRef<Attachment[]>([]);
  useEffect(() => {
    attachmentsRef.current = attachments;
  }, [attachments]);
  useEffect(() => {
    return () => {
      for (const a of attachmentsRef.current) {
        if (a.previewUrl) URL.revokeObjectURL(a.previewUrl);
      }
    };
  }, []);

  // ── 提交 ────────────────────────────────────────────────────────────────
  const mutation = useMutation({
    mutationFn: createMemo,
    // 网络/服务端瞬时失败时自动重试 1 次，指数退避 600ms（用户感知更少"发送失败"提示）
    retry: 1,
    retryDelay: (attempt) => 400 * 2 ** attempt,
    onMutate: (payload) => {
      const tempItem: MemoItem = {
        id: payload.tempId,
        body: payload.body,
        type: payload.type,
        compile_status: "pending",
        ingest_mode: "light",
        created_at: new Date().toISOString(),
      };
      queryClient.setQueryData<MemosCache>(["memos", "pending"], (old) => ({
        items: [tempItem, ...(old?.items ?? [])],
        next_cursor: old?.next_cursor ?? null,
        has_more: old?.has_more ?? false,
      }));
      return { tempId: payload.tempId };
    },
    onSuccess: (newMemo, _payload, ctx) => {
      setBody("");
      for (const a of attachments) {
        if (a.previewUrl) URL.revokeObjectURL(a.previewUrl);
      }
      setAttachments([]);
      try {
        localStorage.removeItem(DRAFT_KEY);
      } catch {
        /* ignore */
      }
      queryClient.setQueryData<MemosCache>(["memos", "pending"], (old) => {
        if (!old) return { items: [newMemo], next_cursor: null, has_more: false };
        const items = old.items.map((m) => (m.id === ctx?.tempId ? newMemo : m));
        return { ...old, items };
      });
    },
    onError: (_err, _payload, ctx) => {
      if (ctx?.tempId) {
        queryClient.setQueryData<MemosCache>(["memos", "pending"], (old) => {
          if (!old) return old;
          return { ...old, items: old.items.filter((m) => m.id !== ctx.tempId) };
        });
      }
    },
  });

  const handleSubmit = useCallback(() => {
    if (empty) return;
    const attachmentLines = attachments.map((a) => `file: ${a.file.name}`);
    const combined = [body.trim(), ...attachmentLines].filter(Boolean).join("\n");
    const type: "text" | "url" = URL_RE.test(combined.trim()) ? "url" : "text";
    const tempId = `temp-${crypto.randomUUID()}`;
    mutation.mutate({ body: combined, type, tempId });
  }, [empty, attachments, body, mutation]);

  const canSubmit = !empty && !mutation.isPending;

  // ── inline 编辑辅助 (与 Mac App MacTodayView.swift:229-248 同语义) ─────────
  const focusEditor = useCallback(() => taRef.current?.focus(), []);

  const insertAtCursor = useCallback((text: string) => {
    const ta = taRef.current;
    if (!ta) return;
    const start = ta.selectionStart ?? body.length;
    const end = ta.selectionEnd ?? body.length;
    const next = body.slice(0, start) + text + body.slice(end);
    setBody(next);
    // 下一帧把光标放到插入内容末尾
    queueMicrotask(() => {
      ta.focus();
      const pos = start + text.length;
      ta.setSelectionRange(pos, pos);
    });
  }, [body]);

  const wrapSelection = useCallback((marker: string) => {
    const ta = taRef.current;
    if (!ta) return;
    const start = ta.selectionStart ?? body.length;
    const end = ta.selectionEnd ?? body.length;
    const selected = body.slice(start, end);
    const wrapped = `${marker}${selected || "粗体"}${marker}`;
    const next = body.slice(0, start) + wrapped + body.slice(end);
    setBody(next);
    queueMicrotask(() => {
      ta.focus();
      const innerStart = start + marker.length;
      const innerEnd = innerStart + (selected.length || 2);
      ta.setSelectionRange(innerStart, innerEnd);
    });
  }, [body]);

  // ── Slash 命令清单 ───────────────────────────────────────────────────────
  // 注意：command 的 run 都用 ref/ callback 在下面用闭包绑定真实 handler，
  //       此处仅声明元数据
  type SlashCmd = {
    id: string;
    label: string;
    hint: string;
    keywords: string[];
    icon: ReactNode;
  };
  const SLASH_CMDS: SlashCmd[] = useMemo(
    () => [
      { id: "photo", label: "图片", hint: "上传图片", keywords: ["photo", "image", "img", "图片", "tu", "tp"], icon: <ImageIcon size={14} aria-hidden="true" /> },
      { id: "file", label: "文件", hint: "上传文件", keywords: ["file", "doc", "文件"], icon: <FileText size={14} aria-hidden="true" /> },
      { id: "voice", label: "语音", hint: "开始语音输入", keywords: ["voice", "mic", "audio", "语音"], icon: <Mic size={14} aria-hidden="true" /> },
      { id: "bookmarklet", label: "Bookmarklet", hint: "保存当前网页", keywords: ["bookmark", "bm"], icon: <Bookmark size={14} aria-hidden="true" /> },
      { id: "bold", label: "粗体", hint: "**文字**", keywords: ["bold", "b", "粗体"], icon: <Bold size={14} aria-hidden="true" /> },
      { id: "list", label: "列表", hint: "项目符号", keywords: ["list", "ul", "列表"], icon: <List size={14} aria-hidden="true" /> },
      { id: "tag", label: "标签", hint: "插入 #", keywords: ["tag", "hash", "标签"], icon: <Hash size={14} aria-hidden="true" /> },
    ],
    [],
  );

  const filteredSlashCmds = useMemo(() => {
    if (slashQuery === null) return SLASH_CMDS;
    const q = slashQuery.toLowerCase().trim();
    if (!q) return SLASH_CMDS;
    return SLASH_CMDS.filter(
      (c) =>
        c.label.toLowerCase().includes(q) ||
        c.keywords.some((k) => k.includes(q)),
    );
  }, [slashQuery, SLASH_CMDS]);

  const insertLinePrefix = useCallback((prefix: string) => {
    const ta = taRef.current;
    if (!ta) return;
    const start = ta.selectionStart ?? body.length;
    // 找到当前行起点
    const lineStart = body.lastIndexOf("\n", Math.max(0, start - 1)) + 1;
    const beforeLine = body.slice(0, lineStart);
    const rest = body.slice(lineStart);
    const next = beforeLine + prefix + rest;
    setBody(next);
    queueMicrotask(() => {
      ta.focus();
      const pos = start + prefix.length;
      ta.setSelectionRange(pos, pos);
    });
  }, [body]);

  // ── Slash：检测 / 触发、清除触发字符、执行命令 ───────────────────────────
  const detectSlash = useCallback((nextBody: string, caret: number) => {
    const lineStart = nextBody.lastIndexOf("\n", Math.max(0, caret - 1)) + 1;
    const segment = nextBody.slice(lineStart, caret);
    if (segment.startsWith("/")) {
      const afterSlash = segment.slice(1);
      const spaceIdx = afterSlash.indexOf(" ");
      const query = spaceIdx >= 0 ? afterSlash.slice(0, spaceIdx) : afterSlash;
      setSlashQuery(query);
      setSlashIndex(0);
    } else {
      setSlashQuery(null);
    }
  }, []);

  // 同步从当前 body 计算"清掉 / 触发段"后的 (nextBody, caret)。
  // 不直接 setBody — 让 runSlashCmd 把后续编辑也算完再一次性 commit，
  // 避免两次 setState 之间因闭包旧值互相覆盖。
  const computeStrippedSlash = useCallback((): { nextBody: string; caret: number } | null => {
    const ta = taRef.current;
    if (!ta) return null;
    const caret = ta.selectionStart ?? body.length;
    const lineStart = body.lastIndexOf("\n", Math.max(0, caret - 1)) + 1;
    const segment = body.slice(lineStart, caret);
    if (!segment.startsWith("/")) return { nextBody: body, caret };
    return {
      nextBody: body.slice(0, lineStart) + body.slice(caret),
      caret: lineStart,
    };
  }, [body]);

  const runSlashCmd = useCallback((cmd: { id: string }) => {
    setSlashQuery(null);

    // 先算清掉 / 触发段后的 (base, caret) — 纯函数，不 setState
    const stripped = computeStrippedSlash();
    if (!stripped) return;
    const ta = taRef.current;

    const commitAndFocus = (next: string, finalCaret: number) => {
      setBody(next);
      queueMicrotask(() => {
        ta?.focus();
        ta?.setSelectionRange(finalCaret, finalCaret);
      });
    };

    switch (cmd.id) {
      case "photo":
        commitAndFocus(stripped.nextBody, stripped.caret);
        photoInputRef.current?.click();
        return;
      case "file":
        commitAndFocus(stripped.nextBody, stripped.caret);
        fileInputRef.current?.click();
        return;
      case "voice":
        commitAndFocus(stripped.nextBody, stripped.caret);
        setDrawerOpen(true);
        return;
      case "bookmarklet":
        commitAndFocus(stripped.nextBody, stripped.caret);
        setBookmarkletOpen(true);
        return;
      case "bold": {
        // 在 stripped.caret 处插入 ****，光标落到中间
        const insertion = "**粗体**";
        const next =
          stripped.nextBody.slice(0, stripped.caret) +
          insertion +
          stripped.nextBody.slice(stripped.caret);
        commitAndFocus(next, stripped.caret + insertion.length);
        return;
      }
      case "list": {
        const insertion = "- ";
        const next =
          stripped.nextBody.slice(0, stripped.caret) +
          insertion +
          stripped.nextBody.slice(stripped.caret);
        commitAndFocus(next, stripped.caret + insertion.length);
        return;
      }
      case "tag": {
        const insertion = "#";
        const next =
          stripped.nextBody.slice(0, stripped.caret) +
          insertion +
          stripped.nextBody.slice(stripped.caret);
        commitAndFocus(next, stripped.caret + insertion.length);
        return;
      }
    }
  }, [computeStrippedSlash]);

  // ── render ──────────────────────────────────────────────────────────────
  return (
    <motion.div
      onDragOver={(e) => e.preventDefault()}
      onDrop={(e) => {
        e.preventDefault();
        const files = Array.from(e.dataTransfer.files);
        addFiles(files);
      }}
      // 微动效：focus 时整体极轻"呼吸"，让"开始写"有物理反馈
      animate={
        reduced
          ? undefined
          : { scale: focused ? 1.0035 : 1, y: focused ? -1 : 0 }
      }
      transition={{ type: "spring", stiffness: 360, damping: 32, mass: 0.6 }}
      style={{
        background: "var(--surface, #fff)",
        border: `1px solid rgba(43, 40, 34, ${focused ? 0.12 : 0.08})`,
        borderRadius: 12,
        boxShadow: focused
          ? "0 4px 16px -8px rgba(43, 40, 34, 0.12)"
          : "0 0 0 transparent",
        transition: "border-color 180ms ease-out, box-shadow 180ms ease-out",
        overflow: "hidden",
      }}
    >
      {/* Editor */}
      <div style={{ position: "relative" }}>
        <textarea
          ref={taRef}
          value={body}
          onChange={(e) => {
            const next = e.target.value;
            setBody(next);
            detectSlash(next, e.target.selectionStart ?? next.length);
          }}
          onFocus={() => setFocused(true)}
          onBlur={() => {
            setFocused(false);
            // 失焦关闭 slash menu（用 setTimeout 让 menu 内 click 还能命中）
            setTimeout(() => setSlashQuery(null), 120);
          }}
          onKeyDown={(e) => {
            // Slash menu 导航
            if (slashQuery !== null && filteredSlashCmds.length > 0) {
              if (e.key === "ArrowDown") {
                e.preventDefault();
                setSlashIndex((i) => (i + 1) % filteredSlashCmds.length);
                return;
              }
              if (e.key === "ArrowUp") {
                e.preventDefault();
                setSlashIndex((i) => (i - 1 + filteredSlashCmds.length) % filteredSlashCmds.length);
                return;
              }
              if (e.key === "Enter" && !e.metaKey && !e.ctrlKey) {
                e.preventDefault();
                runSlashCmd(filteredSlashCmds[slashIndex]!);
                return;
              }
              if (e.key === "Escape") {
                e.preventDefault();
                setSlashQuery(null);
                return;
              }
              if (e.key === "Tab") {
                e.preventDefault();
                runSlashCmd(filteredSlashCmds[slashIndex]!);
                return;
              }
            }
            if ((e.metaKey || e.ctrlKey) && e.key === "Enter" && canSubmit) {
              e.preventDefault();
              handleSubmit();
            }
          }}
          placeholder="What's on your mind?"
          rows={3}
          style={{
            // field-sizing: content 让 textarea 跟随内容自适应（Chrome 123+ / Safari 17+）
            // TS 类型未覆盖这个较新的 CSS 字段
            fieldSizing: "content",
            width: "100%",
            minHeight: 96,
            maxHeight: 320,
            padding: "16px 18px",
            border: "none",
            outline: "none",
            resize: "none",
            background: "transparent",
            font: "15px/1.65 var(--font-sans, system-ui)",
            color: "var(--fg-primary, #2B2822)",
            caretColor: "var(--accent, #5D3000)",
          } as React.CSSProperties}
        />
      </div>

      {/* 附件预览（仅当有附件） */}
      {attachments.length > 0 && (
        <div
          style={{
            display: "flex",
            flexWrap: "wrap",
            gap: 8,
            padding: "0 18px 12px",
          }}
        >
          <AnimatePresence initial={false}>
          {attachments.map((a, idx) => (
            <motion.div
              key={a.id}
              layout
              initial={reduced ? false : { opacity: 0, y: 4, scale: 0.96 }}
              animate={{ opacity: 1, y: 0, scale: 1 }}
              exit={reduced ? { opacity: 0 } : { opacity: 0, scale: 0.94 }}
              transition={{
                duration: 0.18,
                ease: [0.22, 1, 0.36, 1],
                delay: reduced ? 0 : Math.min(idx * 0.025, 0.12),
              }}
              style={{
                display: "inline-flex",
                alignItems: "center",
                gap: 8,
                padding: "6px 8px 6px 6px",
                border: "1px solid var(--border-subtle, #EDE8DF)",
                borderRadius: 8,
                background: "var(--surface-2, #FAF8F6)",
                maxWidth: 240,
              }}
            >
              {a.previewUrl ? (
                /* eslint-disable-next-line @next/next/no-img-element */
                <img
                  src={a.previewUrl}
                  alt={a.file.name}
                  style={{
                    width: 28,
                    height: 28,
                    borderRadius: 4,
                    objectFit: "cover",
                  }}
                />
              ) : (
                <FileText size={14} aria-hidden="true" />
              )}
              <span
                style={{
                  fontSize: 12,
                  color: "var(--fg-secondary, #555)",
                  overflow: "hidden",
                  textOverflow: "ellipsis",
                  whiteSpace: "nowrap",
                  flex: 1,
                }}
                title={a.file.name}
              >
                {a.file.name}
              </span>
              <button
                type="button"
                aria-label={`Remove ${a.file.name}`}
                onClick={() => removeAttachment(a.id)}
                style={{
                  border: "none",
                  background: "transparent",
                  cursor: "pointer",
                  display: "inline-flex",
                  alignItems: "center",
                  color: "var(--fg-subtle, #888)",
                  padding: 2,
                }}
              >
                <X size={12} aria-hidden="true" />
              </button>
            </motion.div>
          ))}
          </AnimatePresence>
        </div>
      )}

      {/* Slash 命令面板：仅在 / 触发且有匹配时浮出 */}
      <AnimatePresence>
      {slashQuery !== null && filteredSlashCmds.length > 0 && (
        <motion.div
          role="listbox"
          aria-label="Slash 命令"
          initial={reduced ? false : { opacity: 0, y: -4, scale: 0.985 }}
          animate={{ opacity: 1, y: 0, scale: 1 }}
          exit={reduced ? { opacity: 0 } : { opacity: 0, y: -4, scale: 0.985 }}
          transition={{ duration: 0.14, ease: [0.22, 1, 0.36, 1] }}
          style={{
            margin: "0 12px",
            border: "1px solid var(--border-subtle, #EDE8DF)",
            borderRadius: 10,
            background: "var(--surface, #fff)",
            boxShadow: "0 8px 24px -12px rgba(43, 40, 34, 0.18)",
            padding: 4,
            display: "flex",
            flexDirection: "column",
            maxHeight: 280,
            overflowY: "auto",
            transformOrigin: "top center",
          }}
        >
          {filteredSlashCmds.map((cmd, i) => {
            const active = i === slashIndex;
            return (
              <motion.button
                key={cmd.id}
                type="button"
                role="option"
                aria-selected={active}
                onMouseDown={(e) => {
                  // 防止 textarea blur 抢先关闭菜单
                  e.preventDefault();
                  runSlashCmd(cmd);
                }}
                onMouseEnter={() => setSlashIndex(i)}
                initial={reduced ? false : { opacity: 0, x: -4 }}
                animate={{ opacity: 1, x: 0 }}
                transition={{
                  duration: 0.12,
                  delay: reduced ? 0 : Math.min(i * 0.018, 0.1),
                }}
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 10,
                  padding: "8px 10px",
                  border: "none",
                  borderRadius: 6,
                  background: active ? "var(--accent-soft, #F5EDE3)" : "transparent",
                  color: active ? "var(--accent, #5D3000)" : "var(--fg-primary, #2B2822)",
                  cursor: "pointer",
                  textAlign: "left",
                  fontSize: 13,
                  transition: "background 80ms",
                }}
              >
                <span
                  aria-hidden="true"
                  style={{
                    width: 22,
                    height: 22,
                    display: "inline-flex",
                    alignItems: "center",
                    justifyContent: "center",
                    color: active ? "var(--accent, #5D3000)" : "var(--fg-subtle, #888)",
                  }}
                >
                  {cmd.icon}
                </span>
                <span style={{ flex: 1, fontWeight: 500 }}>{cmd.label}</span>
                <span
                  style={{
                    fontSize: 11,
                    color: "var(--fg-subtle, #888)",
                    fontFamily: "var(--font-mono, monospace)",
                  }}
                >
                  {cmd.hint}
                </span>
              </motion.button>
            );
          })}
        </motion.div>
      )}
      </AnimatePresence>

      {/* Toolbar */}
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 4,
          padding: "6px 8px",
          borderTop: "1px solid rgba(43, 40, 34, 0.05)",
        }}
      >
        <ToolbarIconButton
          aria-label="更多输入方式"
          tooltip="附件 / 链接 / 语音 / Bookmarklet"
          onClick={() => setDrawerOpen((v) => !v)}
          active={drawerOpen}
        >
          <Plus size={16} strokeWidth={1.8} aria-hidden="true" />
        </ToolbarIconButton>

        {/* divider */}
        <span
          aria-hidden="true"
          style={{
            width: 1,
            height: 14,
            background: "rgba(43, 40, 34, 0.08)",
            margin: "0 4px",
          }}
        />

        <ToolbarIconButton
          aria-label="粗体"
          tooltip="加粗（**文字**）"
          onClick={() => {
            wrapSelection("**");
            focusEditor();
          }}
        >
          <Bold size={14} strokeWidth={1.9} aria-hidden="true" />
        </ToolbarIconButton>

        <ToolbarIconButton
          aria-label="项目符号列表"
          tooltip="项目符号列表"
          onClick={() => {
            insertLinePrefix("- ");
            focusEditor();
          }}
        >
          <List size={14} strokeWidth={1.8} aria-hidden="true" />
        </ToolbarIconButton>

        <ToolbarIconButton
          aria-label="插入标签"
          tooltip="插入 #标签"
          onClick={() => {
            insertAtCursor("#");
            focusEditor();
          }}
        >
          <Hash size={14} strokeWidth={1.8} aria-hidden="true" />
        </ToolbarIconButton>

        <div style={{ flex: 1 }} />

        {/* 状态栏：错误 / hint / 字数 */}
        {mutation.isError ? (
          <button
            type="button"
            onClick={handleSubmit}
            style={{
              fontSize: 11,
              fontFamily: "var(--font-mono, monospace)",
              color: "var(--error, #C53030)",
              background: "transparent",
              border: "none",
              cursor: "pointer",
              padding: "0 8px",
            }}
          >
            发送失败 · 点击重试
          </button>
        ) : focused && canSubmit ? (
          <span
            style={{
              fontSize: 11,
              fontFamily: "var(--font-mono, monospace)",
              color: "var(--fg-subtle, #888)",
              letterSpacing: 0.2,
              padding: "0 8px",
            }}
            aria-live="polite"
          >
            {counts.words} 字 · {isMac ? "⌘↩" : "Ctrl+↩"} 发送
          </span>
        ) : counts.chars > 0 ? (
          <span
            style={{
              fontSize: 11,
              fontFamily: "var(--font-mono, monospace)",
              color: "var(--fg-subtle, #888)",
              letterSpacing: 0.2,
              padding: "0 8px",
            }}
          >
            {counts.words} 字
          </span>
        ) : null}

        <SendButton onClick={handleSubmit} disabled={!canSubmit} pending={mutation.isPending} />
      </div>

      {/* "+" 抽屉：URL / Photo / File / Voice / Bookmarklet */}
      <AnimatePresence initial={false}>
      {drawerOpen && (
        <motion.div
          role="menu"
          initial={reduced ? false : { opacity: 0, height: 0 }}
          animate={{ opacity: 1, height: "auto" }}
          exit={reduced ? { opacity: 0 } : { opacity: 0, height: 0 }}
          transition={{ duration: 0.18, ease: [0.22, 1, 0.36, 1] }}
          style={{
            display: "flex",
            flexWrap: "wrap",
            gap: 6,
            padding: "8px 10px 12px",
            borderTop: "1px solid rgba(43, 40, 34, 0.05)",
            background: "var(--surface-2, #FAF8F6)",
            overflow: "hidden",
          }}
        >
          <DrawerChip
            icon={<Link2 size={13} aria-hidden="true" />}
            label="粘贴链接"
            onClick={() => {
              setDrawerOpen(false);
              taRef.current?.focus();
            }}
          />
          <DrawerChip
            icon={<ImageIcon size={13} aria-hidden="true" />}
            label="图片"
            onClick={() => {
              setDrawerOpen(false);
              photoInputRef.current?.click();
            }}
          />
          <DrawerChip
            icon={<FileText size={13} aria-hidden="true" />}
            label="文件"
            onClick={() => {
              setDrawerOpen(false);
              fileInputRef.current?.click();
            }}
          />
          <VoiceDrawerChip
            onTranscript={(t) => {
              setBody((prev) => (prev ? prev + " " + t : t));
              taRef.current?.focus();
            }}
          />
          <DrawerChip
            icon={<Bookmark size={13} aria-hidden="true" />}
            label="Bookmarklet"
            onClick={() => {
              setDrawerOpen(false);
              setBookmarkletOpen(true);
            }}
          />
        </motion.div>
      )}
      </AnimatePresence>

      {/* 隐藏 input */}
      <input
        ref={photoInputRef}
        type="file"
        accept="image/*"
        style={{ display: "none" }}
        onChange={(e) => {
          const files = Array.from(e.target.files ?? []);
          addFiles(files);
          if (e.target) e.target.value = "";
        }}
      />
      <input
        ref={fileInputRef}
        type="file"
        style={{ display: "none" }}
        onChange={(e) => {
          const files = Array.from(e.target.files ?? []);
          addFiles(files);
          if (e.target) e.target.value = "";
        }}
      />

      {/* Bookmarklet dialog */}
      <BookmarkletDialog open={bookmarkletOpen} onClose={() => setBookmarkletOpen(false)} />
    </motion.div>
  );
}

// ── sub: SendButton ─────────────────────────────────────────────────────────

function SendButton({
  onClick,
  disabled,
  pending,
}: {
  onClick: () => void;
  disabled: boolean;
  pending: boolean;
}) {
  const reduced = useReducedMotion();
  return (
    <motion.button
      type="button"
      onClick={onClick}
      disabled={disabled}
      aria-label={pending ? "发送中" : "发送 (Cmd+Enter)"}
      whileHover={reduced || disabled ? undefined : { scale: 1.06 }}
      whileTap={reduced || disabled ? undefined : { scale: 0.92 }}
      animate={
        reduced
          ? undefined
          : pending
            ? { rotate: [0, 8, -6, 0] }
            : { rotate: 0 }
      }
      transition={{ type: "spring", stiffness: 480, damping: 18, mass: 0.5 }}
      style={{
        width: 28,
        height: 28,
        border: "none",
        borderRadius: 7,
        background: disabled ? "rgba(43, 40, 34, 0.06)" : "var(--accent, #5D3000)",
        color: disabled ? "rgba(43, 40, 34, 0.25)" : "#FAF8F6",
        cursor: disabled ? "not-allowed" : "pointer",
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
      }}
    >
      <Send size={12} strokeWidth={2.2} aria-hidden="true" />
    </motion.button>
  );
}

// ── sub: ToolbarIconButton ──────────────────────────────────────────────────

function ToolbarIconButton({
  children,
  onClick,
  active,
  tooltip,
  ...rest
}: {
  children: ReactNode;
  onClick: () => void;
  active?: boolean;
  tooltip?: string;
  "aria-label": string;
}) {
  const [hover, setHover] = useState(false);
  return (
    <button
      type="button"
      onClick={onClick}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      title={tooltip}
      style={{
        width: 28,
        height: 28,
        border: "none",
        background:
          active || hover ? "rgba(43, 40, 34, 0.06)" : "transparent",
        borderRadius: 6,
        cursor: "pointer",
        color:
          active ? "var(--accent, #5D3000)" : "rgba(43, 40, 34, 0.55)",
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        transition: "background 120ms, color 120ms",
      }}
      {...rest}
    >
      {children}
    </button>
  );
}

// ── sub: DrawerChip ─────────────────────────────────────────────────────────

function DrawerChip({
  icon,
  label,
  onClick,
}: {
  icon: ReactNode;
  label: string;
  onClick: () => void;
}) {
  const [hover, setHover] = useState(false);
  return (
    <button
      type="button"
      onClick={onClick}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: 6,
        padding: "6px 10px",
        border: "1px solid var(--border-subtle, #EDE8DF)",
        borderRadius: 999,
        background: hover ? "var(--surface, #fff)" : "transparent",
        fontSize: 12,
        color: "var(--fg-secondary, #555)",
        cursor: "pointer",
        transition: "background 120ms",
      }}
    >
      {icon}
      {label}
    </button>
  );
}

// ── sub: Voice drawer chip (Speech API) ─────────────────────────────────────

function VoiceDrawerChip({ onTranscript }: { onTranscript: (t: string) => void }) {
  const [supported, setSupported] = useState(false);
  const [recording, setRecording] = useState(false);
  const srRef = useRef<unknown>(null);

  useEffect(() => {
    if (typeof window === "undefined") return;
    setSupported(
      "SpeechRecognition" in window || "webkitSpeechRecognition" in window,
    );
  }, []);

  const handleClick = useCallback(() => {
    if (!supported) return;
    type SR = {
      continuous: boolean;
      interimResults: boolean;
      lang: string;
      onresult: ((e: { results: { length: number;[i: number]: { isFinal: boolean; 0: { transcript: string } } } }) => void) | null;
      onerror: (() => void) | null;
      onend: (() => void) | null;
      start: () => void;
      stop: () => void;
    };
    if (recording) {
      (srRef.current as SR | null)?.stop();
      setRecording(false);
      return;
    }
    const w = window as unknown as Record<string, unknown>;
    const Ctor = (w["SpeechRecognition"] ?? w["webkitSpeechRecognition"]) as
      | (new () => SR)
      | undefined;
    if (!Ctor) return;
    const sr = new Ctor();
    sr.continuous = true;
    sr.interimResults = false;
    sr.lang = "zh-CN";
    sr.onresult = (event) => {
      let transcript = "";
      for (let i = 0; i < event.results.length; i++) {
        if (event.results[i]?.isFinal) {
          transcript += event.results[i]?.[0]?.transcript ?? "";
        }
      }
      if (transcript) onTranscript(transcript.trim());
    };
    sr.onerror = () => setRecording(false);
    sr.onend = () => setRecording(false);
    srRef.current = sr;
    try {
      sr.start();
      setRecording(true);
    } catch {
      setRecording(false);
    }
  }, [recording, supported, onTranscript]);

  const [hover, setHover] = useState(false);
  return (
    <button
      type="button"
      onClick={handleClick}
      disabled={!supported}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      title={supported ? (recording ? "停止录音" : "开始语音输入") : "此浏览器不支持语音输入"}
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: 6,
        padding: "6px 10px",
        border: "1px solid var(--border-subtle, #EDE8DF)",
        borderRadius: 999,
        background: recording
          ? "var(--error-soft, #FFF1F1)"
          : hover && supported
            ? "var(--surface, #fff)"
            : "transparent",
        fontSize: 12,
        color: recording
          ? "var(--error, #C53030)"
          : supported
            ? "var(--fg-secondary, #555)"
            : "var(--fg-subtle, #888)",
        cursor: supported ? "pointer" : "not-allowed",
        opacity: supported ? 1 : 0.5,
        transition: "background 120ms",
      }}
    >
      <Mic size={13} aria-hidden="true" />
      {recording ? "录音中…" : "语音"}
    </button>
  );
}

// ── sub: BookmarkletDialog ──────────────────────────────────────────────────

const BOOKMARKLET_SOURCE = `javascript:void(open('http://localhost:13000/add?url='+encodeURIComponent(location.href)+'&title='+encodeURIComponent(document.title)))`;

function BookmarkletDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [copied, setCopied] = useState(false);
  const handleCopy = useCallback(async () => {
    try {
      await navigator.clipboard.writeText(BOOKMARKLET_SOURCE);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      /* ignore */
    }
  }, []);
  return (
    <Dialog open={open} onClose={onClose} title="Save to DayPage — Bookmarklet">
      <p style={{ margin: "0 0 1rem", fontSize: 14, color: "var(--fg-secondary, #555)" }}>
        把下面的链接拖到浏览器书签栏。在任意网页上点一下就能把它存进 DayPage。
      </p>
      <div style={{ marginBottom: "1rem", textAlign: "center" }}>
        {/* eslint-disable-next-line @next/next/no-html-link-for-pages */}
        <a
          href={BOOKMARKLET_SOURCE}
          draggable
          onClick={(e) => e.preventDefault()}
          style={{
            display: "inline-block",
            padding: "8px 16px",
            background: "var(--accent-soft, #F5EDE3)",
            color: "var(--accent, #5D3000)",
            borderRadius: 6,
            fontWeight: 600,
            fontSize: 14,
            textDecoration: "none",
            border: "2px dashed var(--accent, #5D3000)",
            cursor: "grab",
          }}
        >
          📎 Save to DayPage
        </a>
      </div>
      <div style={{ position: "relative", marginBottom: "0.75rem" }}>
        <pre
          style={{
            margin: 0,
            padding: "10px 12px",
            background: "var(--surface-2, #FAF8F6)",
            borderRadius: 6,
            fontSize: 12,
            overflowX: "auto",
            wordBreak: "break-all",
            whiteSpace: "pre-wrap",
            color: "var(--fg-secondary, #555)",
            paddingRight: 40,
          }}
        >
          {BOOKMARKLET_SOURCE}
        </pre>
        <button
          type="button"
          onClick={handleCopy}
          aria-label="复制 Bookmarklet 源码"
          style={{
            position: "absolute",
            top: 6,
            right: 6,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            background: "var(--surface, #fff)",
            border: "1px solid var(--border-subtle, #EDE8DF)",
            borderRadius: 6,
            cursor: "pointer",
            padding: 4,
            color: copied ? "var(--accent, #5D3000)" : "var(--fg-subtle, #888)",
          }}
        >
          {copied ? <Check size={14} /> : <Copy size={14} />}
        </button>
      </div>
      {copied && (
        <p style={{ margin: 0, fontSize: 12, color: "var(--accent, #5D3000)" }}>
          已复制
        </p>
      )}
    </Dialog>
  );
}
