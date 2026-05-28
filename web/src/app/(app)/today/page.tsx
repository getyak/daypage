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

function MemoFeed({
  composerMicRef,
}: {
  composerMicRef: React.RefObject<HTMLButtonElement | null>;
}) {
  const [memos, setMemos] = useState<MemoCardData[]>([]);

  useEffect(() => {
    fetch("/api/today/memos")
      .then((r) => r.json())
      .then((d: { memos: MemoCardData[] }) => {
        if (Array.isArray(d.memos)) setMemos(d.memos);
      })
      .catch(() => {});
  }, []);

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 10, paddingTop: 8 }}>
      {memos.map((memo) => (
        <MemoCard key={memo.id} memo={memo} />
      ))}
      {/* US-010: Placeholder card — shown when below unlock_threshold */}
      <UnlockPlaceholderCard composerMicRef={composerMicRef} />
    </div>
  );
}

export default function TodayPage() {
  const [scrolled, setScrolled] = useState(false);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const rafRef = useRef<number | null>(null);
  const composerMicRef = useRef<HTMLButtonElement | null>(null);

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
        paddingTop: 60,
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
          height: 60,
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          paddingLeft: 14,
          paddingRight: 14,
          paddingBottom: 10,
          background: scrolled ? "rgba(250,248,246,0.78)" : "transparent",
          backdropFilter: scrolled ? "blur(20px) saturate(150%)" : "none",
          WebkitBackdropFilter: scrolled ? "blur(20px) saturate(150%)" : "none",
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
      <MemoFeed composerMicRef={composerMicRef} />

      {/* Week Wiki Spine Feed — US-011 */}
      <div style={{ paddingTop: 24 }}>
        <WeekFeedSpine />
      </div>

      {/* Drawer — US-019/020/021 */}
      <Drawer isOpen={drawerOpen} onClose={() => setDrawerOpen(false)}>
        <DrawerContent onClose={() => setDrawerOpen(false)} />
      </Drawer>
    </div>
  );
}
