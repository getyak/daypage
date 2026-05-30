"use client";

import { useRouter } from "next/navigation";
import { Share2, MoreHorizontal } from "lucide-react";
import { GlassPillBtn } from "@/components/ui/GlassPillBtn";

interface Props {
  createdAt: string; // ISO string
}

const DAY_NAMES = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"];
const MONTH_NAMES = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"];

function formatTimeAnchor(isoString: string): string {
  const d = new Date(isoString);
  const day = DAY_NAMES[d.getDay()];
  const month = MONTH_NAMES[d.getMonth()];
  const date = String(d.getDate()).padStart(2, "0");
  const hours = String(d.getHours()).padStart(2, "0");
  const minutes = String(d.getMinutes()).padStart(2, "0");
  return `${day} · ${month} ${date} · ${hours}:${minutes}`;
}

export function MemoDetailTopBar({ createdAt }: Props) {
  const router = useRouter();

  async function handleShare() {
    if (typeof navigator !== "undefined" && navigator.share) {
      try {
        await navigator.share({ title: "DayPage Memo", url: window.location.href });
      } catch {
        // user cancelled or not supported
      }
    }
  }

  return (
    <div
      style={{
        position: "sticky",
        top: 0,
        padding: "62px 14px 12px",
        background: "rgba(250,248,246,0.80)",
        backdropFilter: "blur(20px) saturate(130%)",
        WebkitBackdropFilter: "blur(20px) saturate(130%)",
        borderBottom: "0.5px solid var(--border-subtle)",
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        zIndex: 40,
      }}
    >
      <GlassPillBtn aria-label="返回今日" size="sm" onClick={() => router.push("/today")}>
        ← 今日
      </GlassPillBtn>

      <span
        style={{
          fontFamily: "var(--font-mono)",
          fontSize: 10,
          letterSpacing: "1.5px",
          color: "var(--fg-subtle)",
          textTransform: "uppercase",
          userSelect: "none",
        }}
      >
        {formatTimeAnchor(createdAt)}
      </span>

      <div style={{ display: "flex", gap: 8 }}>
        <GlassPillBtn aria-label="分享" size="sm" onClick={() => void handleShare()}>
          <Share2 size={14} />
        </GlassPillBtn>
        <GlassPillBtn aria-label="更多操作" size="sm">
          <MoreHorizontal size={14} />
        </GlassPillBtn>
      </div>
    </div>
  );
}
