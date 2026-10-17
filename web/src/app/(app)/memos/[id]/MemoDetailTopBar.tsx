"use client";

import { useRouter } from "next/navigation";
import { GlassPillBtn } from "@/components/ui/GlassPillBtn";
import { formatMemoAnchor } from "@/lib/memos/format";

interface Props {
  /** Original DB timestamp string — displayed, never mutated. */
  createdAt: string;
}

// Sticky glass top bar. Read-only slice: no share/pin/edit/delete actions are
// wired here (ADR-0022) — the anchor shows the memo time in Asia/Shanghai.
export function MemoDetailTopBar({ createdAt }: Props) {
  const router = useRouter();

  return (
    <div
      style={{
        position: "sticky",
        top: 0,
        padding: "62px 14px 12px",
        background: "rgba(250,248,246,0.82)",
        backdropFilter: "blur(20px) saturate(150%)",
        WebkitBackdropFilter: "blur(20px) saturate(150%)",
        borderBottom: "0.5px solid var(--border-subtle)",
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        zIndex: 40,
      }}
    >
      <GlassPillBtn aria-label="返回历史" size="sm" onClick={() => router.push("/memos")}>
        ← History
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
        {formatMemoAnchor(createdAt)}
      </span>

      {/* Spacer keeps the date anchor optically centered */}
      <span aria-hidden="true" style={{ width: 64 }} />
    </div>
  );
}
