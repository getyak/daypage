"use client";

import { useEffect, useRef, useState, useCallback } from "react";
import { motion, useReducedMotion } from "framer-motion";
import { Menu, Search, Settings } from "lucide-react";
import { GlassPillBtn } from "@/components/ui/GlassPillBtn";
import { Drawer } from "@/components/ui/Drawer";
import { TodayHero } from "./TodayHero";
import { MemoCard, type MemoCardData } from "./MemoCard";
import { DrawerContent } from "./DrawerContent";
import { ShareCard, type ShareCardMemo } from "./ShareCard";
import { MobileOnlyGuard } from "./MobileOnlyGuard";

function MemoFeed({
  onShare,
  onServiceDisconnected,
  refreshToken,
}: {
  onShare: (memo: ShareCardMemo) => void;
  onServiceDisconnected?: () => void;
  refreshToken: number;
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
  }, [reloadMemos, onServiceDisconnected, refreshToken]);

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
    <MemoFeedList
      memos={memos}
      serviceConnected={serviceConnected}
      onRetry={handleRetry}
      onShare={onShare}
    />
  );
}

function MemoFeedList({
  memos,
  serviceConnected,
  onRetry,
  onShare,
}: {
  memos: MemoCardData[];
  serviceConnected: boolean;
  onRetry: (id: string) => void;
  onShare: (memo: ShareCardMemo) => void;
}) {
  const reduced = useReducedMotion();
  return (
    <motion.div
      initial="hidden"
      animate="show"
      variants={
        reduced
          ? undefined
          : {
              hidden: {},
              show: {
                transition: { staggerChildren: 0.045, delayChildren: 0.04 },
              },
            }
      }
      style={{ display: "flex", flexDirection: "column", gap: 10, paddingTop: 8 }}
    >
      {memos.map((memo) => (
        <MemoCard
          key={memo.id}
          memo={memo}
          serviceConnected={serviceConnected}
          onRetry={onRetry}
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
    </motion.div>
  );
}

function TodayMobileFlow() {
  const [scrolled, setScrolled] = useState(false);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [shareMemo, setShareMemo] = useState<ShareCardMemo | null>(null);
  const [showServiceToast, setShowServiceToast] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const rafRef = useRef<number | null>(null);

  const [feedRevision, setFeedRevision] = useState(0);
  const handleSaved = useCallback(() => setFeedRevision((value) => value + 1), []);
  const handleDisconnected = useCallback(() => setShowServiceToast(true), []);

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

      <TodayHero onSaved={handleSaved} />

      {/* Memo Feed + Unlock Placeholder — US-009, US-010 */}
      <MemoFeed
          onShare={setShareMemo}
        onServiceDisconnected={handleDisconnected}
        refreshToken={feedRevision}
      />

      {/* Drawer — US-019/020/021 */}
      <Drawer isOpen={drawerOpen} onClose={() => setDrawerOpen(false)}>
        <DrawerContent onClose={() => setDrawerOpen(false)} />
      </Drawer>

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
