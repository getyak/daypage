// Home view — translated from /tmp/daypage-handoff/.../view-home.jsx.
// Inbox count is now live; other stats remain mock (Round 1 skeleton).
import Link from "next/link";
import { ArrowUpRight, ChevronRight, Sparkles, Inbox } from "lucide-react";
import { Btn, Card, Chip, Icon, SectionLabel, Sparkline } from "@/components/ui";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, inbox_items } from "@/lib/db/schema";
import { eq, and, sql } from "drizzle-orm";

async function getOpenInboxCount(email: string): Promise<number> {
  try {
    const userRows = await db
      .select({ id: users.id })
      .from(users)
      .where(eq(users.email, email))
      .limit(1);
    const userId = userRows[0]?.id;
    if (!userId) return 0;

    const rows = await db
      .select({ count: sql<number>`count(*)::int` })
      .from(inbox_items)
      .where(and(eq(inbox_items.user_id, userId), eq(inbox_items.status, "open")));
    return rows[0]?.count ?? 0;
  } catch {
    return 0;
  }
}

// ── Mock data (mirrors design's DayPage namespace) ────────────────────
type Observation = {
  lead: string;
  body: string[];
  actions: { label: string; kind: "primary" | "soft" | "ghost"; href?: string; disabled?: boolean }[];
};

type RecentRow = { when: string; what: string; subject: string; target: string };

type Domain = { id: string; label: string; count: number; dot: string };

const observations: Observation[] = [
  {
    lead: "I noticed",
    body: [
      "Eight of your last ten inputs land in the same neighbourhood — Raft, Paxos, Spanner clocks, Kafka log compaction. That cluster has grown 3× this week.",
      "You don’t have a Concepts page tying them together yet. Want me to draft one called “Replicated state machines” and link the existing sources?",
    ],
    actions: [
      { label: "Draft the page", kind: "primary", disabled: true },
      { label: "Show what it would link", kind: "soft", disabled: true },
      { label: "Not yet", kind: "ghost", disabled: true },
    ],
  },
  {
    lead: "I’m unsure",
    body: [
      "Two of your sources disagree about whether linearizability subsumes serializability. The 2018 talk says yes; your notes from last month say “they’re orthogonal”.",
      "I’ve been quietly carrying both. Pick one or I’ll keep them as a tracked contradiction.",
    ],
    actions: [
      { label: "Open in Inbox", kind: "soft", href: "/inbox" },
      { label: "Keep tracked", kind: "ghost", disabled: true },
    ],
  },
];

const recent: RecentRow[] = [
  { when: "Just now", what: "Compiled", subject: " “Raft consensus, in plain words” → 3 sources merged into ", target: "Raft (concept)" },
  { when: "12m ago", what: "Linked", subject: " “The end of Moore’s law” essay to ", target: "Hardware substrate (concept)" },
  { when: "1h ago", what: "Drafted", subject: " a synthesis page from your conversation about ", target: "streaming joins" },
  { when: "3h ago", what: "Merged", subject: " 4 voice notes from this morning into ", target: "Daily inbox · 2026-05-10" },
  { when: "Yesterday", what: "Promoted", subject: " highlights from “Designing Data-Intensive Apps” Ch. 9 to ", target: "Linearizability" },
  { when: "2 days ago", what: "Archived", subject: " “Quick read on TPM chips” — no references in 90 days, moved to ", target: "cold storage" },
];

const domainsMock: Domain[] = [
  { id: "distsys", label: "Distributed systems", count: 24, dot: "#5D3000" },
  { id: "mlsystems", label: "ML systems", count: 18, dot: "#7A3F00" },
  { id: "biotech", label: "Biotech weekly", count: 11, dot: "#A66A00" },
  { id: "crm", label: "People & relationships", count: 9, dot: "#4C7A3F" },
];

const sparks: Record<string, number[]> = {
  distsys: [3, 4, 6, 5, 8, 9, 12, 14, 11, 13, 16, 18],
  mlsystems: [2, 3, 3, 4, 4, 5, 6, 7, 8, 9, 9, 11],
  biotech: [1, 2, 2, 3, 4, 4, 5, 6, 6, 7, 8, 8],
  crm: [4, 4, 4, 4, 4, 5, 5, 5, 6, 6, 7, 8],
};

// ── Page ──────────────────────────────────────────────────────────────
export default async function HomePage() {
  const session = await auth();
  const openInboxCount = session?.user?.email
    ? await getOpenInboxCount(session.user.email)
    : 0;
  return (
    <div className="page">
      {/* Hero */}
      <div className="hero">
        <div>
          <div
            className="ds-section-label"
            style={{
              color: "var(--accent)",
              marginBottom: 14,
              display: "inline-flex",
              alignItems: "center",
              gap: 6,
            }}
          >
            <Icon as={Sparkles} size={12} />
            Sun, 10 May 2026 · morning
          </div>
          <h1 className="hero-headline">
            Eight new signals since you logged off.
            <br />
            <span className="accent">Three reshape pages you already cared about.</span>
          </h1>
          <p className="hero-sub">
            I&rsquo;ve compiled what I could. The rest is in the queue, and a couple of things I wasn&rsquo;t sure
            about are sitting in your inbox.
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

        {/* Stats grid (2x2) */}
        <div className="stats">
          <div className="stat">
            <div className="stat__value">147</div>
            <div className="stat__label">Sources</div>
            <div className="stat__delta">+12 this week</div>
          </div>
          <div className="stat">
            <div className="stat__value">84</div>
            <div className="stat__label">Wiki pages</div>
            <div className="stat__delta">+3 this week</div>
          </div>
          <div className="stat">
            <div className="stat__value">12</div>
            <div className="stat__label">Domains</div>
            <div className="stat__delta" style={{ color: "var(--fg-subtle)" }}>+1 proposed</div>
          </div>
          <div className="stat">
            <div className="stat__value">3.2k</div>
            <div className="stat__label">Backlinks</div>
            <div className="stat__delta">+87 this week</div>
          </div>
        </div>
      </div>

      {/* Observations */}
      <div className="mt-32">
        <SectionLabel right={observations.length > 0 ? <Chip tone="accent">{observations.length} new</Chip> : null}>
          What the system noticed
        </SectionLabel>
        {observations.length === 0 ? (
          <Card>
            <div
              style={{
                display: "flex",
                flexDirection: "column",
                alignItems: "center",
                justifyContent: "center",
                gap: 12,
                padding: "48px 24px",
                textAlign: "center",
              }}
            >
              <span style={{ color: "var(--fg-subtle)", opacity: 0.5, display: "flex" }}>
                <Icon as={Sparkles} size={28} />
              </span>
              <p style={{ color: "var(--fg-subtle)", margin: 0, fontSize: "0.9rem" }}>
                No observations yet — start by adding a source
              </p>
              <Link href="/add">
                <Btn kind="ghost" size="sm">Add a source</Btn>
              </Link>
            </div>
          </Card>
        ) : (
          <Card>
            {observations.map((o, i) => (
              <div key={i}>
                <div className="observation">
                  <div className="observation__lead">
                    <span className="pulse" />
                    {o.lead}
                  </div>
                  <div className="observation__body">
                    {o.body.map((p, j) => (
                      <p key={j}>{p}</p>
                    ))}
                    <div className="observation__actions">
                      {o.actions.map((a, k) =>
                        a.href ? (
                          <Link key={k} href={a.href}>
                            <Btn kind={a.kind} size="sm">{a.label}</Btn>
                          </Link>
                        ) : (
                          <Btn
                            key={k}
                            kind={a.kind}
                            size="sm"
                            disabled={a.disabled}
                            title={a.disabled ? "coming soon" : undefined}
                          >
                            {a.label}
                          </Btn>
                        )
                      )}
                    </div>
                  </div>
                </div>
                {i < observations.length - 1 && <div className="divider" />}
              </div>
            ))}
          </Card>
        )}
      </div>

      {/* Recent activity */}
      <div className="mt-32">
        <SectionLabel
          right={
            <Link href="/inbox?filter=compiled">
              <Btn kind="ghost" size="sm" iconRight={<Icon as={ArrowUpRight} size={14} />}>
                Full history
              </Btn>
            </Link>
          }
        >
          Recent activity
        </SectionLabel>
        <Card>
          {recent.map((r, i) => (
            <div className="activity-row" key={i}>
              <div className="when">{r.when}</div>
              <div className="what">
                <strong>{r.what}</strong>
                {r.subject}
                <Link href="/wiki" className="activity-target"><em>{r.target}</em></Link>
              </div>
              <Icon as={ChevronRight} size={14} />
            </div>
          ))}
        </Card>
      </div>

      {/* Domains at a glance */}
      <div className="mt-32">
        <SectionLabel
          right={
            <Btn
              kind="ghost"
              size="sm"
              iconRight={<Icon as={ArrowUpRight} size={14} />}
              disabled
              title="coming soon"
            >
              All domains
            </Btn>
          }
        >
          Domains at a glance
        </SectionLabel>
        <div className="grid-4">
          {domainsMock.map((d) => (
            <Card key={d.id} className="domain-card">
              <div className="flex between center">
                <div className="domain-card__title">{d.label}</div>
                <span
                  style={{
                    background: d.dot,
                    width: 8,
                    height: 8,
                    borderRadius: 999,
                    display: "inline-block",
                  }}
                />
              </div>
              <Sparkline values={sparks[d.id] ?? [3, 4, 5, 6, 7, 8, 9, 10]} color={d.dot} fill w={240} h={32} />
              <div className="flex between center">
                <div className="domain-card__meta">{d.count} pages · 4 sources this week</div>
                <Icon as={ArrowUpRight} size={14} />
              </div>
            </Card>
          ))}
        </div>
      </div>
    </div>
  );
}
