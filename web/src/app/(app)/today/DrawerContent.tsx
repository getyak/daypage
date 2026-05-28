"use client";

import { useEffect, useState } from "react";
import { useRouter, usePathname } from "next/navigation";
import { X, Calendar, FileText, Archive, GitBranch } from "lucide-react";
import { GlassPillBtn } from "@/components/ui/GlassPillBtn";
import { DrawerHeatmap } from "./DrawerHeatmap";

const PLACEHOLDER_NAME = "User";
const PLACEHOLDER_YEAR = "2025";

interface DrawerContentProps {
  onClose: () => void;
}

interface DrawerStats {
  streak_days: number;
  pages_total: number;
  words_this_year: number;
  words_this_year_display: string;
}

interface RecentItem {
  date_slug: string;
  day: string;
  date_display: string;
  title: string;
  memo_count: number;
  is_today: boolean;
}

function formatLargeNumber(n: number): string {
  if (n >= 1_000_000) return `${Math.round(n / 100_000) / 10}M`;
  if (n >= 1_000) return `${Math.round(n / 100) / 10}K`;
  return String(n);
}

const PLACEHOLDER_RECENT: RecentItem[] = [
  { date_slug: "2026-05-28", day: "THU", date_display: "05·28", title: "Today's Recap", memo_count: 3, is_today: true },
  { date_slug: "2026-05-27", day: "WED", date_display: "05·27", title: "Morning thoughts", memo_count: 5, is_today: false },
];

export function DrawerContent({ onClose }: DrawerContentProps) {
  const router = useRouter();
  const pathname = usePathname();
  const initial = PLACEHOLDER_NAME.charAt(0).toUpperCase();

  const [stats, setStats] = useState<DrawerStats | null>(null);
  const [recentItems, setRecentItems] = useState<RecentItem[]>([]);

  useEffect(() => {
    fetch("/api/stats/drawer")
      .then((r) => r.json())
      .then((d: DrawerStats) => setStats(d))
      .catch(() => {});
  }, []);

  useEffect(() => {
    fetch("/api/stats/recent?limit=7")
      .then((r) => r.json())
      .then((d: { items: RecentItem[] }) => {
        const items = Array.isArray(d.items) && d.items.length > 0 ? d.items : PLACEHOLDER_RECENT;
        setRecentItems(items);
      })
      .catch(() => setRecentItems(PLACEHOLDER_RECENT));
  }, []);

  function navigate(href: string) {
    router.push(href);
    setTimeout(onClose, 280);
  }

  const navRows = [
    { label: "今日", href: "/today", icon: Calendar, count: stats?.pages_total ?? null },
    { label: "成稿", href: "/wiki", icon: FileText, count: stats?.pages_total ?? null },
    { label: "档案", href: "/archive", icon: Archive, count: null },
    { label: "关系图谱", href: "/graph", icon: GitBranch, count: null, muted: true },
  ];

  const version = process.env.NEXT_PUBLIC_VERSION ?? "v1.0";

  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        gap: 0,
        padding: "16px 16px 32px",
        flex: 1,
      }}
    >
      {/* Top bar: close button + brand label */}
      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          marginBottom: 20,
        }}
      >
        <GlassPillBtn size="sm" aria-label="关闭侧边栏" onClick={onClose}>
          <X size={16} strokeWidth={1.7} aria-hidden="true" />
        </GlassPillBtn>

        <span
          id="drawer-title"
          style={{
            fontFamily: "var(--font-jetbrains-mono), ui-monospace, monospace",
            fontSize: 10,
            letterSpacing: 2,
            fontWeight: 700,
            textTransform: "uppercase",
            color: "var(--fg-muted)",
          }}
        >
          DAYPAGE · 2026
        </span>
      </div>

      {/* Profile row */}
      <button
        type="button"
        onClick={() => router.push("/settings")}
        style={{
          display: "flex",
          alignItems: "center",
          gap: 12,
          padding: "10px 12px",
          borderRadius: 12,
          border: "none",
          background: "transparent",
          cursor: "pointer",
          textAlign: "left",
          width: "100%",
          transition: "background 140ms ease-out",
          marginBottom: 20,
        }}
        onMouseEnter={(e) =>
          ((e.currentTarget as HTMLElement).style.background = "var(--surface-sunken)")
        }
        onMouseLeave={(e) =>
          ((e.currentTarget as HTMLElement).style.background = "transparent")
        }
        aria-label={`前往设置 — ${PLACEHOLDER_NAME}`}
      >
        {/* Avatar */}
        <div
          style={{
            width: 46,
            height: 46,
            borderRadius: "50%",
            background: "linear-gradient(135deg, #C9A677 0%, #5D3000 100%)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            flexShrink: 0,
          }}
        >
          <span
            style={{
              fontFamily: "var(--font-fraunces), Georgia, serif",
              fontSize: 20,
              fontWeight: 600,
              color: "#fff",
              textTransform: "uppercase",
              lineHeight: 1,
            }}
          >
            {initial}
          </span>
        </div>

        {/* Name + subtitle */}
        <div style={{ flex: 1, minWidth: 0 }}>
          <div
            style={{
              fontFamily: "var(--font-fraunces), Georgia, serif",
              fontSize: 19,
              fontWeight: 600,
              lineHeight: 1.15,
              letterSpacing: "-0.2px",
              color: "var(--fg-primary)",
              whiteSpace: "nowrap",
              overflow: "hidden",
              textOverflow: "ellipsis",
            }}
          >
            {PLACEHOLDER_NAME}
          </div>
          <div
            style={{
              fontFamily: "var(--font-jetbrains-mono), ui-monospace, monospace",
              fontSize: 10,
              letterSpacing: 1.2,
              textTransform: "uppercase",
              color: "var(--fg-muted)",
              marginTop: 3,
            }}
          >
            MEMBER · SINCE {PLACEHOLDER_YEAR}
          </div>
        </div>
      </button>

      {/* Heatmap */}
      <DrawerHeatmap />

      {/* US-022: Stats 三联卡 */}
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "1fr 1fr 1fr",
          borderRadius: 14,
          overflow: "hidden",
          border: "0.5px solid var(--border-default)",
          boxShadow: "var(--shadow-card)",
          marginTop: 16,
        }}
      >
        {[
          {
            label: "STREAK",
            value: stats ? String(stats.streak_days) : "—",
            unit: "DAYS",
            first: true,
          },
          {
            label: "PAGES",
            value: stats ? String(stats.pages_total) : "—",
            unit: "TOTAL",
            first: false,
          },
          {
            label: "WORDS",
            value: stats ? formatLargeNumber(stats.words_this_year) : "—",
            unit: "THIS YEAR",
            first: false,
          },
        ].map((col) => (
          <div
            key={col.label}
            style={{
              padding: "14px 6px 12px",
              textAlign: "center",
              borderLeft: col.first ? "none" : "0.5px solid var(--border-default)",
            }}
          >
            <div
              style={{
                fontFamily: "var(--font-jetbrains-mono), ui-monospace, monospace",
                fontSize: 9,
                fontWeight: 600,
                lineHeight: 1.4,
                letterSpacing: 1,
                textTransform: "uppercase",
                color: "var(--fg-muted)",
              }}
            >
              {col.label}
            </div>
            <div
              style={{
                fontFamily: "var(--font-fraunces), Georgia, serif",
                fontSize: 22,
                fontWeight: 600,
                letterSpacing: "-0.5px",
                color: "var(--fg-primary)",
                lineHeight: 1.2,
                marginTop: 2,
                marginBottom: 2,
              }}
            >
              {col.value}
            </div>
            <div
              style={{
                fontFamily: "var(--font-jetbrains-mono), ui-monospace, monospace",
                fontSize: 8,
                lineHeight: 1.2,
                letterSpacing: 0.8,
                textTransform: "uppercase",
                color: "var(--fg-muted)",
              }}
            >
              {col.unit}
            </div>
          </div>
        ))}
      </div>

      {/* US-023: Navigate Card */}
      <div
        style={{
          borderRadius: 14,
          border: "0.5px solid var(--border-default)",
          overflow: "hidden",
          boxShadow: "var(--shadow-card)",
          marginTop: 12,
        }}
      >
        {navRows.map((row, i) => {
          const Icon = row.icon;
          const isActive = pathname === row.href || (row.href !== "/" && pathname.startsWith(row.href));
          return (
            <button
              key={row.href}
              type="button"
              onClick={() => navigate(row.href)}
              style={{
                display: "flex",
                alignItems: "center",
                gap: 14,
                padding: "12px 14px",
                width: "100%",
                border: "none",
                borderTop: i === 0 ? "none" : "0.5px solid var(--border-subtle)",
                background: isActive ? "var(--accent-soft)" : "transparent",
                cursor: "pointer",
                textAlign: "left",
                transition: "background 140ms ease-out",
              }}
              onMouseEnter={(e) => {
                if (!isActive) (e.currentTarget as HTMLElement).style.background = "var(--surface-sunken)";
              }}
              onMouseLeave={(e) => {
                if (!isActive) (e.currentTarget as HTMLElement).style.background = "transparent";
              }}
            >
              <div
                style={{
                  width: 30,
                  height: 30,
                  borderRadius: 9,
                  background: isActive ? "#fff" : "var(--surface-sunken)",
                  border: "0.5px solid var(--border-subtle)",
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  flexShrink: 0,
                }}
              >
                <Icon
                  size={15}
                  strokeWidth={1.6}
                  color={isActive ? "var(--accent)" : row.muted ? "var(--fg-muted)" : "var(--fg-secondary)"}
                />
              </div>
              <span
                style={{
                  flex: 1,
                  fontSize: 14,
                  fontWeight: 500,
                  lineHeight: 1.4,
                  color: isActive
                    ? "var(--accent)"
                    : row.muted
                    ? "var(--fg-muted)"
                    : "var(--fg-primary)",
                  fontFamily: "var(--font-inter), system-ui, sans-serif",
                }}
              >
                {row.label}
              </span>
            </button>
          );
        })}
      </div>

      {/* US-024: Recent List */}
      <div style={{ marginTop: 20 }}>
        {recentItems.length === 0 ? (
          <div
            style={{
              fontSize: 13,
              color: "var(--fg-muted)",
              textAlign: "center",
              padding: "16px 0",
              fontFamily: "var(--font-inter), system-ui, sans-serif",
            }}
          >
            还没有成稿的日页
          </div>
        ) : (
          recentItems.map((item, i) => {
            const isActive = item.is_today;
            return (
              <button
                key={item.date_slug}
                type="button"
                onClick={() => navigate(`/archive/${item.date_slug}`)}
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 14,
                  padding: "13px 0px",
                  width: "100%",
                  border: "none",
                  borderTop: i === 0 ? "none" : "0.5px solid var(--border-subtle)",
                  background: "transparent",
                  cursor: "pointer",
                  textAlign: "left",
                }}
              >
                {/* Date column */}
                <div style={{ minWidth: 52, flexShrink: 0 }}>
                  <div
                    style={{
                      fontFamily: "var(--font-jetbrains-mono), ui-monospace, monospace",
                      fontSize: 9,
                      lineHeight: 1.4,
                      letterSpacing: 0.8,
                      textTransform: "uppercase",
                      color: isActive ? "var(--accent)" : "var(--fg-muted)",
                    }}
                  >
                    {item.day}
                  </div>
                  <div
                    style={{
                      fontFamily: "var(--font-jetbrains-mono), ui-monospace, monospace",
                      fontSize: 16,
                      fontWeight: 600,
                      color: isActive ? "var(--accent)" : "var(--fg-secondary)",
                      lineHeight: 1.2,
                    }}
                  >
                    {item.date_display}
                  </div>
                </div>

                {/* Title */}
                <div
                  style={{
                    flex: 1,
                    fontSize: 14,
                    lineHeight: 1.4,
                    fontWeight: isActive ? 600 : 400,
                    color: isActive ? "var(--fg-primary)" : "var(--fg-secondary)",
                    fontFamily: "var(--font-inter), system-ui, sans-serif",
                    whiteSpace: "nowrap",
                    overflow: "hidden",
                    textOverflow: "ellipsis",
                    minWidth: 0,
                  }}
                >
                  {item.title}
                </div>

                {/* Count */}
                <div
                  style={{
                    fontFamily: "var(--font-jetbrains-mono), ui-monospace, monospace",
                    fontSize: 10,
                    letterSpacing: 0.6,
                    color: isActive ? "var(--accent)" : "var(--fg-subtle)",
                    flexShrink: 0,
                  }}
                >
                  {item.memo_count}
                </div>
              </button>
            );
          })
        )}

        {/* VIEW ALL link */}
        <div style={{ paddingTop: 8 }}>
          <button
            type="button"
            onClick={() => navigate("/archive")}
            style={{
              background: "none",
              border: "none",
              padding: 0,
              cursor: "pointer",
              fontFamily: "var(--font-jetbrains-mono), ui-monospace, monospace",
              fontSize: 10,
              letterSpacing: 1.2,
              textTransform: "uppercase",
              color: "var(--fg-muted)",
            }}
          >
            VIEW ALL ›
          </button>
        </div>
      </div>

      {/* US-025: Footer */}
      <div
        style={{
          marginTop: 30,
          paddingTop: 18,
          paddingBottom: 4,
          paddingLeft: 4,
          paddingRight: 4,
          borderTop: "0.5px solid var(--border-subtle)",
        }}
      >
        <div
          style={{
            display: "flex",
            gap: 16,
            alignItems: "center",
            marginBottom: 8,
          }}
        >
          <button
            type="button"
            onClick={() => navigate("/settings")}
            style={{
              background: "none",
              border: "none",
              padding: 0,
              cursor: "pointer",
              fontSize: 13,
              fontWeight: 500,
              color: "var(--fg-muted)",
              fontFamily: "var(--font-inter), system-ui, sans-serif",
            }}
          >
            Settings
          </button>
          <a
            href="mailto:feedback@daypage.app"
            style={{
              fontSize: 13,
              fontWeight: 500,
              color: "var(--fg-muted)",
              textDecoration: "none",
              fontFamily: "var(--font-inter), system-ui, sans-serif",
            }}
          >
            Feedback
          </a>
        </div>
        <div
          style={{
            fontFamily: "var(--font-jetbrains-mono), ui-monospace, monospace",
            fontSize: 9,
            letterSpacing: 1.2,
            textTransform: "uppercase",
            color: "var(--fg-muted)",
          }}
        >
          {version} · 2026-05-28
        </div>
      </div>
    </div>
  );
}
