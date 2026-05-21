import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, domains, pages } from "@/lib/db/schema";
import { eq, and, gte, count, sql } from "drizzle-orm";
import { notFound } from "next/navigation";
import Link from "next/link";
import { DomainClientView } from "./DomainClientView";

// ─── Types ────────────────────────────────────────────────────────────────────

type DomainRow = {
  id: string;
  slug: string;
  label: string;
  color: string | null;
  position: number;
  created_at: Date;
};

type PageRow = {
  id: string;
  slug: string;
  type: "concept" | "source" | "entity" | "synthesis" | "daily";
  title: string;
  status: "draft" | "live" | "archived";
  source_count: number;
  backlink_count: number;
  updated_at: Date;
};

type GroupedPages = Record<string, PageRow[]>;

const TYPE_LABELS: Record<string, string> = {
  concept: "Concepts",
  entity: "Entities",
  synthesis: "Syntheses",
  source: "Sources",
  daily: "Daily Pages",
};

const TYPE_COLORS: Record<string, { bg: string; color: string }> = {
  concept:   { bg: "var(--accent-soft)",    color: "var(--accent)" },
  source:    { bg: "var(--surface-sunken)", color: "var(--fg-muted)" },
  entity:    { bg: "var(--accent-soft)",    color: "var(--accent-hover)" },
  synthesis: { bg: "var(--success-soft)",   color: "var(--success)" },
  daily:     { bg: "var(--surface-sunken)", color: "var(--fg-muted)" },
};

const TYPE_ORDER = ["concept", "entity", "synthesis", "source", "daily"];

// ─── Helpers ──────────────────────────────────────────────────────────────────

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

function relativeTime(date: Date): string {
  const diffMs = Date.now() - date.getTime();
  const diffSec = Math.floor(diffMs / 1000);
  if (diffSec < 60) return "just now";
  const diffMin = Math.floor(diffSec / 60);
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffHr = Math.floor(diffMin / 60);
  if (diffHr < 24) return `${diffHr}h ago`;
  const diffDay = Math.floor(diffHr / 24);
  if (diffDay < 30) return `${diffDay}d ago`;
  const diffMo = Math.floor(diffDay / 30);
  if (diffMo < 12) return `${diffMo}mo ago`;
  return `${Math.floor(diffMo / 12)}y ago`;
}

// ─── Data fetching ────────────────────────────────────────────────────────────

async function fetchDomain(userId: string, slug: string): Promise<DomainRow | null> {
  const rows = await db
    .select()
    .from(domains)
    .where(and(eq(domains.user_id, userId), eq(domains.slug, slug)))
    .limit(1);
  return (rows[0] as DomainRow) ?? null;
}

async function fetchDomainPages(userId: string, domainId: string): Promise<PageRow[]> {
  try {
    const rows = await db
      .select({
        id: pages.id,
        slug: pages.slug,
        type: pages.type,
        title: pages.title,
        status: pages.status,
        source_count: pages.source_count,
        backlink_count: pages.backlink_count,
        updated_at: pages.updated_at,
      })
      .from(pages)
      .where(
        and(
          eq(pages.user_id, userId),
          eq(pages.domain_id, domainId)
        )
      )
      .orderBy(pages.type, pages.title);
    return rows as PageRow[];
  } catch {
    return [];
  }
}

async function fetchActivityThisWeek(
  userId: string,
  domainId: string
): Promise<number> {
  try {
    const oneWeekAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000);
    const rows = await db
      .select({ n: count() })
      .from(pages)
      .where(
        and(
          eq(pages.user_id, userId),
          eq(pages.domain_id, domainId),
          gte(pages.updated_at, oneWeekAgo)
        )
      );
    return rows[0]?.n ?? 0;
  } catch {
    return 0;
  }
}

// ─── Page ─────────────────────────────────────────────────────────────────────

export default async function DomainPage({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const session = await auth();
  if (!session?.user?.email) notFound();

  const userId = await resolveUserId(session.user.email);
  if (!userId) notFound();

  const { slug } = await params;
  const domain = await fetchDomain(userId, slug);
  if (!domain) {
    return (
      <div style={{ padding: "2rem 2.5rem", maxWidth: "900px" }}>
        <p
          className="ds-section-label"
          style={{ color: "var(--fg-subtle)", marginBottom: "1.25rem" }}
        >
          <Link href="/home" style={{ color: "inherit", textDecoration: "none" }}>
            DayPage
          </Link>
          {" / Domains"}
        </p>
        <div
          style={{
            marginTop: "2rem",
            padding: "3rem 2rem",
            background: "var(--surface-sunken)",
            borderRadius: "var(--radius-card)",
            border: "1px solid var(--accent-border)",
            textAlign: "center",
            display: "flex",
            flexDirection: "column",
            alignItems: "center",
            gap: "1rem",
          }}
        >
          <p
            style={{
              fontSize: "2rem",
              margin: 0,
              lineHeight: 1,
            }}
          >
            🗂️
          </p>
          <h2
            style={{
              margin: 0,
              fontSize: "1.125rem",
              fontWeight: 600,
              fontFamily: "var(--font-space-grotesk)",
              color: "var(--fg-primary)",
            }}
          >
            Domain not found
          </h2>
          <p
            className="ds-body-md"
            style={{ color: "var(--fg-muted)", margin: 0, maxWidth: "360px" }}
          >
            <code
              style={{
                fontFamily: "var(--font-mono)",
                fontSize: "0.875rem",
                background: "var(--surface-white)",
                border: "1px solid var(--accent-border)",
                borderRadius: "var(--radius-sm)",
                padding: "0.125rem 0.375rem",
              }}
            >
              {slug}
            </code>{" "}
            doesn&apos;t exist. Create a new domain or go back to Home.
          </p>
          <div style={{ display: "flex", gap: "0.75rem", flexWrap: "wrap", justifyContent: "center" }}>
            <Link href="/home" className="btn btn--secondary btn--sm">
              ← Back to Home
            </Link>
          </div>
        </div>
      </div>
    );
  }

  const [domainPages, activityThisWeek] = await Promise.all([
    fetchDomainPages(userId, domain.id),
    fetchActivityThisWeek(userId, domain.id),
  ]);

  const grouped: GroupedPages = {};
  for (const p of domainPages) {
    if (!grouped[p.type]) grouped[p.type] = [];
    grouped[p.type].push(p);
  }

  const orderedTypes = TYPE_ORDER.filter((t) => grouped[t]?.length);

  const color = domain.color ?? "#6366f1";

  return (
    <div style={{ padding: "2rem 2.5rem", maxWidth: "900px" }}>
      {/* Breadcrumb */}
      <p
        className="ds-section-label"
        style={{ color: "var(--fg-subtle)", marginBottom: "1.25rem" }}
      >
        <Link
          href="/home"
          style={{ color: "inherit", textDecoration: "none" }}
        >
          DayPage
        </Link>
        {" / Domains"}
      </p>

      {/* Editable title + color picker */}
      <DomainClientView
        domainId={domain.id}
        initialLabel={domain.label}
        initialColor={color}
      />

      {/* Stats row */}
      <div
        style={{
          display: "flex",
          gap: "1.25rem",
          marginTop: "1.25rem",
          flexWrap: "wrap",
        }}
      >
        <StatChip label="Pages" value={domainPages.length} />
        <StatChip label="Updated this week" value={activityThisWeek} />
        <StatChip
          label="Created"
          value={relativeTime(domain.created_at)}
        />
      </div>

      {/* Pages by type */}
      <div style={{ marginTop: "2rem", display: "flex", flexDirection: "column", gap: "1.75rem" }}>
        {orderedTypes.length === 0 ? (
          <div
            style={{
              padding: "2.5rem 1.5rem",
              background: "var(--surface-sunken)",
              borderRadius: "var(--radius-md)",
              textAlign: "center",
            }}
          >
            <p className="ds-body-md" style={{ color: "var(--fg-muted)", margin: 0 }}>
              No pages in this domain yet. Compile memos to grow it.
            </p>
          </div>
        ) : (
          orderedTypes.map((type) => (
            <TypeGroup
              key={type}
              type={type}
              pagesInGroup={grouped[type]}
            />
          ))
        )}
      </div>
    </div>
  );
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function StatChip({
  label,
  value,
}: {
  label: string;
  value: string | number;
}) {
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        gap: "0.125rem",
        background: "var(--surface-white)",
        border: "1px solid var(--accent-border)",
        borderRadius: "var(--radius-sm)",
        padding: "0.5rem 0.875rem",
        minWidth: "90px",
      }}
    >
      <span
        className="ds-section-label"
        style={{ color: "var(--fg-subtle)", fontSize: "0.6875rem" }}
      >
        {label}
      </span>
      <span
        style={{
          fontSize: "1.125rem",
          fontWeight: 600,
          color: "var(--fg-primary)",
          fontFamily: "var(--font-space-grotesk)",
        }}
      >
        {value}
      </span>
    </div>
  );
}

function TypeGroup({
  type,
  pagesInGroup,
}: {
  type: string;
  pagesInGroup: PageRow[];
}) {
  const colors = TYPE_COLORS[type] ?? {
    bg: "var(--surface-sunken)",
    color: "var(--fg-muted)",
  };

  return (
    <div>
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: "0.5rem",
          marginBottom: "0.625rem",
        }}
      >
        <p
          className="ds-section-label"
          style={{ color: "var(--fg-subtle)", margin: 0 }}
        >
          {TYPE_LABELS[type] ?? type}
        </p>
        <span
          style={{
            fontSize: "0.6875rem",
            fontWeight: 600,
            color: colors.color,
            background: colors.bg,
            padding: "0.125rem 0.4rem",
            borderRadius: "999px",
          }}
        >
          {pagesInGroup.length}
        </span>
      </div>

      <div
        style={{
          background: "var(--surface-white)",
          border: "1px solid var(--accent-border)",
          borderRadius: "var(--radius-md)",
          overflow: "hidden",
        }}
      >
        {pagesInGroup.map((p, i) => (
          <PageRow
            key={p.id}
            page={p}
            isLast={i === pagesInGroup.length - 1}
            typeColors={colors}
          />
        ))}
      </div>
    </div>
  );
}

function relTime(date: Date): string {
  // eslint-disable-next-line react-hooks/purity
  const diffMs = Date.now() - date.getTime();
  const diffMin = Math.floor(diffMs / 60000);
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffHr = Math.floor(diffMin / 60);
  if (diffHr < 24) return `${diffHr}h ago`;
  return `${Math.floor(diffHr / 24)}d ago`;
}

function PageRow({
  page,
  isLast,
  typeColors,
}: {
  page: PageRow;
  isLast: boolean;
  typeColors: { bg: string; color: string };
}) {
  return (
    <Link
      href={`/wiki/${page.slug}`}
      style={{
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        padding: "0.6875rem 1rem",
        textDecoration: "none",
        borderBottom: isLast ? "none" : "1px solid var(--accent-border)",
        transition: "background 100ms",
      }}
      className="page-row-link"
    >
      <div style={{ display: "flex", flexDirection: "column", gap: "0.125rem", minWidth: 0 }}>
        <span
          style={{
            fontSize: "0.9375rem",
            fontWeight: 500,
            color: "var(--fg-primary)",
            overflow: "hidden",
            textOverflow: "ellipsis",
            whiteSpace: "nowrap",
          }}
        >
          {page.title}
        </span>
        <span
          className="ds-mono-11"
          style={{ color: "var(--fg-subtle)", fontSize: "0.75rem" }}
        >
          {page.source_count} sources · {page.backlink_count} backlinks
        </span>
      </div>

      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: "0.5rem",
          flexShrink: 0,
          marginLeft: "1rem",
        }}
      >
        {page.status === "draft" && (
          <span
            style={{
              fontSize: "0.6875rem",
              fontWeight: 600,
              background: "var(--warning-soft)",
              color: "var(--warning)",
              padding: "0.125rem 0.4rem",
              borderRadius: "999px",
            }}
          >
            draft
          </span>
        )}
        <span
          className="ds-mono-11"
          style={{ color: "var(--fg-subtle)", whiteSpace: "nowrap" }}
        >
          {relTime(page.updated_at)}
        </span>
      </div>
    </Link>
  );
}
