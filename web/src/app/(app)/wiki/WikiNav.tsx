"use client";

import { useState, useEffect, useCallback } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import {
  ChevronDown,
  ChevronRight,
  Search,
  List,
  Network,
  AlertTriangle,
  FileText,
} from "lucide-react";

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
      style={{
        display: "flex",
        alignItems: "center",
        gap: "0.5rem",
        padding: "0.3125rem 0.75rem 0.3125rem 1.25rem",
        borderRadius: "var(--radius-sm)",
        textDecoration: "none",
        background: isActive ? "var(--accent-soft)" : "transparent",
        transition: "background 100ms ease-out",
      }}
    >
      <FileText
        size={13}
        style={{ color: "var(--fg-subtle)", flexShrink: 0 }}
      />
      <span
        style={{
          flex: 1,
          fontSize: "0.8125rem",
          fontWeight: isActive ? 500 : 400,
          color: isActive ? "var(--accent)" : "var(--fg-primary)",
          overflow: "hidden",
          textOverflow: "ellipsis",
          whiteSpace: "nowrap",
        }}
      >
        {page.title}
      </span>
      <span
        style={{
          display: "flex",
          alignItems: "center",
          gap: "0.25rem",
          flexShrink: 0,
        }}
      >
        {isDraft && (
          <span
            style={{
              fontSize: "0.625rem",
              fontWeight: 600,
              color: "var(--warning)",
              background: "var(--warning-soft)",
              padding: "0.0625rem 0.3125rem",
              borderRadius: "999px",
              letterSpacing: "0.03em",
              textTransform: "uppercase",
            }}
          >
            draft
          </span>
        )}
        {page.source_count > 0 && !isDraft && (
          <span
            style={{
              fontSize: "0.6875rem",
              color: "var(--fg-subtle)",
            }}
          >
            {page.source_count}
          </span>
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
    <div>
      <button
        onClick={() => onToggle(type)}
        style={{
          display: "flex",
          alignItems: "center",
          gap: "0.375rem",
          width: "100%",
          padding: "0.3125rem 0.75rem",
          background: "transparent",
          border: "none",
          cursor: "pointer",
          borderRadius: "var(--radius-sm)",
        }}
      >
        {collapsed ? (
          <ChevronRight size={13} style={{ color: "var(--fg-subtle)" }} />
        ) : (
          <ChevronDown size={13} style={{ color: "var(--fg-subtle)" }} />
        )}
        <span
          className="ds-section-label"
          style={{ flex: 1, textAlign: "left", color: "var(--fg-subtle)" }}
        >
          {TYPE_LABELS[type]}
        </span>
        <span
          style={{
            fontSize: "0.6875rem",
            color: "var(--fg-subtle)",
            background: "var(--surface-sunken)",
            padding: "0.0625rem 0.3125rem",
            borderRadius: "999px",
          }}
        >
          {pagesInGroup.length}
        </span>
      </button>

      {!collapsed && (
        <div style={{ marginBottom: "0.25rem" }}>
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

export function WikiNav({ initialPages }: { initialPages: WikiPage[] }) {
  const pathname = usePathname();
  const [query, setQuery] = useState("");
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});

  useEffect(() => {
    setCollapsed(loadCollapsed());
  }, []);

  const toggleGroup = useCallback(
    (type: WikiPage["type"]) => {
      setCollapsed((prev) => {
        const next = { ...prev, [type]: !prev[type] };
        saveCollapsed(next);
        return next;
      });
    },
    []
  );

  const filtered = query.trim()
    ? initialPages.filter((p) =>
        p.title.toLowerCase().includes(query.toLowerCase())
      )
    : initialPages;

  const grouped = TYPE_ORDER.reduce<GroupedPages>(
    (acc, type) => {
      acc[type] = filtered.filter((p) => p.type === type);
      return acc;
    },
    { concept: [], source: [], entity: [], synthesis: [], daily: [] }
  );

  const totalPages = initialPages.length;

  return (
    <div
      style={{
        width: "240px",
        flexShrink: 0,
        borderRight: "1px solid var(--accent-border)",
        background: "var(--surface-white)",
        display: "flex",
        flexDirection: "column",
        height: "100%",
        overflowY: "auto",
      }}
    >
      {/* Search + mode toggle */}
      <div
        style={{
          padding: "0.875rem 0.75rem 0.625rem",
          borderBottom: "1px solid var(--accent-border)",
          display: "flex",
          flexDirection: "column",
          gap: "0.5rem",
        }}
      >
        {/* Search */}
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: "0.375rem",
            background: "var(--surface-sunken)",
            borderRadius: "var(--radius-sm)",
            padding: "0.375rem 0.625rem",
          }}
        >
          <Search size={13} style={{ color: "var(--fg-subtle)", flexShrink: 0 }} />
          <input
            type="text"
            placeholder="Search pages..."
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            style={{
              flex: 1,
              border: "none",
              background: "transparent",
              outline: "none",
              fontSize: "0.8125rem",
              color: "var(--fg-primary)",
            }}
          />
        </div>

        {/* List / Graph toggle */}
        <div
          style={{
            display: "flex",
            gap: "0.25rem",
          }}
        >
          <button
            style={{
              display: "flex",
              alignItems: "center",
              gap: "0.3125rem",
              padding: "0.3125rem 0.625rem",
              borderRadius: "var(--radius-sm)",
              border: "none",
              cursor: "pointer",
              fontSize: "0.75rem",
              fontWeight: 500,
              background: "var(--accent-soft)",
              color: "var(--accent)",
              flex: 1,
              justifyContent: "center",
            }}
          >
            <List size={13} />
            List
          </button>
          <button
            disabled
            title="Coming soon"
            style={{
              display: "flex",
              alignItems: "center",
              gap: "0.3125rem",
              padding: "0.3125rem 0.625rem",
              borderRadius: "var(--radius-sm)",
              border: "none",
              cursor: "not-allowed",
              fontSize: "0.75rem",
              fontWeight: 500,
              background: "transparent",
              color: "var(--fg-subtle)",
              opacity: 0.5,
              flex: 1,
              justifyContent: "center",
            }}
          >
            <Network size={13} />
            Graph
          </button>
        </div>
      </div>

      {/* Page groups */}
      <div
        style={{
          flex: 1,
          overflowY: "auto",
          padding: "0.625rem 0",
        }}
      >
        {totalPages === 0 ? (
          <div
            style={{
              padding: "1.5rem 1rem",
              textAlign: "center",
            }}
          >
            <p
              className="ds-body-md"
              style={{ color: "var(--fg-subtle)", fontSize: "0.8125rem" }}
            >
              Your wiki will grow here as AI compiles your memos
            </p>
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
      </div>
    </div>
  );
}
