"use client";

import { useState, useEffect, useCallback } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import {
  ChevronDown,
  ChevronRight,
  Search,
  AlertTriangle,
  FileText,
  Inbox,
} from "lucide-react";

export type WikiMode = "list" | "graph";

export type WikiPage = {
  id: string;
  slug: string;
  type: "concept" | "source" | "entity" | "synthesis" | "daily";
  title: string;
  status: "draft" | "live" | "archived";
  domain_id: string | null;
  source_count: number;
  backlink_count: number;
  last_compiled_at: string | null;
  updated_at: string;
};

type GroupedPages = Record<WikiPage["type"], WikiPage[]>;

const TYPE_LABELS: Record<WikiPage["type"], string> = {
  concept: "Concepts",
  source: "Sources",
  entity: "Entities",
  synthesis: "Synthesis",
  daily: "Daily",
};

const TYPE_ORDER: WikiPage["type"][] = [
  "concept",
  "synthesis",
  "entity",
  "source",
  "daily",
];

const COLLAPSED_KEY = "wiki-nav-collapsed";

function loadCollapsed(): Record<string, boolean> {
  if (typeof window === "undefined") return {};
  try {
    return JSON.parse(localStorage.getItem(COLLAPSED_KEY) ?? "{}") as Record<
      string,
      boolean
    >;
  } catch {
    return {};
  }
}

function saveCollapsed(state: Record<string, boolean>) {
  try {
    localStorage.setItem(COLLAPSED_KEY, JSON.stringify(state));
  } catch {
    // ignore
  }
}

function PageRow({ page, isActive }: { page: WikiPage; isActive: boolean }) {
  const isDraft = page.status === "draft";

  return (
    <Link
      href={`/wiki/${page.slug}`}
      className={isActive ? "wiki__nav-item is-active" : "wiki__nav-item"}
    >
      <span
        style={{
          display: "inline-flex",
          alignItems: "center",
          gap: "0.5rem",
          minWidth: 0,
          flex: 1,
        }}
      >
        <FileText size={13} style={{ flexShrink: 0, opacity: 0.7 }} />
        <span
          style={{
            overflow: "hidden",
            textOverflow: "ellipsis",
            whiteSpace: "nowrap",
          }}
        >
          {page.title}
        </span>
      </span>
      <span
        style={{
          display: "inline-flex",
          alignItems: "center",
          gap: "0.375rem",
          flexShrink: 0,
        }}
      >
        {isDraft && (
          <span
            className="chip chip--warning"
            style={{
              fontSize: "0.625rem",
              padding: "0.0625rem 0.3125rem",
              textTransform: "uppercase",
              letterSpacing: "0.03em",
            }}
          >
            draft
          </span>
        )}
        {page.source_count > 0 && !isDraft && (
          <span className="meta">{page.source_count}</span>
        )}
        {page.backlink_count > 1 && (
          <AlertTriangle
            size={10}
            style={{ color: "var(--warning)", opacity: 0.7 }}
          />
        )}
      </span>
    </Link>
  );
}

function PageGroup({
  type,
  pagesInGroup,
  activePath,
  collapsed,
  onToggle,
}: {
  type: WikiPage["type"];
  pagesInGroup: WikiPage[];
  activePath: string;
  collapsed: boolean;
  onToggle: (type: WikiPage["type"]) => void;
}) {
  if (pagesInGroup.length === 0) return null;

  return (
    <div className="wiki__group">
      <button
        onClick={() => onToggle(type)}
        className="wiki__group-head"
        style={{
          width: "100%",
          background: "transparent",
          border: "none",
          cursor: "pointer",
        }}
      >
        <span
          style={{ display: "inline-flex", alignItems: "center", gap: "0.375rem" }}
        >
          {collapsed ? (
            <ChevronRight size={13} style={{ color: "var(--fg-subtle)" }} />
          ) : (
            <ChevronDown size={13} style={{ color: "var(--fg-subtle)" }} />
          )}
          <span className="ds-section-label" style={{ color: "var(--fg-subtle)" }}>
            {TYPE_LABELS[type]}
          </span>
        </span>
        <span className="meta">{pagesInGroup.length}</span>
      </button>

      {!collapsed && (
        <div>
          {pagesInGroup.map((page) => (
            <PageRow
              key={page.id}
              page={page}
              isActive={activePath === `/wiki/${page.slug}`}
            />
          ))}
        </div>
      )}
    </div>
  );
}

export function WikiNav({
  initialPages,
  draftPages = [],
}: {
  initialPages: WikiPage[];
  draftPages?: WikiPage[];
  mode?: WikiMode;
  onModeChange?: (m: WikiMode) => void;
}) {
  const pathname = usePathname();
  const [query, setQuery] = useState("");
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});
  const [showDrafts, setShowDrafts] = useState(false);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setCollapsed(loadCollapsed());
  }, []);

  const toggleGroup = useCallback((type: WikiPage["type"]) => {
    setCollapsed((prev) => {
      const next = { ...prev, [type]: !prev[type] };
      saveCollapsed(next);
      return next;
    });
  }, []);

  const matchesQuery = useCallback(
    (p: WikiPage) =>
      !query.trim() || p.title.toLowerCase().includes(query.toLowerCase()),
    [query]
  );

  const filtered = initialPages.filter(matchesQuery);
  const filteredDrafts = draftPages.filter(matchesQuery);

  const grouped = TYPE_ORDER.reduce<GroupedPages>(
    (acc, type) => {
      acc[type] = filtered.filter((p) => p.type === type);
      return acc;
    },
    { concept: [], source: [], entity: [], synthesis: [], daily: [] }
  );

  const totalPages = initialPages.length;

  return (
    <>
      <div className="wiki__search">
        <Search size={13} style={{ color: "var(--fg-subtle)", flexShrink: 0 }} />
        <input
          type="text"
          placeholder="Search wiki"
          aria-label="Search wiki"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
      </div>

      {totalPages === 0 ? (
        <div
          className="wiki__group"
          style={{
            marginTop: 18,
            padding: "14px 12px",
            border: "1px dashed var(--border-subtle)",
            borderRadius: 14,
            background: "transparent",
          }}
        >
          <div
            className="ds-section-label"
            style={{ color: "var(--fg-subtle-aa)", marginBottom: 6 }}
          >
            Knowledge layers
          </div>
          <p
            style={{
              fontSize: 12.5,
              lineHeight: 1.55,
              color: "var(--fg-muted)",
              margin: 0,
            }}
          >
            Concepts · Synthesis · Entities · Sources will appear here once
            tonight&apos;s compile weaves your raw memos into a network.
          </p>
          <div
            style={{
              marginTop: 10,
              display: "flex",
              flexWrap: "wrap",
              gap: 6,
            }}
          >
            {(["concept", "synthesis", "entity", "source"] as const).map((type) => (
              <span
                key={type}
                className="ds-mono-11"
                style={{
                  padding: "2px 8px",
                  borderRadius: 999,
                  background: "var(--surface-sunken)",
                  color: "var(--fg-subtle-aa)",
                  letterSpacing: "0.04em",
                }}
              >
                {TYPE_LABELS[type] ?? type}
              </span>
            ))}
          </div>
        </div>
      ) : (
        TYPE_ORDER.map((type) => (
          <PageGroup
            key={type}
            type={type}
            pagesInGroup={grouped[type]}
            activePath={pathname}
            collapsed={!!collapsed[type]}
            onToggle={toggleGroup}
          />
        ))
      )}

      {draftPages.length > 0 && (
        <div className="wiki__group" style={{ marginTop: 18 }}>
          <button
            onClick={() => setShowDrafts((v) => !v)}
            className="wiki__group-head"
            aria-expanded={showDrafts}
            style={{
              width: "100%",
              background: "transparent",
              border: "none",
              cursor: "pointer",
            }}
          >
            <span
              style={{
                display: "inline-flex",
                alignItems: "center",
                gap: "0.375rem",
              }}
            >
              {showDrafts ? (
                <ChevronDown size={13} style={{ color: "var(--fg-subtle)" }} />
              ) : (
                <ChevronRight size={13} style={{ color: "var(--fg-subtle)" }} />
              )}
              <Inbox size={12} style={{ color: "var(--fg-subtle)" }} />
              <span
                className="ds-section-label"
                style={{ color: "var(--fg-subtle)" }}
              >
                待编织 · 原料
              </span>
            </span>
            <span className="meta">{draftPages.length}</span>
          </button>

          {showDrafts && (
            <div>
              {filteredDrafts.length === 0 ? (
                <div
                  style={{
                    padding: "6px 10px",
                    fontSize: 12,
                    color: "var(--fg-subtle)",
                    fontStyle: "italic",
                  }}
                >
                  没有匹配的草稿
                </div>
              ) : (
                filteredDrafts.map((page) => (
                  <PageRow
                    key={page.id}
                    page={page}
                    isActive={pathname === `/wiki/${page.slug}`}
                  />
                ))
              )}
            </div>
          )}
        </div>
      )}
    </>
  );
}
