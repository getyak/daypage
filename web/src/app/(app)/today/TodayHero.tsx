"use client";

import Link from "next/link";
import { CaptureHero } from "../add/CaptureHero";
import { Composer } from "../add/Composer";
import "../add/capture.css";

export function TodayHero({ onSaved }: { onSaved: () => void }) {
  return (
    <header className="capture-page" style={{ display: "grid", gap: 24, padding: "24px 6px" }} data-testid="today-capture-welcome">
      <CaptureHero />
      <Composer onSaved={onSaved} />
      <Link href="/home" style={{ display: "inline-block", padding: "12px 0", fontSize: 13, color: "var(--fg-muted)" }}>
        查看日记与知识
      </Link>
    </header>
  );
}
