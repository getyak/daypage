import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { pages, users } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { asc } from "drizzle-orm";
import { WikiNav, type WikiPage } from "./WikiNav";

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

async function fetchUserPages(userId: string): Promise<WikiPage[]> {
  try {
    const rows = await db
      .select({
        id: pages.id,
        slug: pages.slug,
        type: pages.type,
        title: pages.title,
        status: pages.status,
        domain_id: pages.domain_id,
        source_count: pages.source_count,
        backlink_count: pages.backlink_count,
        last_compiled_at: pages.last_compiled_at,
        updated_at: pages.updated_at,
      })
      .from(pages)
      .where(eq(pages.user_id, userId))
      .orderBy(asc(pages.type), asc(pages.title));

    return rows.map((r) => ({
      ...r,
      last_compiled_at: r.last_compiled_at?.toISOString() ?? null,
      updated_at: r.updated_at.toISOString(),
    }));
  } catch {
    return [];
  }
}

export default async function WikiPage() {
  const session = await auth();

  let userPages: WikiPage[] = [];

  if (session?.user?.email) {
    const userId = await resolveUserId(session.user.email);
    if (userId) {
      userPages = await fetchUserPages(userId);
    }
  }

  return (
    <div
      style={{
        display: "flex",
        height: "100%",
        minHeight: "calc(100vh - 52px)",
      }}
    >
      {/* Left nav: 240px */}
      <WikiNav initialPages={userPages} />

      {/* Main content area */}
      <main
        style={{
          flex: 1,
          overflowY: "auto",
          display: "flex",
          flexDirection: "column",
        }}
      >
        <WikiMainContent hasPages={userPages.length > 0} />
      </main>

      {/* Right aside: 280px */}
      <aside
        style={{
          width: "280px",
          flexShrink: 0,
          borderLeft: "1px solid var(--accent-border)",
          background: "var(--surface-white)",
          overflowY: "auto",
        }}
      >
        <WikiAside />
      </aside>
    </div>
  );
}

function WikiMainContent({ hasPages }: { hasPages: boolean }) {
  if (!hasPages) {
    return (
      <div
        style={{
          flex: 1,
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          padding: "3rem 2rem",
          textAlign: "center",
          gap: "1rem",
        }}
      >
        <div
          style={{
            width: "48px",
            height: "48px",
            borderRadius: "var(--radius-md)",
            background: "var(--surface-sunken)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontSize: "1.5rem",
          }}
        >
          📖
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: "0.5rem" }}>
          <h2 className="ds-h2" style={{ margin: 0 }}>
            Your wiki is empty
          </h2>
          <p
            className="ds-body-md"
            style={{ color: "var(--fg-muted)", margin: 0, maxWidth: "360px" }}
          >
            Your wiki will grow here as AI compiles your memos. Add content from
            the{" "}
            <a
              href="/add"
              style={{ color: "var(--accent)", textDecoration: "none" }}
            >
              Add
            </a>{" "}
            page to get started.
          </p>
        </div>
      </div>
    );
  }

  return (
    <div
      style={{
        flex: 1,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        padding: "3rem 2rem",
        textAlign: "center",
        gap: "0.5rem",
      }}
    >
      <p className="ds-body-md" style={{ color: "var(--fg-subtle)" }}>
        Select a page from the left to read it
      </p>
    </div>
  );
}

function WikiAside() {
  return (
    <div
      style={{
        padding: "1.25rem 1rem",
        display: "flex",
        flexDirection: "column",
        gap: "1.25rem",
      }}
    >
      <div>
        <p
          className="ds-section-label"
          style={{ color: "var(--fg-subtle)", marginBottom: "0.5rem" }}
        >
          About
        </p>
        <p
          className="ds-body-md"
          style={{ color: "var(--fg-muted)", fontSize: "0.8125rem" }}
        >
          Select a page to see sources, backlinks, and provenance.
        </p>
      </div>
    </div>
  );
}
