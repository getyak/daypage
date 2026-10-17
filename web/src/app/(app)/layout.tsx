import { ReactNode } from "react";
import { auth, signOut } from "@/lib/auth/session";
import { redirect } from "next/navigation";
import { headers } from "next/headers";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { loginRedirectTarget } from "@/lib/memos/redirects";
import type { QueryBuilderLike } from "@/lib/memos/store";
import { NavItem, NavItemLink, type NavIconName } from "./_components/NavItem";
import { SystemRow } from "./_components/SystemRow";
import { TopbarDate } from "./_components/TopbarDate";
import { NewDomainButton } from "./_components/NewDomainButton";
import { MobileSidebarDrawer, HamburgerButton } from "./_components/MobileSidebarDrawer";
import { DesktopSidebarShell } from "./_components/DesktopSidebarShell";
import { BreadcrumbLabel } from "./_components/BreadcrumbLabel";
import { PageTransition } from "./_components/PageTransition";

type NavSpec = { href: string; label: string; iconName: NavIconName; meta?: string };

const NAV_ITEMS: ReadonlyArray<NavSpec> = [
  { href: "/home", label: "Home", iconName: "home", meta: "⌘1" },
  { href: "/add", label: "Add", iconName: "plus", meta: "⌘N" },
  { href: "/chat", label: "Chat", iconName: "message", meta: "⌘K" },
  { href: "/agents", label: "Agents", iconName: "bot" },
  { href: "/orbit", label: "Orbit", iconName: "orbit" },
  { href: "/wiki", label: "Wiki", iconName: "book", meta: "⌘W" },
  { href: "/inbox", label: "Inbox", iconName: "inbox" },
  { href: "/memos", label: "History", iconName: "history" },
  { href: "/insights", label: "Insights", iconName: "chart" },
];

// Sidebar domain row: the minimum safe read contract for the new
// same-project Supabase backend (uid + RLS + explicit user_id predicate).
interface SidebarDomain {
  id: string;
  label: string;
  slug: string;
  color: string | null;
}

async function fetchUserDomains(userId: string): Promise<SidebarDomain[]> {
  const supabase = await createClient();
  const result = await (supabase
    .from("domains")
    .select("id,label,slug,color")
    .eq("user_id", userId)
    .order("position", { ascending: true })
    .order("created_at", { ascending: true }) as unknown as QueryBuilderLike);
  // Failures are NOT swallowed into fake-empty state: surface them to the
  // error boundary rather than pretending the user has no domains.
  if (result.error) throw new Error("Domains are unavailable right now");
  return (result.data ?? []) as SidebarDomain[];
}

export default async function AppLayout({ children }: { children: ReactNode }) {
  const session = await auth();
  if (!session?.user) {
    // Preserve the intended destination when a request header carries the
    // path (see web/src/lib/memos/redirects.ts for the boundary notes).
    const headerStore = await headers();
    redirect(loginRedirectTarget(headerStore.get("x-pathname")));
  }

  // Identity is the verified auth uid — never email — so accounts without an
  // email still resolve. The inbox count badge is deliberately omitted: the
  // server-private count is not client-readable under the new RLS and we will
  // not fabricate a zero (deferred, see ADR-0022).
  const userDomains = await fetchUserDomains(session.user.id);

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
        {NAV_ITEMS.map(({ href, label, iconName, meta }) => (
          <NavItem key={href} href={href} label={label} iconName={iconName} meta={meta} />
        ))}
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
      <SystemRow
        iconName="user"
        label={
          session.user.name ??
          session.user.email?.split("@")[0] ??
          "account"
        }
        title={session.user.email ?? undefined}
        meta="account"
        href="/settings"
      />

      {/* Sign out — server action form */}
      <form
        action={async () => {
          "use server";
          await signOut({ redirectTo: "/login" });
        }}
      >
        <SystemRow iconName="logout" label="Sign out this device" as="button" />
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
          <PageTransition>{children}</PageTransition>
        </main>
      </div>
      </MobileSidebarDrawer>
    </div>
  );
}
