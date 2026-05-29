"use client";

import { useState } from "react";
import Link from "next/link";
import { Network, FileText, ArrowRight, List } from "lucide-react";
import { Btn } from "@/components/ui";
import { WikiGraph } from "./WikiGraph";
import type { WikiPage } from "./WikiNav";

// US-051: the /wiki landing leads with the formed knowledge network —
// live concepts & entities plus a graph entry point. Raw draft sources are
// secondary and live in the sidebar "原料" section (see WikiNav).

const TYPE_META: Record<
  WikiPage["type"],
  { label: string; plural: string; chip: string }
> = {
  concept: { label: "Concept", plural: "Concepts", chip: "chip--accent" },
  synthesis: { label: "Synthesis", plural: "Synthesis", chip: "chip--success" },
  entity: { label: "Entity", plural: "Entities", chip: "chip--accent" },
  source: { label: "Source", plural: "Sources", chip: "chip--default" },
  daily: { label: "Daily", plural: "Daily", chip: "chip--default" },
};

// Concepts and entities are the live network's anchors — lead with those.
const FEATURED_ORDER: WikiPage["type"][] = ["concept", "entity", "synthesis"];

function NetworkCard({ page }: { page: WikiPage }) {
  const meta = TYPE_META[page.type];
  return (
    <Link
      href={`/wiki/${page.slug}`}
      className="wiki-landing__card"
      style={{ textDecoration: "none" }}
    >
      <span style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
        <span className={`chip ${meta.chip}`} style={{ fontSize: "0.625rem" }}>
          {meta.label}
        </span>
        {page.backlink_count > 0 && (
          <span className="meta" style={{ color: "var(--fg-subtle)" }}>
            {page.backlink_count} link{page.backlink_count !== 1 ? "s" : ""}
          </span>
        )}
      </span>
      <span className="wiki-landing__card-title">{page.title}</span>
      {page.source_count > 0 && (
        <span style={{ fontSize: "0.75rem", color: "var(--fg-subtle)" }}>
          {page.source_count} source{page.source_count !== 1 ? "s" : ""}
        </span>
      )}
    </Link>
  );
}

function FeaturedSection({
  type,
  pagesInGroup,
}: {
  type: WikiPage["type"];
  pagesInGroup: WikiPage[];
}) {
  if (pagesInGroup.length === 0) return null;
  return (
    <section style={{ marginBottom: "2rem" }}>
      <div
        style={{
          display: "flex",
          alignItems: "baseline",
          justifyContent: "space-between",
          marginBottom: "0.75rem",
        }}
      >
        <h2 className="ds-section-label" style={{ color: "var(--fg-muted)" }}>
          {TYPE_META[type].plural}
        </h2>
        <span className="meta" style={{ color: "var(--fg-subtle)" }}>
          {pagesInGroup.length}
        </span>
      </div>
      <div className="wiki-landing__grid">
        {pagesInGroup.map((p) => (
          <NetworkCard key={p.id} page={p} />
        ))}
      </div>
    </section>
  );
}

export function WikiLanding({ livePages }: { livePages: WikiPage[] }) {
  const [showGraph, setShowGraph] = useState(false);

  const grouped = FEATURED_ORDER.map((type) => ({
    type,
    pages: livePages.filter((p) => p.type === type),
  }));
  const featuredCount = grouped.reduce((n, g) => n + g.pages.length, 0);

  return (
    <div className="wiki-landing">
      {/* Header + graph entry point */}
      <header className="wiki-landing__header">
        <div>
          <h1 className="ds-h2" style={{ margin: 0 }}>
            Your knowledge network
          </h1>
          <p
            className="ds-body-md"
            style={{ color: "var(--fg-muted)", margin: "0.375rem 0 0" }}
          >
            The concepts and entities DayPage has woven from your memos. Raw
            drafts wait in the sidebar under{" "}
            <span style={{ color: "var(--fg-subtle)" }}>待编织 · 原料</span>.
          </p>
        </div>
        <Btn
          kind={showGraph ? "primary" : "secondary"}
          size="sm"
          onClick={() => setShowGraph((v) => !v)}
        >
          {showGraph ? (
            <>
              <List size={14} /> List view
            </>
          ) : (
            <>
              <Network size={14} /> Open graph
            </>
          )}
        </Btn>
      </header>

      {showGraph ? (
        <div className="wiki-landing__graph-frame">
          <WikiGraph />
        </div>
      ) : featuredCount > 0 ? (
        <>
          {grouped.map((g) => (
            <FeaturedSection key={g.type} type={g.type} pagesInGroup={g.pages} />
          ))}
        </>
      ) : (
        // Live pages exist but none are concept/entity/synthesis — still nudge
        // toward the network rather than showing nothing.
        <div
          className="empty-card"
          style={{ padding: "40px 28px", maxWidth: 480, margin: "32px auto 0" }}
        >
          <FileText size={22} className="empty-card__icon" />
          <div className="empty-card__title" style={{ fontSize: 15 }}>
            No live concepts or entities yet
          </div>
          <div className="empty-card__hint">
            Pick a page from the sidebar, or explore the graph to see how your
            notes connect.
          </div>
          <button
            type="button"
            className="btn btn--secondary btn--sm"
            onClick={() => setShowGraph(true)}
            style={{
              marginTop: 12,
              display: "inline-flex",
              alignItems: "center",
              gap: 6,
            }}
          >
            Open graph <ArrowRight size={14} />
          </button>
        </div>
      )}
    </div>
  );
}
