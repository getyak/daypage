// Home view — stats, activities, inbox observations, and domains wired to real data.
import Link from "next/link";
import { ArrowUpRight, ChevronRight, Sparkles, Inbox, Activity, Clock } from "lucide-react";
import { Btn, Card, Chip, Icon, SectionLabel, Sparkline } from "@/components/ui";
import { ColdStartGuide } from "./ColdStartGuide";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, inbox_items, memos, pages, domains, page_links, activities } from "@/lib/db/schema";
import { eq, and, gte, desc, sql } from "drizzle-orm";

// How many sources we suggest before the graph starts weaving itself. Used only
// to phrase the cold-start guidance — kept small and encouraging.
const WEAVE_HINT_TARGET = 3;

// ── Data helpers ──────────────────────────────────────────────────────────────

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

type StatsData = {
  sources: number;
  pages: number;
  domainCount: number;
  backlinks: number;
  sources_week: number;
  pages_week: number;
  backlinks_week: number;
};

async function getStats(userId: string): Promise<StatsData> {
  const oneWeekAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000);
  try {
    const [sourcesRes, pagesRes, domainsRes, backlinksRes, swRes, pwRes, bwRes] =
      await Promise.all([
        db.select({ count: sql<number>`count(*)::int` }).from(memos).where(eq(memos.user_id, userId)),
        db.select({ count: sql<number>`count(*)::int` }).from(pages).where(eq(pages.user_id, userId)),
        db.select({ count: sql<number>`count(*)::int` }).from(domains).where(eq(domains.user_id, userId)),
        db.select({ count: sql<number>`count(*)::int` }).from(page_links).where(eq(page_links.user_id, userId)),
        db.select({ count: sql<number>`count(*)::int` }).from(memos).where(and(eq(memos.user_id, userId), gte(memos.created_at, oneWeekAgo))),
        db.select({ count: sql<number>`count(*)::int` }).from(pages).where(and(eq(pages.user_id, userId), gte(pages.created_at, oneWeekAgo))),
        db.select({ count: sql<number>`count(*)::int` }).from(page_links).where(and(eq(page_links.user_id, userId), gte(page_links.created_at, oneWeekAgo))),
      ]);
    return {
      sources: sourcesRes[0]?.count ?? 0,
      pages: pagesRes[0]?.count ?? 0,
      domainCount: domainsRes[0]?.count ?? 0,
      backlinks: backlinksRes[0]?.count ?? 0,
      sources_week: swRes[0]?.count ?? 0,
      pages_week: pwRes[0]?.count ?? 0,
      backlinks_week: bwRes[0]?.count ?? 0,
    };
  } catch {
    return { sources: 0, pages: 0, domainCount: 0, backlinks: 0, sources_week: 0, pages_week: 0, backlinks_week: 0 };
  }
}

type ActivityRow = {
  id: string;
  verb: string;
  subject: string;
  target_type: string | null;
  target_id: string | null;
  created_at: Date;
};

async function getActivities(userId: string): Promise<ActivityRow[]> {
  try {
    return await db
      .select()
      .from(activities)
      .where(eq(activities.user_id, userId))
      .orderBy(desc(activities.created_at))
      .limit(6);
  } catch {
    return [];
  }
}

type InboxItemRow = {
  id: string;
  kind: string;
  title: string;
  body: string | null;
  created_at: Date;
};

async function getOpenInboxItems(userId: string): Promise<{ items: InboxItemRow[]; total: number }> {
  try {
    const [countRes, rows] = await Promise.all([
      db.select({ count: sql<number>`count(*)::int` }).from(inbox_items).where(and(eq(inbox_items.user_id, userId), eq(inbox_items.status, "open"))),
      db
        .select({ id: inbox_items.id, kind: inbox_items.kind, title: inbox_items.title, body: inbox_items.body, created_at: inbox_items.created_at })
        .from(inbox_items)
        .where(and(eq(inbox_items.user_id, userId), eq(inbox_items.status, "open")))
        .orderBy(desc(inbox_items.created_at))
        .limit(3),
    ]);
    return { items: rows, total: countRes[0]?.count ?? 0 };
  } catch {
    return { items: [], total: 0 };
  }
}

type DomainRow = {
  id: string;
  slug: string;
  label: string;
  color: string | null;
  created_at: Date;
};

async function getDomains(userId: string): Promise<DomainRow[]> {
  try {
    return await db
      .select({ id: domains.id, slug: domains.slug, label: domains.label, color: domains.color, created_at: domains.created_at })
      .from(domains)
      .where(eq(domains.user_id, userId))
      .orderBy(domains.position, domains.created_at)
      .limit(8);
  } catch {
    return [];
  }
}

// ── Formatting helpers ────────────────────────────────────────────────────────

function formatRelative(date: Date): string {
  const diffMs = Date.now() - date.getTime();
  const diffMin = Math.floor(diffMs / 60_000);
  if (diffMin < 1) return "Just now";
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffH = Math.floor(diffMin / 60);
  if (diffH < 24) return `${diffH}h ago`;
  const diffD = Math.floor(diffH / 24);
  if (diffD === 1) return "Yesterday";
  return `${diffD} days ago`;
}

function kindLabel(kind: string): string {
  switch (kind) {
    case "contradiction": return "Contradiction";
    case "schema": return "Schema";
    case "orphan": return "Orphan";
    case "compiled": return "Compiled";
    default: return kind;
  }
}

// ── Page ──────────────────────────────────────────────────────────────────────

export default async function HomePage() {
  const session = await auth();
  const userId = session?.user?.email ? await resolveUserId(session.user.email) : null;

  const [stats, recentActivities, inboxData, domainList] = userId
    ? await Promise.all([
        getStats(userId),
        getActivities(userId),
        getOpenInboxItems(userId),
        getDomains(userId),
      ])
    : [
        { sources: 0, pages: 0, domainCount: 0, backlinks: 0, sources_week: 0, pages_week: 0, backlinks_week: 0 },
        [] as ActivityRow[],
        { items: [] as InboxItemRow[], total: 0 },
        [] as DomainRow[],
      ];

  const openInboxCount = inboxData.total;

  // Cold-start: no knowledge network has formed yet (no domains, no backlinks).
  // Replace the bare zeros with explicit guidance + a concrete next step.
  const isColdStart = stats.domainCount === 0 && stats.backlinks === 0;
  const sourcesToWeave = Math.max(WEAVE_HINT_TARGET - stats.sources, 1);

  return (
    <div className="page">
      {/* Hero */}
      <div className="hero">
        <div>
          <div
            className="ds-section-label"
            style={{ color: "var(--accent)", marginBottom: 14, display: "inline-flex", alignItems: "center", gap: 6 }}
          >
            <Icon as={Sparkles} size={12} />
            {new Date().toLocaleDateString("en-US", { weekday: "short", day: "numeric", month: "long", year: "numeric" })}
          </div>
          <h1 className="hero-headline">
            Your personal knowledge base.
            <br />
            <span className="accent">Everything compiled and connected.</span>
          </h1>
          <p className="hero-sub">
            Add sources and I&rsquo;ll compile them into your wiki. Check the inbox for things that need your attention.
          </p>
          <div className="flex gap-12 mt-24">
            <Link href="/add"><Btn kind="primary">Add something</Btn></Link>
            <Link href="/chat"><Btn kind="soft">Ask the wiki</Btn></Link>
            <Link href="/inbox">
              <Btn kind="ghost" icon={<Inbox size={14} />}>
                {openInboxCount > 0 ? `${openInboxCount} in inbox` : "Inbox"}
              </Btn>
            </Link>
          </div>
        </div>

        {/* Stats grid (2×2) — US-002 */}
        <div className="stats">
          <div className="stat">
            <div className="stat__value">{stats.sources}</div>
            <div className="stat__label">Sources</div>
            <div className="stat__delta">+{stats.sources_week} this week</div>
          </div>
          <div className="stat">
            <div className="stat__value">{stats.pages}</div>
            <div className="stat__label">Wiki pages</div>
            <div className="stat__delta">+{stats.pages_week} this week</div>
          </div>
          <div className="stat">
            <div className="stat__value">{stats.domainCount}</div>
            <div className="stat__label">Domains</div>
            <div className="stat__delta" style={{ color: "var(--fg-subtle)" }}>across your topics</div>
          </div>
          <div className="stat">
            <div className="stat__value">{stats.backlinks}</div>
            <div className="stat__label">Backlinks</div>
            <div className="stat__delta">+{stats.backlinks_week} this week</div>
          </div>
        </div>
      </div>

      {/* Cold-start guidance — US-052: replace bare zeros with a clear next step */}
      {isColdStart && (
        <div className="mt-32">
          <ColdStartGuide sourcesToWeave={sourcesToWeave} />
        </div>
      )}

      {/* Observations — US-004 */}
      <div className="mt-32">
        <SectionLabel
          right={
            openInboxCount > 0 ? (
              <Link href="/inbox">
                <Chip tone="accent">{openInboxCount} open</Chip>
              </Link>
            ) : null
          }
        >
          What the system noticed
        </SectionLabel>
        {inboxData.items.length === 0 ? (
          <Card>
            <div style={{ display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 12, padding: "48px 24px", textAlign: "center" }}>
              <span style={{ color: "var(--fg-subtle)", opacity: 0.5, display: "flex" }}>
                <Icon as={Sparkles} size={28} />
              </span>
              <p style={{ color: "var(--fg-subtle)", margin: 0, fontSize: "0.9rem" }}>
                No pending observations
              </p>
              <Link href="/add">
                <Btn kind="ghost" size="sm">Add a source</Btn>
              </Link>
            </div>
          </Card>
        ) : (
          <Card>
            {inboxData.items.map((item, i) => (
              <div key={item.id}>
                <Link href="/inbox" style={{ textDecoration: "none", color: "inherit" }}>
                  <div className="observation">
                    <div className="observation__lead">
                      <span className="pulse" />
                      {kindLabel(item.kind)}
                    </div>
                    <div className="observation__body">
                      <p style={{ fontWeight: 500, margin: "0 0 4px" }}>{item.title}</p>
                      {item.body && <p style={{ color: "var(--fg-subtle)", margin: 0, fontSize: "0.875rem" }}>{item.body}</p>}
                      <div style={{ display: "flex", alignItems: "center", gap: 4, marginTop: 6, color: "var(--fg-subtle)", fontSize: "0.8rem" }}>
                        <Icon as={Clock} size={11} />
                        {formatRelative(item.created_at)}
                      </div>
                    </div>
                  </div>
                </Link>
                {i < inboxData.items.length - 1 && <div className="divider" />}
              </div>
            ))}
            {openInboxCount > inboxData.items.length && (
              <div style={{ padding: "12px 16px", borderTop: "1px solid var(--border)" }}>
                <Link href="/inbox">
                  <Btn kind="ghost" size="sm" iconRight={<Icon as={ArrowUpRight} size={14} />}>
                    View all {openInboxCount} observations
                  </Btn>
                </Link>
              </div>
            )}
          </Card>
        )}
      </div>

      {/* Recent activity — US-003 */}
      <div className="mt-32">
        <SectionLabel
          right={
            <Link href="/inbox?filter=compiled">
              <Btn kind="ghost" size="sm" iconRight={<Icon as={ArrowUpRight} size={14} />}>
                View all
              </Btn>
            </Link>
          }
        >
          Recent activity
        </SectionLabel>
        {recentActivities.length === 0 ? (
          <Card>
            <div style={{ display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 12, padding: "48px 24px", textAlign: "center" }}>
              <span style={{ color: "var(--fg-subtle)", opacity: 0.5, display: "flex" }}>
                <Icon as={Activity} size={28} />
              </span>
              <p style={{ color: "var(--fg-subtle)", margin: 0, fontSize: "0.9rem" }}>
                No recent activity — start by adding a memo
              </p>
              <Link href="/add">
                <Btn kind="ghost" size="sm">Add a memo</Btn>
              </Link>
            </div>
          </Card>
        ) : (
          <Card>
            {recentActivities.map((a) => (
              <div className="activity-row" key={a.id}>
                <div className="when">{formatRelative(a.created_at)}</div>
                <div className="what">
                  <strong>{a.verb}</strong>
                  {" "}
                  {a.subject}
                  {a.target_id && a.target_type === "page" && (
                    <Link href={`/wiki/${a.target_id}`} className="activity-target"><em>{a.target_id}</em></Link>
                  )}
                </div>
                <Icon as={ChevronRight} size={14} />
              </div>
            ))}
          </Card>
        )}
      </div>

      {/* Domains at a glance — US-005 */}
      <div className="mt-32">
        <SectionLabel
          right={
            <Link href="/insights">
              <Btn kind="ghost" size="sm" iconRight={<Icon as={ArrowUpRight} size={14} />}>
                All domains
              </Btn>
            </Link>
          }
        >
          Domains at a glance
        </SectionLabel>
        {domainList.length === 0 ? (
          <Card>
            <div style={{ display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 12, padding: "48px 24px", textAlign: "center" }}>
              <p style={{ color: "var(--fg-subtle)", margin: 0, fontSize: "0.9rem" }}>No domains yet</p>
            </div>
          </Card>
        ) : (
          <div className="grid-4">
            {domainList.map((d) => (
              <Link key={d.id} href={`/insights?domain=${d.slug}`} style={{ textDecoration: "none" }}>
                <Card className="domain-card">
                  <div className="flex between center">
                    <div className="domain-card__title">{d.label}</div>
                    <span
                      style={{
                        background: d.color ?? "#888",
                        width: 8,
                        height: 8,
                        borderRadius: 999,
                        display: "inline-block",
                      }}
                    />
                  </div>
                  <Sparkline values={[3, 4, 5, 6, 7, 8, 9, 10]} color={d.color ?? "#888"} fill w={240} h={32} />
                  <div className="flex between center">
                    <div className="domain-card__meta">
                      {new Date(d.created_at).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" })}
                    </div>
                    <Icon as={ArrowUpRight} size={14} />
                  </div>
                </Card>
              </Link>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
