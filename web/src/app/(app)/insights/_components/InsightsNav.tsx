"use client";

import Link from "next/link";
import { BarChart2, Activity, Cpu, Code2 } from "lucide-react";

const SECTIONS = [
  { id: "knowledge", label: "Knowledge", icon: BarChart2 },
  { id: "activity", label: "Activity Stream", icon: Activity },
  { id: "system", label: "System & Cost", icon: Cpu },
  { id: "dev", label: "Development", icon: Code2 },
];

export function InsightsNav({ range, active }: { range: string; active: string }) {
  return (
    <nav style={{ display: "flex", flexDirection: "column", gap: 2 }}>
      <div className="ds-section-label" style={{ padding: "0 8px", marginBottom: 8 }}>Categories</div>
      {SECTIONS.map(({ id, label, icon: Icon }) => {
        const isActive = active === id;
        return (
          <Link
            key={id}
            href={`/insights?range=${range}&section=${id}`}
            style={{
              display: "flex",
              alignItems: "center",
              gap: 8,
              padding: "8px 10px",
              borderRadius: "var(--radius-small)",
              textDecoration: "none",
              fontSize: "0.875rem",
              fontWeight: isActive ? 500 : 400,
              color: isActive ? "var(--accent)" : "var(--fg-muted)",
              background: isActive ? "var(--accent-soft)" : "transparent",
              transition: "background 120ms ease-out, color 120ms ease-out",
            }}
          >
            <Icon size={15} strokeWidth={1.7} />
            {label}
          </Link>
        );
      })}
    </nav>
  );
}
