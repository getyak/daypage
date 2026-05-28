"use client";

import { useRouter } from "next/navigation";
import { X } from "lucide-react";
import { GlassPillBtn } from "@/components/ui/GlassPillBtn";
import { DrawerHeatmap } from "./DrawerHeatmap";

const PLACEHOLDER_NAME = "User";
const PLACEHOLDER_YEAR = "2025";

interface DrawerContentProps {
  onClose: () => void;
}

export function DrawerContent({ onClose }: DrawerContentProps) {
  const router = useRouter();
  const initial = PLACEHOLDER_NAME.charAt(0).toUpperCase();

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
    </div>
  );
}
