"use client";

import { useEffect, useRef, useState, useCallback } from "react";
import { Menu, Search, Settings } from "lucide-react";
import { GlassPillBtn } from "@/components/ui/GlassPillBtn";

export default function TodayPage() {
  const [scrolled, setScrolled] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const rafRef = useRef<number | null>(null);

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
        <GlassPillBtn size="sm" aria-label="打开侧边栏">
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

      {/* Placeholder content — enough to enable scrolling */}
      <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
        {Array.from({ length: 30 }, (_, i) => (
          <div
            key={i}
            className="card"
            style={{ padding: "16px 20px", minHeight: 64 }}
          >
            <span
              className="ds-label"
              style={{ color: "var(--fg-muted)" }}
            >
              Memo {i + 1}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}
