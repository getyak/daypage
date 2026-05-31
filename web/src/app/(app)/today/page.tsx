"use client";

import { useEffect, useRef, useState, useCallback, Suspense } from "react";
import { Menu, Search, Settings } from "lucide-react";
import { GlassPillBtn } from "@/components/ui/GlassPillBtn";
import { Drawer } from "@/components/ui/Drawer";
import { TodayHero } from "./TodayHero";
import { TodaySegmentedControl } from "./TodaySegmentedControl";
import { AISummaryCard } from "./AISummaryCard";
import { MemoCard, type MemoCardData } from "./MemoCard";
import { UnlockPlaceholderCard } from "./UnlockPlaceholderCard";
import { WeekFeedSpine } from "./WeekFeedSpine";
import { DrawerContent } from "./DrawerContent";
import { ComposerPill } from "./ComposerPill";
import { WriteSheet } from "./WriteSheet";
import { AttachSheet } from "./AttachSheet";
import { RecordingSheet } from "./RecordingSheet";
import { DynamicIslandLive } from "./DynamicIslandLive";
import { ShareCard, type ShareCardMemo } from "./ShareCard";
import { MobileOnlyGuard } from "./MobileOnlyGuard";

function MemoFeed({
  composerMicRef,
  onShare,
  onServiceDisconnected,
}: {
  composerMicRef: React.RefObject<HTMLButtonElement | null>;
  onShare: (memo: ShareCardMemo) => void;
  onServiceDisconnected?: () => void;
}) {
  const [memos, setMemos] = useState<MemoCardData[]>([]);
  const [serviceConnected, setServiceConnected] = useState(true);

  const reloadMemos = useCallback(() => {
    fetch("/api/today/memos")
      .then((r) => r.json())
      .then((d: { memos: MemoCardData[] }) => {
        if (Array.isArray(d.memos)) setMemos(d.memos);
      })
      .catch(() => {});
  }, []);

  useEffect(() => {
    reloadMemos();
    fetch("/api/compile/status")
      .then((r) => (r.ok ? r.json() : null))
      .then((d: { connected: boolean } | null) => {
        if (d) {
          setServiceConnected(d.connected);
          if (!d.connected) onServiceDisconnected?.();
        }
      })
      .catch(() => {});
  }, [reloadMemos, onServiceDisconnected]);

  const handleRetry = useCallback(
    (id: string) => {
      // Optimistically mark as pending, then re-trigger compilation.
      setMemos((prev) =>
        prev.map((m) =>
          m.id === id
            ? { ...m, compile_status: "pending", compile_error: null }
            : m,
        ),
      );
      fetch(`/api/memos/${id}/recompile`, { method: "POST" })
        .then(() => reloadMemos())
        .catch(() => {});
    },
    [reloadMemos],
  );

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 10, paddingTop: 8 }}>
      {memos.map((memo) => (
        <MemoCard
          key={memo.id}
          memo={memo}
          serviceConnected={serviceConnected}
          onRetry={handleRetry}
          onShare={() =>
            onShare({
              id: memo.id,
              body: memo.body,
              created_at: memo.created_at,
              type: memo.type,
              photo_url: memo.photo_url ?? undefined,
            })
          }
        />
      ))}
      {/* US-010: Placeholder card — shown when below unlock_threshold */}
      <UnlockPlaceholderCard composerMicRef={composerMicRef} />
    </div>
  );
}

function TodayMobileFlow() {
  const [scrolled, setScrolled] = useState(false);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [isRecording, setIsRecording] = useState(false);
  const [recordElapsed, setRecordElapsed] = useState(0);
  const [writeOpen, setWriteOpen] = useState(false);
  const [showAttachSheet, setShowAttachSheet] = useState(false);
  const [shareMemo, setShareMemo] = useState<ShareCardMemo | null>(null);
  const [showServiceToast, setShowServiceToast] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const rafRef = useRef<number | null>(null);
  const composerMicRef = useRef<HTMLButtonElement | null>(null);

  // Tap (mic short-press) and the text placeholder both open the WriteSheet.
  const handleMicPress = useCallback(() => {
    setWriteOpen(true);
  }, []);

  const handleMicLongPress = useCallback(() => {
    setIsRecording(true);
  }, []);

  const handlePlusPress = useCallback(() => {
    setShowAttachSheet(true);
  }, []);

  const handleTextPress = useCallback(() => {
    setWriteOpen(true);
  }, []);

  // Drive the Dynamic Island timer while recording (mirrors RecordingSheet's
  // own elapsed clock; design composer.jsx useRecording:522-533). The reset to
  // 0 runs in cleanup (not the effect body) to avoid cascading-render lint.
  useEffect(() => {
    if (!isRecording) return;
    const start = Date.now();
    const t = setInterval(() => {
      setRecordElapsed(Math.floor((Date.now() - start) / 1000));
    }, 1000);
    return () => {
      clearInterval(t);
      setRecordElapsed(0);
    };
  }, [isRecording]);

  // The mobile Today flow paints its own glass toolbar, so suppress the shared
  // app topbar while it is mounted (restored on unmount / desktop redirect).
  useEffect(() => {
    document.body.classList.add("today-mobile-active");
    return () => document.body.classList.remove("today-mobile-active");
  }, []);

  const handleScroll = useCallback(() => {
    if (rafRef.current !== null) return;
    rafRef.current = requestAnimationFrame(() => {
      rafRef.current = null;
      const top = containerRef.current?.scrollTop ?? 0;
      setScrolled(top > 8);
    });
  }, []);

  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    el.addEventListener("scroll", handleScroll, { passive: true });
    return () => {
      el.removeEventListener("scroll", handleScroll);
      if (rafRef.current !== null) {
        cancelAnimationFrame(rafRef.current);
        rafRef.current = null;
      }
    };
  }, [handleScroll]);

  return (
    <div
      ref={containerRef}
      style={{
        position: "relative",
        height: "100%",
        overflowY: "auto",
        paddingTop: 52,
        paddingLeft: 14,
        paddingRight: 14,
        paddingBottom: 10,
      }}
    >
      {/* Scroll-aware utility bar */}
      <div
        role="toolbar"
        aria-label="页面工具栏"
        style={{
          position: "absolute",
          top: 0,
          left: 0,
          right: 0,
          height: 52,
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          paddingLeft: 14,
          paddingRight: 14,
          background: scrolled ? "rgba(250,248,246,0.82)" : "transparent",
          backdropFilter: scrolled ? "blur(20px) saturate(160%)" : "none",
          WebkitBackdropFilter: scrolled ? "blur(20px) saturate(160%)" : "none",
          borderBottom: scrolled
            ? "0.5px solid var(--border-subtle)"
            : "0.5px solid transparent",
          transition:
            "background 200ms ease-out, backdrop-filter 200ms ease-out, -webkit-backdrop-filter 200ms ease-out, border-color 200ms ease-out",
          zIndex: 10,
        }}
      >
        <GlassPillBtn size="sm" aria-label="打开侧边栏" onClick={() => setDrawerOpen(true)}>
          <Menu size={16} strokeWidth={1.7} aria-hidden="true" />
        </GlassPillBtn>

        <div style={{ display: "flex", gap: 8 }}>
          <GlassPillBtn size="sm" aria-label="搜索">
            <Search size={16} strokeWidth={1.7} aria-hidden="true" />
          </GlassPillBtn>
          <GlassPillBtn size="sm" aria-label="设置">
            <Settings size={16} strokeWidth={1.7} aria-hidden="true" />
          </GlassPillBtn>
        </div>
      </div>

      {/* Service disconnected toast — floats at top, auto-dismiss after 6s */}
      {showServiceToast && (
        <div
          role="status"
          aria-live="polite"
          style={{
            position: "fixed",
            top: "calc(64px + env(safe-area-inset-top, 0px))",
            left: "50%",
            transform: "translateX(-50%)",
            zIndex: 50,
            display: "flex",
            alignItems: "center",
            gap: 8,
            padding: "9px 14px 9px 12px",
            borderRadius: 999,
            background: "rgba(43,40,34,0.88)",
            backdropFilter: "blur(16px) saturate(140%)",
            WebkitBackdropFilter: "blur(16px) saturate(140%)",
            boxShadow: "0 4px 20px rgba(0,0,0,0.22), inset 0 0.5px 0 rgba(255,255,255,0.08)",
            animation: "toast-in 280ms var(--motion-spring) both",
            whiteSpace: "nowrap",
          }}
        >
          <span
            style={{
              width: 6,
              height: 6,
              borderRadius: 999,
              background: "var(--warning)",
              flexShrink: 0,
            }}
          />
          <span
            style={{
              fontFamily: "var(--font-family-mono), monospace",
              fontSize: 11.5,
              letterSpacing: "0.3px",
              color: "rgba(240,237,232,0.9)",
            }}
          >
            AI 编译服务未连接
          </span>
          <button
            type="button"
            aria-label="关闭提示"
            onClick={() => setShowServiceToast(false)}
            style={{
              marginLeft: 2,
              width: 18,
              height: 18,
              borderRadius: 999,
              border: "none",
              background: "rgba(255,255,255,0.12)",
              color: "rgba(240,237,232,0.7)",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              cursor: "pointer",
              fontSize: 12,
              lineHeight: 1,
              flexShrink: 0,
            }}
          >
            ×
          </button>
        </div>
      )}

      {/* Today Hero — US-006 */}
      <TodayHero />

      {/* Segmented Control — US-007 */}
      <div style={{ display: "flex", justifyContent: "center", paddingTop: 12, paddingBottom: 4 }}>
        <Suspense fallback={null}>
          <TodaySegmentedControl />
        </Suspense>
      </div>

      {/* AI Summary Card — US-008 */}
      <div style={{ paddingTop: 16, paddingBottom: 8 }}>
        <AISummaryCard />
      </div>

      {/* Memo Feed + Unlock Placeholder — US-009, US-010 */}
      <MemoFeed
        composerMicRef={composerMicRef}
        onShare={setShareMemo}
        onServiceDisconnected={() => setShowServiceToast(true)}
      />

      {/* Week Wiki Spine Feed — US-011 */}
      <div style={{ paddingTop: 24 }}>
        <WeekFeedSpine />
      </div>

      {/* Composer Pill — US-026/027 */}
      <ComposerPill
        isRecording={isRecording}
        onMicPress={handleMicPress}
        onMicLongPress={handleMicLongPress}
        onPlusPress={handlePlusPress}
        onTextPress={handleTextPress}
      />

      {/* Drawer — US-019/020/021 */}
      <Drawer isOpen={drawerOpen} onClose={() => setDrawerOpen(false)}>
        <DrawerContent onClose={() => setDrawerOpen(false)} />
      </Drawer>

      {/* Write Sheet — text composer (design composer.jsx:183-345) */}
      <WriteSheet
        isOpen={writeOpen}
        onClose={() => setWriteOpen(false)}
        onSend={() => setWriteOpen(false)}
      />

      {/* Attach Sheet — US-028 */}
      {showAttachSheet && (
        <AttachSheet isOpen={showAttachSheet} onClose={() => setShowAttachSheet(false)} />
      )}

      {/* Recording Sheet — US-029 */}
      {isRecording && (
        <RecordingSheet isOpen={isRecording} onClose={() => setIsRecording(false)} onStop={() => setIsRecording(false)} />
      )}

      {/* Dynamic Island live activity — top capsule while recording */}
      <DynamicIslandLive active={isRecording} elapsed={recordElapsed} />

      {/* Share Card — US-031/032/033 */}
      {shareMemo && (
        <ShareCard memo={shareMemo} onClose={() => setShareMemo(null)} />
      )}
    </div>
  );
}

// US-050: /today is the mobile capture/browse flow only. Desktop (≥1024px)
// redirects to /add via MobileOnlyGuard so the mobile layout never collides
// with the desktop workstation shell.
export default function TodayPage() {
  return (
    <MobileOnlyGuard>
      <TodayMobileFlow />
    </MobileOnlyGuard>
  );
}
