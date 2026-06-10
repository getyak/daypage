import { Suspense } from "react";
import Link from "next/link";
import { BarChart2, Activity, Cpu, Code2, BookOpen } from "lucide-react";
import { SectionLabel } from "@/components/ui";
import { InsightsNav } from "./_components/InsightsNav";
import { KnowledgeCard } from "./_components/KnowledgeCard";
import { ActivityStreamCard } from "./_components/ActivityStreamCard";
import { SystemCostCard } from "./_components/SystemCostCard";
import { DevActivityCard } from "./_components/DevActivityCard";
import { DigitalFootprintCard } from "./_components/DigitalFootprintCard";
import { AgentCostCard } from "./_components/AgentCostCard";

export const dynamic = "force-dynamic";

type Range = "7d" | "30d" | "90d" | "1y";

const VALID_RANGES: Range[] = ["7d", "30d", "90d", "1y"];

function isValidRange(v: string | undefined): v is Range {
  return VALID_RANGES.includes(v as Range);
}

export default async function InsightsPage({
  searchParams,
}: {
  searchParams: Promise<{ range?: string; section?: string; type?: string; cursor?: string }>;
}) {
  const sp = await searchParams;
  const range: Range = isValidRange(sp.range) ? sp.range : "30d";
  const section = sp.section ?? "knowledge";
  const activityType = sp.type;
  const cursor = sp.cursor;

  return (
    <div className="page">
      {/* Header */}
      <div style={{ marginBottom: 24 }}>
        <div className="ds-section-label" style={{ marginBottom: 8, color: "var(--accent)", display: "flex", alignItems: "center", gap: 6 }}>
          <BarChart2 size={12} />
          Insights
        </div>
        <h1 className="ds-h2" style={{ margin: 0 }}>Usage &amp; Activity</h1>
        <p style={{ color: "var(--fg-subtle)", fontSize: "0.875rem", margin: "6px 0 0" }}>
          Understand your knowledge-building habits over time.
        </p>
      </div>

      {/* Time range selector */}
      <RangeSelector range={range} section={section} />

      {/* Layout: sidebar + content */}
      <div style={{ display: "flex", gap: 24, marginTop: 24, alignItems: "flex-start" }}>
        {/* Sidebar nav */}
        <aside style={{ width: 200, flexShrink: 0 }}>
          <InsightsNav range={range} active={section} />
        </aside>

        {/* Main content */}
        <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 24 }}>
          <Suspense fallback={<CardSkeleton />}>
            {section === "knowledge" && <KnowledgeCard range={range} />}
            {section === "activity" && <ActivityStreamCard range={range} type={activityType} cursor={cursor} />}
            {section === "system" && <SystemCostCard range={range} />}
            {section === "agent" && <AgentCostCard />}
            {section === "dev" && <DevActivityCard range={range} />}
            {section === "footprint" && <DigitalFootprintCard range={range} />}
            {/* Default: show all on 'all' or unknown */}
            {!["knowledge", "activity", "system", "agent", "dev", "footprint"].includes(section) && (
              <>
                <KnowledgeCard range={range} />
                <ActivityStreamCard range={range} type={activityType} cursor={cursor} />
                <SystemCostCard range={range} />
                <AgentCostCard />
                <DevActivityCard range={range} />
                <DigitalFootprintCard range={range} />
              </>
            )}
          </Suspense>
        </div>
      </div>
    </div>
  );
}

function RangeSelector({ range, section }: { range: Range; section: string }) {
  const ranges: { value: Range; label: string }[] = [
    { value: "7d", label: "7 days" },
    { value: "30d", label: "30 days" },
    { value: "90d", label: "90 days" },
    { value: "1y", label: "1 year" },
  ];

  return (
    <div style={{ display: "flex", gap: 4, padding: "4px", background: "var(--surface-sunken)", borderRadius: "var(--radius-md)", width: "fit-content" }}>
      {ranges.map(({ value, label }) => (
        <Link
          key={value}
          href={`/insights?range=${value}&section=${section}`}
          style={{
            padding: "6px 14px",
            borderRadius: "calc(var(--radius-md) - 4px)",
            fontSize: "0.8125rem",
            fontWeight: 500,
            textDecoration: "none",
            background: range === value ? "var(--surface-white)" : "transparent",
            color: range === value ? "var(--fg-primary)" : "var(--fg-muted)",
            boxShadow: range === value ? "var(--shadow-card)" : "none",
            transition: "all 120ms ease-out",
          }}
        >
          {label}
        </Link>
      ))}
    </div>
  );
}

function CardSkeleton() {
  return (
    <div style={{
      background: "var(--surface-white)",
      borderRadius: "var(--radius-card)",
      border: "1px solid var(--accent-border)",
      padding: 24,
      display: "flex",
      flexDirection: "column",
      gap: 12,
    }}>
      <div style={{ height: 18, width: "40%", background: "var(--surface-sunken)", borderRadius: 6 }} />
      <div style={{ height: 80, background: "var(--surface-sunken)", borderRadius: 6 }} />
      <div style={{ height: 14, width: "60%", background: "var(--surface-sunken)", borderRadius: 6 }} />
    </div>
  );
}
