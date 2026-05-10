import { ReactNode } from "react";
import { auth, signOut } from "@/auth";
import { redirect } from "next/navigation";
import Link from "next/link";
import { Home, Plus, MessageSquare, BookOpen, Inbox } from "lucide-react";
import { headers } from "next/headers";
import { db } from "@/lib/db/client";
import { users, domains, inbox_items } from "@/lib/db/schema";
import { eq, and, sql } from "drizzle-orm";
import type { Domain } from "@/lib/db/schema";

const NAV_ITEMS = [
  { href: "/home", label: "Home", icon: Home },
  { href: "/add", label: "Add", icon: Plus },
  { href: "/chat", label: "Chat", icon: MessageSquare },
  { href: "/wiki", label: "Wiki", icon: BookOpen },
  { href: "/inbox", label: "Inbox", icon: Inbox },
] as const;

function getViewLabel(pathname: string): string {
  for (const item of NAV_ITEMS) {
    if (pathname.startsWith(item.href)) return item.label;
  }
  return "Home";
}

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

  const headersList = await headers();
  const pathname = headersList.get("x-pathname") ?? "/home";
  const viewLabel = getViewLabel(pathname);

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

  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: "248px 1fr",
        minHeight: "100vh",
      }}
    >
      {/* Sidebar */}
      <aside
        style={{
          borderRight: "1px solid var(--accent-border)",
          background: "var(--surface-white)",
          display: "flex",
          flexDirection: "column",
        }}
      >
        {/* Logo */}
        <div
          style={{
            padding: "1.25rem 1rem 1rem",
            borderBottom: "1px solid var(--accent-border)",
          }}
        >
          <span className="ds-h2" style={{ color: "var(--accent)" }}>
            Codex
          </span>
        </div>

        {/* Nav items */}
        <nav style={{ flex: 1, padding: "0.75rem 0.5rem", display: "flex", flexDirection: "column", gap: "2px", overflowY: "auto" }}>
          {NAV_ITEMS.map(({ href, label, icon: Icon }) => {
            const isInbox = label === "Inbox";
            return (
              <NavItem
                key={href}
                href={href}
                label={label}
                Icon={Icon}
                badge={isInbox && openInboxCount > 0 ? openInboxCount : undefined}
              />
            );
          })}

          {/* Dynamic Domains group */}
          {userDomains.length > 0 && (
            <div style={{ marginTop: "0.75rem" }}>
              <p
                className="ds-section-label"
                style={{
                  padding: "0 0.75rem",
                  marginBottom: "0.25rem",
                  color: "var(--fg-subtle)",
                }}
              >
                Domains
              </p>
              {userDomains.map((domain) => (
                <DomainItem key={domain.id} domain={domain} />
              ))}
            </div>
          )}
        </nav>

        {/* Footer */}
        <div
          style={{
            borderTop: "1px solid var(--accent-border)",
            padding: "0.875rem 1rem",
            display: "flex",
            flexDirection: "column",
            gap: "0.375rem",
          }}
        >
          <p className="ds-mono-11" style={{ color: "var(--fg-muted)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
            {session.user.email}
          </p>
          <form
            action={async () => {
              "use server";
              await signOut({ redirectTo: "/login" });
            }}
          >
            <button type="submit" className="btn btn--ghost btn--sm" style={{ padding: 0, height: "auto", fontSize: "0.75rem", color: "var(--fg-subtle)" }}>
              Sign out
            </button>
          </form>
        </div>
      </aside>

      {/* Main column */}
      <div style={{ display: "flex", flexDirection: "column", minHeight: "100vh" }}>
        {/* Topbar */}
        <header
          style={{
            height: "52px",
            borderBottom: "1px solid var(--accent-border)",
            background: "var(--surface-white)",
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            padding: "0 1.5rem",
            flexShrink: 0,
          }}
        >
          <div style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
            <span className="ds-section-label">Codex</span>
            <span style={{ color: "var(--fg-subtle)", fontSize: "0.75rem" }}>/</span>
            <span style={{ fontSize: "0.875rem", fontWeight: 500, color: "var(--fg-primary)" }}>
              {viewLabel}
            </span>
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
            <span className="ds-mono-11">
              {new Date().toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" })}
            </span>
            <Link href="/add" className="btn btn--soft btn--sm">Ask</Link>
            <Link href="/add" className="btn btn--primary btn--sm">Add</Link>
          </div>
        </header>

        {/* Page content */}
        <main style={{ flex: 1, overflowY: "auto" }}>
          {children}
        </main>
      </div>
    </div>
  );
}

function NavItem({
  href,
  label,
  Icon,
  badge,
}: {
  href: string;
  label: string;
  Icon: React.ComponentType<{ size?: number }>;
  badge?: number;
}) {
  return (
    <Link
      href={href}
      style={{
        display: "flex",
        alignItems: "center",
        gap: "0.625rem",
        padding: "0.5rem 0.75rem",
        borderRadius: "var(--radius-sm)",
        fontSize: "0.9375rem",
        fontWeight: 500,
        color: "var(--fg-muted)",
        textDecoration: "none",
        transition: "background 100ms ease-out, color 100ms ease-out",
      }}
      className="sidebar-nav-item"
    >
      <Icon size={18} />
      <span style={{ flex: 1 }}>{label}</span>
      {badge !== undefined && (
        <span
          style={{
            background: "var(--accent)",
            color: "#fff",
            fontSize: "0.6875rem",
            fontWeight: 600,
            lineHeight: 1,
            padding: "0.1875rem 0.4375rem",
            borderRadius: "999px",
            minWidth: "1.25rem",
            textAlign: "center",
          }}
        >
          {badge > 99 ? "99+" : badge}
        </span>
      )}
    </Link>
  );
}

function DomainItem({ domain }: { domain: Domain }) {
  const color = domain.color ?? "var(--fg-muted)";
  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        gap: "0.625rem",
        padding: "0.4375rem 0.75rem",
        borderRadius: "var(--radius-sm)",
        fontSize: "0.875rem",
        fontWeight: 500,
        color: "var(--fg-muted)",
      }}
    >
      <span
        style={{
          width: "8px",
          height: "8px",
          borderRadius: "50%",
          background: color,
          flexShrink: 0,
        }}
      />
      <span style={{ flex: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
        {domain.label}
      </span>
    </div>
  );
}
