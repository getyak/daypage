"use client";

import { useState, useRef, useCallback, useEffect } from "react";

// ─── Types ────────────────────────────────────────────────────────────────────

export type Anchor = {
  section_idx: number;
  char_start: number;
  char_end: number;
  text: string;
};

export type Annotation = {
  id: string;
  page_id: string;
  anchor: Anchor;
  tag: string;
  note: string | null;
  created_at: string;
};

type ToolbarState = {
  visible: boolean;
  x: number;
  y: number;
  anchor: Anchor | null;
};

type CustomTagModal = {
  visible: boolean;
  anchor: Anchor | null;
};

const TAG_STYLES: Record<string, { background: string; color: string }> = {
  important: {
    background: "var(--accent-soft)",
    color: "var(--accent)",
  },
  questionable: {
    background: "var(--warning-soft)",
    color: "var(--warning)",
  },
};

function getTagStyle(tag: string) {
  return (
    TAG_STYLES[tag] ?? {
      background: "var(--surface-sunken)",
      color: "var(--fg-muted)",
    }
  );
}

// ─── Props ────────────────────────────────────────────────────────────────────

type Props = {
  pageId: string;
  initialAnnotations: Annotation[];
  children: React.ReactNode;
};

// ─── Component ────────────────────────────────────────────────────────────────

export default function AnnotationLayer({
  pageId,
  initialAnnotations,
  children,
}: Props) {
  const [annotationList, setAnnotationList] =
    useState<Annotation[]>(initialAnnotations);
  const [toolbar, setToolbar] = useState<ToolbarState>({
    visible: false,
    x: 0,
    y: 0,
    anchor: null,
  });
  const [customModal, setCustomModal] = useState<CustomTagModal>({
    visible: false,
    anchor: null,
  });
  const [customTagInput, setCustomTagInput] = useState("");
  const [customNoteInput, setCustomNoteInput] = useState("");
  const [saving, setSaving] = useState(false);

  const containerRef = useRef<HTMLDivElement>(null);
  const toolbarRef = useRef<HTMLDivElement>(null);

  // Close toolbar when clicking outside
  useEffect(() => {
    function onPointerDown(e: PointerEvent) {
      if (
        toolbarRef.current &&
        !toolbarRef.current.contains(e.target as Node)
      ) {
        setToolbar((t) => ({ ...t, visible: false, anchor: null }));
      }
    }
    document.addEventListener("pointerdown", onPointerDown);
    return () => document.removeEventListener("pointerdown", onPointerDown);
  }, []);

  // ─── Selection handler ───────────────────────────────────────────────────

  const handleMouseUp = useCallback(() => {
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed || !selection.rangeCount) return;

    const range = selection.getRangeAt(0);
    const selectedText = selection.toString().trim();
    if (!selectedText) return;

    const container = containerRef.current;
    if (!container) return;

    // Check selection is within our container
    if (!container.contains(range.commonAncestorContainer)) return;

    // Compute char_start / char_end relative to the container's text content
    const preRange = document.createRange();
    preRange.setStart(container, 0);
    preRange.setEnd(range.startContainer, range.startOffset);
    const char_start = preRange.toString().length;
    const char_end = char_start + range.toString().length;

    const anchor: Anchor = {
      section_idx: 0,
      char_start,
      char_end,
      text: selectedText,
    };

    // Position toolbar just above the selection
    const rect = range.getBoundingClientRect();
    const containerRect = container.getBoundingClientRect();
    const x = rect.left - containerRect.left + rect.width / 2;
    const y = rect.top - containerRect.top - 8; // 8px gap above selection

    setToolbar({ visible: true, x, y, anchor });
  }, []);

  // ─── Annotation actions ──────────────────────────────────────────────────

  async function createAnnotation(anchor: Anchor, tag: string, note?: string) {
    setSaving(true);
    try {
      const res = await fetch("/api/annotations", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ page_id: pageId, anchor, tag, note }),
      });
      if (!res.ok) throw new Error("Failed to create annotation");
      const created = (await res.json()) as Annotation;
      setAnnotationList((prev) => [...prev, created]);
      window.getSelection()?.removeAllRanges();
    } finally {
      setSaving(false);
      setToolbar({ visible: false, x: 0, y: 0, anchor: null });
    }
  }

  async function deleteAnnotation(id: string) {
    await fetch(`/api/annotations/${id}`, { method: "DELETE" });
    setAnnotationList((prev) => prev.filter((a) => a.id !== id));
  }

  function handleTagClick(tag: string) {
    if (!toolbar.anchor) return;
    void createAnnotation(toolbar.anchor, tag);
  }

  function handleCustomOpen() {
    setCustomModal({ visible: true, anchor: toolbar.anchor });
    setCustomTagInput("");
    setCustomNoteInput("");
    setToolbar((t) => ({ ...t, visible: false }));
  }

  async function handleCustomSubmit() {
    if (!customModal.anchor || !customTagInput.trim()) return;
    await createAnnotation(
      customModal.anchor,
      customTagInput.trim(),
      customNoteInput.trim() || undefined
    );
    setCustomModal({ visible: false, anchor: null });
  }

  // ─── Render highlighted body ─────────────────────────────────────────────

  // We wrap the children in a div and apply mark highlights as absolutely
  // positioned overlays driven by DOM range rects. This is the safest approach
  // when the body is rendered by react-markdown (we can't mutate its VDOM).
  // Highlights are transparent colored overlays; clicking them deletes the annotation.

  return (
    <div style={{ position: "relative" }}>
      {/* Body content */}
      <div
        ref={containerRef}
        onMouseUp={handleMouseUp}
        style={{ position: "relative" }}
      >
        {children}
        <HighlightOverlay
          containerRef={containerRef}
          annotations={annotationList}
          onDelete={deleteAnnotation}
        />
      </div>

      {/* Floating toolbar */}
      {toolbar.visible && toolbar.anchor && (
        <div
          ref={toolbarRef}
          style={{
            position: "absolute",
            left: toolbar.x,
            top: toolbar.y,
            transform: "translate(-50%, -100%)",
            zIndex: 50,
            background: "var(--surface-white)",
            border: "1px solid var(--accent-border)",
            borderRadius: "var(--radius-md)",
            boxShadow: "0 4px 16px rgba(0,0,0,0.12)",
            padding: "0.375rem 0.5rem",
            display: "flex",
            alignItems: "center",
            gap: "0.375rem",
            pointerEvents: "auto",
          }}
        >
          <button
            className="btn btn--soft btn--sm"
            style={{
              background: "var(--accent-soft)",
              color: "var(--accent)",
              fontSize: "0.75rem",
            }}
            disabled={saving}
            onMouseDown={(e) => {
              e.preventDefault(); // prevent selection clear
              handleTagClick("important");
            }}
          >
            Important
          </button>
          <button
            className="btn btn--soft btn--sm"
            style={{
              background: "var(--warning-soft)",
              color: "var(--warning)",
              fontSize: "0.75rem",
            }}
            disabled={saving}
            onMouseDown={(e) => {
              e.preventDefault();
              handleTagClick("questionable");
            }}
          >
            Questionable
          </button>
          <button
            className="btn btn--ghost btn--sm"
            style={{ fontSize: "0.75rem" }}
            disabled={saving}
            onMouseDown={(e) => {
              e.preventDefault();
              handleCustomOpen();
            }}
          >
            Custom…
          </button>
        </div>
      )}

      {/* Custom tag modal */}
      {customModal.visible && (
        <div
          style={{
            position: "fixed",
            inset: 0,
            zIndex: 100,
            background: "rgba(0,0,0,0.3)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
          }}
          onClick={(e) => {
            if (e.target === e.currentTarget)
              setCustomModal({ visible: false, anchor: null });
          }}
        >
          <div
            style={{
              background: "var(--surface-white)",
              border: "1px solid var(--accent-border)",
              borderRadius: "var(--radius-md)",
              padding: "1.25rem",
              width: "360px",
              display: "flex",
              flexDirection: "column",
              gap: "0.875rem",
            }}
          >
            <h3 className="ds-h2" style={{ margin: 0, fontSize: "1rem" }}>
              Custom tag
            </h3>
            <div style={{ display: "flex", flexDirection: "column", gap: "0.375rem" }}>
              <label
                htmlFor="custom-tag-input"
                className="ds-section-label"
                style={{ color: "var(--fg-subtle)" }}
              >
                Tag name
              </label>
              <input
                id="custom-tag-input"
                autoFocus
                value={customTagInput}
                onChange={(e) => setCustomTagInput(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") void handleCustomSubmit();
                  if (e.key === "Escape")
                    setCustomModal({ visible: false, anchor: null });
                }}
                placeholder="e.g. follow-up"
                style={{
                  padding: "0.4375rem 0.625rem",
                  border: "1px solid var(--accent-border)",
                  borderRadius: "var(--radius-sm)",
                  fontSize: "0.875rem",
                  background: "var(--surface-sunken)",
                  color: "var(--fg-primary)",
                  outline: "none",
                  width: "100%",
                }}
              />
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: "0.375rem" }}>
              <label
                className="ds-section-label"
                style={{ color: "var(--fg-subtle)" }}
              >
                Note (optional)
              </label>
              <textarea
                value={customNoteInput}
                onChange={(e) => setCustomNoteInput(e.target.value)}
                rows={3}
                placeholder="Add a note…"
                style={{
                  padding: "0.4375rem 0.625rem",
                  border: "1px solid var(--accent-border)",
                  borderRadius: "var(--radius-sm)",
                  fontSize: "0.875rem",
                  background: "var(--surface-sunken)",
                  color: "var(--fg-primary)",
                  outline: "none",
                  resize: "vertical",
                  width: "100%",
                  fontFamily: "inherit",
                }}
              />
            </div>
            <div
              style={{ display: "flex", gap: "0.5rem", justifyContent: "flex-end" }}
            >
              <button
                className="btn btn--ghost btn--sm"
                onClick={() => setCustomModal({ visible: false, anchor: null })}
              >
                Cancel
              </button>
              <button
                className="btn btn--primary btn--sm"
                disabled={!customTagInput.trim() || saving}
                onClick={() => void handleCustomSubmit()}
              >
                Save
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// ─── HighlightOverlay ─────────────────────────────────────────────────────────
// Renders colored `<mark>` overlays on top of the text by measuring DOM ranges.

type OverlayProps = {
  containerRef: React.RefObject<HTMLDivElement | null>;
  annotations: Annotation[];
  onDelete: (id: string) => void;
};

function HighlightOverlay({ containerRef, annotations, onDelete }: OverlayProps) {
  const [rects, setRects] = useState<
    Array<{ id: string; tag: string; clientRects: DOMRect[]; containerRect: DOMRect }>
  >([]);

  // Compute rects after render / resize
  useEffect(() => {
    function compute() {
      const container = containerRef.current;
      if (!container) return;

      const containerRect = container.getBoundingClientRect();
      const text = container.textContent ?? "";
      const results: typeof rects = [];

      for (const ann of annotations) {
        const anchor = ann.anchor as Anchor;
        if (
          anchor.char_start < 0 ||
          anchor.char_end > text.length ||
          anchor.char_start >= anchor.char_end
        )
          continue;

        const range = findRangeByCharOffsets(
          container,
          anchor.char_start,
          anchor.char_end
        );
        if (!range) continue;

        const clientRects = Array.from(range.getClientRects());
        if (clientRects.length === 0) continue;

        results.push({
          id: ann.id,
          tag: ann.tag,
          clientRects,
          containerRect,
        });
      }
      setRects(results);
    }

    compute();

    const observer = new ResizeObserver(compute);
    if (containerRef.current) observer.observe(containerRef.current);
    return () => observer.disconnect();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [annotations, containerRef]);

  /* eslint-disable react-hooks/refs */
  return (
    <>
      {rects.map(({ id, tag, clientRects, containerRect }) => {
        const style = getTagStyle(tag);
        return clientRects.map((rect, i) => (
          <mark
            key={`${id}-${i}`}
            data-tag={tag}
            title={`${tag} — click to remove`}
            onClick={() => onDelete(id)}
            style={{
              position: "fixed",
              top: rect.top,
              left: rect.left,
              width: rect.width,
              height: rect.height,
              background: style.background,
              opacity: 0.55,
              pointerEvents: "auto",
              cursor: "pointer",
              zIndex: 10,
              border: "none",
              display: "block",
              // Offset by container scroll — ref read is safe here (layout only)
              transform: `translate(0, ${containerRef.current?.scrollTop ?? 0}px)`,
            }}
            aria-label={`Annotation: ${tag}`}
          />
        ));
      })}
    </>
  );
  /* eslint-enable react-hooks/refs */
}

// ─── DOM helpers ──────────────────────────────────────────────────────────────

function findRangeByCharOffsets(
  root: Node,
  start: number,
  end: number
): Range | null {
  let charCount = 0;
  let startNode: Node | null = null;
  let startOffset = 0;
  let endNode: Node | null = null;
  let endOffset = 0;

  const iter = document.createNodeIterator(root, NodeFilter.SHOW_TEXT);
  let node: Node | null;

  while ((node = iter.nextNode())) {
    const len = (node as Text).length;
    if (!startNode && charCount + len > start) {
      startNode = node;
      startOffset = start - charCount;
    }
    if (!endNode && charCount + len >= end) {
      endNode = node;
      endOffset = end - charCount;
      break;
    }
    charCount += len;
  }

  if (!startNode || !endNode) return null;

  try {
    const range = document.createRange();
    range.setStart(startNode, startOffset);
    range.setEnd(endNode, endOffset);
    return range;
  } catch {
    return null;
  }
}
