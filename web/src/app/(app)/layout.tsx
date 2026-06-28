import { ReactNode } from "react";
import { auth, signOut } from "@/lib/auth/session";
import { redirect } from "next/navigation";
import Link from "next/link";
import { db } from "@/lib/db/client";
import { users, domains, inbox_items } from "@/lib/db/schema";
import { eq, and, sql } from "drizzle-orm";
import type { Domain } from "@/lib/db/schema";
import { NavItem, NavItemLink, type NavIconName } from "./_components/NavItem";
import { SystemRow } from "./_components/SystemRow";
import { TopbarDate } from "./_components/TopbarDate";
import { NewDomainButton } from "./_components/NewDomainButton";
import { MobileSidebarDrawer, HamburgerButton } from "./_components/MobileSidebarDrawer";
import { DesktopSidebarShell } from "./_components/DesktopSidebarShell";
import { BreadcrumbLabel } from "./_components/BreadcrumbLabel";

type NavSpec = { href: string; label: string; iconName: NavIconName; meta?: string };

const NAV_ITEMS: ReadonlyArray<NavSpec> = [
  { href: "/home", label: "Home", iconName: "home", meta: "⌘1" },
  { href: "/add", label: "Add", iconName: "plus", meta: "⌘N" },
  { href: "/chat", label: "Chat", iconName: "message", meta: "⌘K" },
  { href: "/agents", label: "Agents", iconName: "bot" },
  { href: "/orbit", label: "Orbit", iconName: "orbit" },
  { href: "/wiki", label: "Wiki", iconName: "book", meta: "⌘W" },
  { href: "/inbox", label: "Inbox", iconName: "inbox" },
  { href: "/insights", label: "Insights", iconName: "chart" },
];

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

async function fetchSidebarData(userId: string): Promise<{
  userDomains: Domain[];
  openInboxCount: number;
}> {
  const [userDomains, inboxResult] = await Promise.all([
    db
      .select()
      .from(domains)
      .where(eq(domains.user_id, userId))
      .orderBy(domains.position, domains.created_at),
    db
      .select({ count: sql<number>`count(*)::int` })
      .from(inbox_items)
      .where(
        and(
          eq(inbox_items.user_id, userId),
          eq(inbox_items.status, "open")
        )
      ),
  ]);

  return {
    userDomains,
    openInboxCount: inboxResult[0]?.count ?? 0,
  };
}

export default async function AppLayout({ children }: { children: ReactNode }) {
  const session = await auth();
  if (!session?.user) redirect("/login");

  let userDomains: Domain[] = [];
  let openInboxCount = 0;

  if (session.user.email) {
    const userId = await resolveUserId(session.user.email);
    if (userId) {
      const data = await fetchSidebarData(userId);
      userDomains = data.userDomains;
      openInboxCount = data.openInboxCount;
    }
  }

  const sidebarContent = (
    <>
      {/* Brand */}
      <div className="sb__brand">
        <div
          className="sb__brand-mark"
          style={{
            fontFamily: "var(--font-fraunces), var(--font-family-serif), serif",
            fontWeight: 500,
            fontSize: 19,
            letterSpacing: "-0.01em",
            color: "var(--fg-primary)",
            textTransform: "none",
          }}
        >
          DayPage
        </div>
        <div className="sb__brand-tag">v0.4 · private</div>
      </div>

      {/* Primary nav */}
      <nav aria-label="Main navigation">
        {NAV_ITEMS.map(({ href, label, iconName, meta }) => {
          const isInbox = label === "Inbox";
          const badge = isInbox && openInboxCount > 0 ? openInboxCount : undefined;
          return (
            <NavItem
              key={href}
              href={href}
              label={label}
              iconName={iconName}
              badge={badge}
              meta={badge === undefined ? meta : undefined}
            />
          );
        })}
      </nav>

      {/* Domains group */}
      <div className="sb__group-label">
        <span>Domains</span>
        {userDomains.length > 0 && (
          <span className="count">{userDomains.length}</span>
        )}
      </div>
      {userDomains.map((domain) => {
        const color = domain.color ?? "var(--fg-muted)";
        return (
          <NavItemLink key={domain.id} href={`/domain/${domain.slug}`}>
            <span
              className="sb__domain-dot"
              style={{ background: color }}
            />
            <span className="sb__domain-label">{domain.label}</span>
          </NavItemLink>
        );
      })}
      <NewDomainButton />

      <div className="sb__spacer" />

      {/* System group */}
      <div className="sb__group-label">
        <span>System</span>
      </div>
      <SystemRow iconName="settings" label="Settings" href="/settings" />
      <SystemRow
        iconName="user"
        label={
          session.user.name ??
          session.user.email?.split("@")[0] ??
          "account"
        }
        title={session.user.email ?? undefined}
        meta="free"
      />

      {/* Sign out — server action form */}
      <form
        action={async () => {
          "use server";
          await signOut({ redirectTo: "/login" });
        }}
      >
        <SystemRow iconName="logout" label="Sign out" as="button" />
      </form>
    </>
  );

  return (
    <div className="flex min-h-screen">
      {/* Sidebar — hidden on mobile, visible on lg+ (collapsible via DesktopSidebarShell) */}
      <DesktopSidebarShell>{sidebarContent}</DesktopSidebarShell>

      {/* Mobile drawer — sidebar prop → fixed drawer panel. children → main content.
          Pass the bare content; MobileSidebarDrawer wraps it in <aside class="sb">. */}
      <MobileSidebarDrawer sidebar={sidebarContent}>

      {/* Main column — fills the remaining space next to the (collapsible) sidebar.
          Using flex-1 + min-w-0 avoids hard-coding sidebar width here.
          h-screen (not min-h-screen) gives the column a *definite* height so the
          scrollable <main> below — and any child using height:100% (e.g. the
          Orbit d3-force <svg>) — resolves against a real height instead of
          collapsing. The inner <main> owns the scroll. */}
      <div className="flex flex-col h-screen flex-1 min-w-0">
        {/* Topbar — hidden on mobile when the /today flow mounts its own
            glass toolbar (see .today-mobile-active rule in globals.css). */}
        <header
          className="app-topbar"
          style={{
            height: "52px",
            borderBottom: "1px solid var(--accent-border)",
            background: "var(--surface-white)",
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            padding: "0 1rem 0 1rem",
            flexShrink: 0,
          }}
        >
          <div style={{ display: "flex", alignItems: "center", gap: "0.5rem", minWidth: 0 }}>
            {/* Hamburger — visible on mobile only, inside MobileSidebarDrawer context */}
            <HamburgerButton />
            <span
              style={{
                fontFamily: "var(--font-fraunces), var(--font-family-serif), serif",
                fontSize: 14,
                fontWeight: 500,
                letterSpacing: "-0.005em",
                color: "var(--fg-primary)",
              }}
            >
              DayPage
            </span>
            <span style={{ color: "var(--fg-subtle)", fontSize: "0.75rem" }}>/</span>
            <BreadcrumbLabel />
            <span
              aria-hidden="true"
              style={{
                color: "var(--fg-subtle)",
                fontSize: "0.65rem",
                marginLeft: 10,
                marginRight: 2,
              }}
            >
              ·
            </span>
            <TopbarDate />
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
            <Link href="/chat" className="btn btn--soft btn--sm" aria-label="Ask — open chat">Ask</Link>
            <Link href="/add" className="btn btn--primary btn--sm">Add</Link>
          </div>
        </header>

        {/* Page content. minHeight:0 lets this flex child shrink below its
            content height so overflowY:auto actually scrolls. display:flex +
            column makes the page's own flex:1 root (e.g. OrbitClient) fill the
            available height instead of collapsing to content height — a plain
            block parent silences a child's flex:1. */}
        <main
          style={{
            flex: 1,
            minHeight: 0,
            overflowY: "auto",
            display: "flex",
            flexDirection: "column",
          }}
        >
          {children}
        </main>
      </div>
      </MobileSidebarDrawer>
    </div>
  );
}

