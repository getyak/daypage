"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";

type Tab = "today" | "page" | "archive";

const TABS: { id: Tab; label: string }[] = [
  { id: "today", label: "今日" },
  { id: "page", label: "成稿" },
  { id: "archive", label: "档案" },
];

interface IndicatorGeometry {
  width: number;
  translateX: number;
}

export function TodaySegmentedControl() {
  const router = useRouter();
  const searchParams = useSearchParams();

  const rawTab = searchParams.get("tab");
  const active: Tab =
    rawTab === "page" || rawTab === "archive" ? rawTab : "today";

  const containerRef = useRef<HTMLDivElement>(null);
  const [geo, setGeo] = useState<IndicatorGeometry | null>(null);

  const computeGeo = useCallback(() => {
    const container = containerRef.current;
    if (!container) return;
    const first = container.querySelector<HTMLButtonElement>("button");
    const activeBtn = container.querySelector<HTMLButtonElement>(
      '[aria-selected="true"]'
    );
    if (!first || !activeBtn) return;
    const firstRect = first.getBoundingClientRect();
    const btnRect = activeBtn.getBoundingClientRect();
    setGeo({
      width: btnRect.width,
      translateX: btnRect.left - firstRect.left,
    });
  }, []);

  useEffect(() => {
    // Small delay to allow layout to settle after navigation
    const id = requestAnimationFrame(computeGeo);
    window.addEventListener("resize", computeGeo);
    return () => {
      cancelAnimationFrame(id);
      window.removeEventListener("resize", computeGeo);
    };
  }, [active, computeGeo]);

  const setTab = useCallback(
    (tab: Tab) => {
      const params = new URLSearchParams(searchParams.toString());
      params.set("tab", tab);
      router.replace(`?${params.toString()}`);
    },
    [router, searchParams]
  );

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent<HTMLDivElement>) => {
      const idx = TABS.findIndex((t) => t.id === active);
      if (e.key === "ArrowRight") {
        e.preventDefault();
        setTab(TABS[(idx + 1) % TABS.length].id);
      } else if (e.key === "ArrowLeft") {
        e.preventDefault();
        setTab(TABS[(idx - 1 + TABS.length) % TABS.length].id);
      }
    },
    [active, setTab]
  );

  return (
    <div
      ref={containerRef}
      role="tablist"
      aria-label="今日视图切换"
      onKeyDown={handleKeyDown}
      style={{
        position: "relative",
        display: "inline-flex",
        padding: 3,
        borderRadius: 999,
        background: "var(--surface-sunken)",
        border: "0.5px solid var(--border-subtle)",
      }}
    >
      {/* Sliding indicator — anchored at first button, moves via translateX */}
      {geo && (
        <span
          aria-hidden="true"
          style={{
            position: "absolute",
            top: 3,
            left: 3,
            width: geo.width,
            height: "calc(100% - 6px)",
            borderRadius: 999,
            background: "var(--surface-white)",
            boxShadow: "0 1px 2px rgba(0,0,0,0.06)",
            transform: `translateX(${geo.translateX}px)`,
            transition: "transform 280ms var(--motion-spring), width 280ms var(--motion-spring)",
            pointerEvents: "none",
            zIndex: 0,
          }}
        />
      )}

      {TABS.map((tab) => {
        const isActive = tab.id === active;
        return (
          <button
            key={tab.id}
            role="tab"
            type="button"
            className="today-segmented-tab"
            aria-selected={isActive}
            tabIndex={isActive ? 0 : -1}
            onClick={() => setTab(tab.id)}
            style={{
              position: "relative",
              zIndex: 1,
              padding: "7px 16px",
              borderRadius: 999,
              border: "none",
              background: "transparent",
              color: isActive ? "var(--accent)" : "var(--fg-muted)",
              fontFamily: "var(--font-family-body), sans-serif",
              fontSize: "var(--font-size-body-xs)",
              fontWeight: isActive ? 600 : 500,
              lineHeight: 1.4,
              cursor: "pointer",
              whiteSpace: "nowrap",
              transition: "color 180ms ease-out",
              WebkitTapHighlightColor: "transparent",
            }}
          >
            {tab.label}
          </button>
        );
      })}

      {/* Design intent (app.jsx:314-325): the active tab is already legible via
          accent color + bold weight + the sliding white pill. No always-on
          outline ring. Keyboard-only focus uses :focus-visible so mouse clicks
          stay clean while keyboard navigation remains accessible. */}
      <style>{`
        .today-segmented-tab { outline: none; }
        .today-segmented-tab:focus-visible {
          outline: 2px solid var(--accent);
          outline-offset: -2px;
        }
      `}</style>
    </div>
  );
}
