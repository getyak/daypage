"use client";

import { useRef, useState, useCallback, useEffect, useId } from "react";
import {
  Camera,
  Share2,
  MoreHorizontal,
  Loader2,
  AlertCircle,
  RefreshCw,
} from "lucide-react";
import { applyRubberBand, snapTarget } from "@/lib/gestures/rubberBand";

const REVEAL_WIDTH = 132;
const DRAG_TAP_THRESHOLD = 6;

export type CompileStatus = "pending" | "running" | "done" | "failed";

export type MemoCardData = {
  id: string;
  created_at: string;
  body: string;
  type: "text" | "voice" | "photo" | "mixed" | "url" | "file";
  photo_url?: string | null;
  compile_status?: CompileStatus;
  compile_step?: string | null;
  compile_error?: string | null;
};

type Props = {
  memo: MemoCardData;
  onTap?: (id: string) => void;
  onShare?: (id: string) => void;
  onMore?: (id: string) => void;
  /** Whether the Inngest compile pipeline is reachable (false in dev w/o key). */
  serviceConnected?: boolean;
  /** Called when the user retries a failed memo. */
  onRetry?: (id: string) => void;
};

function formatTime(isoString: string): string {
  const d = new Date(isoString);
  const hh = String(d.getHours()).padStart(2, "0");
  const mm = String(d.getMinutes()).padStart(2, "0");
  return `${hh}·${mm}`;
}

export function MemoCard({
  memo,
  onTap,
  onShare,
  onMore,
  serviceConnected = true,
  onRetry,
}: Props) {
  const [tx, setTx] = useState(0);
  const [dragging, setDragging] = useState(false);
  const dragRef = useRef({ startX: 0, startTx: 0, moved: 0, active: false });
  const menuId = useId();

  const hasPhoto =
    (memo.type === "photo" || memo.type === "mixed") && memo.photo_url;
  const isMixed = memo.type === "mixed";

  // ── Pointer gesture ──────────────────────────────────────────────

  const onPointerDown = useCallback(
    (e: React.PointerEvent<HTMLDivElement>) => {
      if ((e.target as Element).closest("[data-drawer]")) return;
      dragRef.current = { startX: e.clientX, startTx: tx, moved: 0, active: true };
      setDragging(true);
      (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    },
    [tx]
  );

  const onPointerMove = useCallback(
    (e: React.PointerEvent<HTMLDivElement>) => {
      if (!dragRef.current.active) return;
      const delta = e.clientX - dragRef.current.startX;
      dragRef.current.moved = Math.abs(delta);
      const raw = dragRef.current.startTx + delta;
      setTx(applyRubberBand(raw));
    },
    []
  );

  const onPointerUp = useCallback(() => {
    if (!dragRef.current.active) return;
    dragRef.current.active = false;
    setDragging(false);
    setTx(snapTarget(tx));
  }, [tx]);

  // ── Click / tap ──────────────────────────────────────────────────

  const handleCardClick = useCallback(() => {
    if (dragRef.current.moved > DRAG_TAP_THRESHOLD) return;
    if (tx !== 0) {
      setTx(0);
      return;
    }
    onTap?.(memo.id);
  }, [tx, memo.id, onTap]);

  // ── Keyboard a11y ────────────────────────────────────────────────

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent<HTMLDivElement>) => {
      if (e.key === "Enter" && !e.shiftKey) {
        if (tx !== 0) {
          setTx(0);
        } else {
          onTap?.(memo.id);
        }
      }
    },
    [tx, memo.id, onTap]
  );

  // ── Context menu (a11y: expose Share / More) ─────────────────────

  const handleContextMenu = useCallback(
    (e: React.MouseEvent) => {
      // Native <menu> context is declared below; default browser context menu
      // carries the <menu> element in supporting browsers. No extra handling needed.
      void e; // mark used
    },
    []
  );

  const drawerOpacity = Math.min(1, Math.max(0, (-tx - 8) / (REVEAL_WIDTH - 8)));

  return (
    <div style={{ position: "relative", overflow: "hidden", borderRadius: 18 }}>
      {/* Action drawer — always in DOM, revealed by translateX.
          Design geometry (app.jsx:486-502): 132px drawer, gap:8 between the
          two inset action chips, padding 8px on top/right/bottom (0 left so the
          card edge meets the chips), each chip borderRadius:14. */}
      <div
        data-drawer
        aria-hidden="true"
        style={{
          position: "absolute",
          right: 0,
          top: 0,
          bottom: 0,
          width: REVEAL_WIDTH,
          display: "flex",
          gap: 8,
          padding: "8px 8px 8px 0",
          opacity: drawerOpacity,
          zIndex: 1,
        }}
      >
        {/* MORE — sunken */}
        <button
          type="button"
          aria-label="更多操作"
          onClick={(e) => {
            e.stopPropagation();
            onMore?.(memo.id);
          }}
          style={{
            flex: 1,
            border: "none",
            borderRadius: 14,
            cursor: "pointer",
            display: "flex",
            flexDirection: "column",
            alignItems: "center",
            justifyContent: "center",
            gap: 4,
            background: "var(--surface-sunken)",
            color: "var(--fg-primary)",
            fontFamily: "var(--font-family-mono), monospace",
            fontSize: 9,
            letterSpacing: "0.13em",
            textTransform: "uppercase",
            fontWeight: 700,
          }}
        >
          <MoreHorizontal size={17} strokeWidth={1.8} />
          MORE
        </button>

        {/* SHARE — accent */}
        <button
          type="button"
          aria-label="分享"
          onClick={(e) => {
            e.stopPropagation();
            onShare?.(memo.id);
          }}
          style={{
            flex: 1,
            border: "none",
            borderRadius: 14,
            cursor: "pointer",
            display: "flex",
            flexDirection: "column",
            alignItems: "center",
            justifyContent: "center",
            gap: 4,
            background: "var(--accent)",
            color: "#FAF8F6",
            fontFamily: "var(--font-family-mono), monospace",
            fontSize: 9,
            letterSpacing: "0.13em",
            textTransform: "uppercase",
            fontWeight: 700,
          }}
        >
          <Share2 size={17} strokeWidth={1.8} />
          SHARE
        </button>
      </div>

      {/* Card face */}
      <div
        role="article"
        tabIndex={0}
        aria-describedby={menuId}
        style={{
          position: "relative",
          zIndex: 2,
          borderRadius: 18,
          background: "var(--surface-white)",
          border: "0.5px solid var(--border-subtle)",
          boxShadow: "var(--shadow-card)",
          overflow: "hidden",
          cursor: "pointer",
          userSelect: "none",
          WebkitUserSelect: "none",
          touchAction: "pan-y",
          transform: `translateX(${tx}px)`,
          transition: dragging ? "none" : "transform 280ms cubic-bezier(.2,.8,.2,1)",
        }}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerUp}
        onClick={handleCardClick}
        onKeyDown={handleKeyDown}
        onContextMenu={handleContextMenu}
      >
        {/* Photo (aspect-ratio 4:5, no radius) */}
        {hasPhoto && (
          <div
            style={{
              aspectRatio: "4 / 5",
              width: "100%",
              overflow: "hidden",
              borderRadius: 0,
              flexShrink: 0,
            }}
          >
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              src={memo.photo_url!}
              alt=""
              aria-hidden="true"
              style={{ width: "100%", height: "100%", objectFit: "cover", display: "block" }}
            />
          </div>
        )}

        {/* Body block */}
        <div
          style={{
            padding: hasPhoto ? "16px 20px 18px" : "18px 20px 20px",
          }}
        >
          {/* Top row: time + (mixed) dots + camera icon */}
          <div
            style={{
              display: "flex",
              alignItems: "center",
              gap: 7,
              marginBottom: 10,
            }}
          >
            <span
              aria-label={`记录时间 ${formatTime(memo.created_at)}`}
              style={{
                fontFamily: "var(--font-family-mono), monospace",
                fontSize: 11,
                letterSpacing: "0.04em",
                color: "var(--fg-subtle)",
                fontWeight: 500,
              }}
            >
              {formatTime(memo.created_at)}
            </span>

            {isMixed && (
              <DotGrid aria-hidden />
            )}

            {(memo.type === "photo" || memo.type === "mixed") && (
              <Camera
                size={13}
                strokeWidth={1.7}
                aria-hidden="true"
                style={{ color: "var(--fg-subtle)", flexShrink: 0 }}
              />
            )}
          </div>

          {/* Body text — clamp 5 lines */}
          <BodyText body={memo.body} />

          {/* Compile status — US-002 */}
          <CompileStatusBar
            memo={memo}
            serviceConnected={serviceConnected}
            onRetry={onRetry}
          />
        </div>
      </div>

      {/* Native context menu for a11y (Share / More) */}
      <menu id={menuId} style={{ display: "none" }}>
        <li>
          <button type="button" onClick={() => onShare?.(memo.id)}>
            分享
          </button>
        </li>
        <li>
          <button type="button" onClick={() => onMore?.(memo.id)}>
            更多操作
          </button>
        </li>
      </menu>
    </div>
  );
}

// 3×3 dot grid for mixed entries
function DotGrid({ ...rest }: React.HTMLAttributes<SVGElement>) {
  return (
    <svg width="9" height="9" viewBox="0 0 9 9" fill="none" {...rest}>
      {[0, 3, 6].map((row) =>
        [0, 3, 6].map((col) => (
          <circle
            key={`${row}-${col}`}
            cx={col + 1.5}
            cy={row + 1.5}
            r={1}
            fill="var(--fg-subtle)"
          />
        ))
      )}
    </svg>
  );
}

// Compile status footer: queued / running(step) / done / failed(+retry).
// When the compile service is disconnected (dev w/o Inngest), an explicit
// notice replaces the deceptive "queued" state.
function CompileStatusBar({
  memo,
  serviceConnected,
  onRetry,
}: {
  memo: MemoCardData;
  serviceConnected: boolean;
  onRetry?: (id: string) => void;
}) {
  const status = memo.compile_status;
  if (!status || status === "done") return null;

  const isPending = status === "pending";
  const isRunning = status === "running";
  const isFailed = status === "failed";
  const showDisconnected = isPending && !serviceConnected;

  let icon: React.ReactNode;
  let label: string;
  let tone: string; // text color

  if (showDisconnected) {
    icon = <AlertCircle size={12} strokeWidth={1.9} aria-hidden="true" />;
    label = "编译服务未连接（运行 pnpm run dev:inngest）";
    tone = "var(--fg-muted)";
  } else if (isFailed) {
    icon = <AlertCircle size={12} strokeWidth={1.9} aria-hidden="true" />;
    label = memo.compile_error?.trim() || "编译失败";
    tone = "var(--accent, #c2410c)";
  } else if (isRunning) {
    icon = (
      <Loader2
        size={12}
        strokeWidth={1.9}
        aria-hidden="true"
        style={{ animation: "spin 1s linear infinite" }}
      />
    );
    label = memo.compile_step ? `编译中 · ${memo.compile_step}` : "编译中…";
    tone = "var(--fg-muted)";
  } else {
    // pending + connected
    icon = <Loader2 size={12} strokeWidth={1.9} aria-hidden="true" />;
    label = "排队中";
    tone = "var(--fg-subtle)";
  }

  return (
    <div
      role="status"
      onClick={(e) => e.stopPropagation()}
      onPointerDown={(e) => e.stopPropagation()}
      style={{
        display: "flex",
        alignItems: "center",
        gap: 6,
        marginTop: 12,
        paddingTop: 10,
        borderTop: "0.5px solid var(--border-subtle)",
        fontFamily: "var(--font-family-mono), monospace",
        fontSize: 11,
        letterSpacing: "0.02em",
        color: tone,
      }}
    >
      <span style={{ display: "inline-flex", flexShrink: 0 }}>{icon}</span>
      <span
        style={{
          flex: 1,
          minWidth: 0,
          overflow: "hidden",
          textOverflow: "ellipsis",
          whiteSpace: "nowrap",
        }}
      >
        {label}
      </span>
      {isFailed && onRetry && (
        <button
          type="button"
          aria-label="重试编译"
          onClick={(e) => {
            e.stopPropagation();
            onRetry(memo.id);
          }}
          style={{
            display: "inline-flex",
            alignItems: "center",
            gap: 4,
            flexShrink: 0,
            border: "0.5px solid var(--border-subtle)",
            borderRadius: 8,
            background: "var(--surface-white)",
            color: "var(--fg-primary)",
            cursor: "pointer",
            padding: "3px 8px",
            fontFamily: "inherit",
            fontSize: 11,
            fontWeight: 600,
          }}
        >
          <RefreshCw size={11} strokeWidth={2} aria-hidden="true" />
          重试
        </button>
      )}
    </div>
  );
}

// Body text with 5-line clamp and gradient fade
function BodyText({ body }: { body: string }) {
  const clampRef = useRef<HTMLDivElement>(null);
  const [clamped, setClamped] = useState(false);

  useEffect(() => {
    const el = clampRef.current;
    if (!el) return;
    setClamped(el.scrollHeight > el.clientHeight + 2);
  }, [body]);

  return (
    <div style={{ position: "relative" }}>
      <div
        ref={clampRef}
        style={{
          fontFamily: "var(--font-inter), ui-sans-serif, sans-serif",
          fontSize: 16,
          lineHeight: 1.62,
          letterSpacing: "0.1px",
          color: "var(--fg-primary)",
          textWrap: "pretty",
          display: "-webkit-box",
          WebkitLineClamp: 5,
          WebkitBoxOrient: "vertical",
          overflow: "hidden",
        } as React.CSSProperties}
      >
        {body}
      </div>

      {/* Gradient fade when text is clamped */}
      {clamped && (
        <div
          aria-hidden="true"
          style={{
            position: "absolute",
            bottom: 0,
            left: 0,
            right: 0,
            height: 32,
            background:
              "linear-gradient(to bottom, transparent, var(--surface-white))",
            pointerEvents: "none",
          }}
        />
      )}
    </div>
  );
}
