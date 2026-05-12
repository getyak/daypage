import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { pages, users } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { asc } from "drizzle-orm";
import { redirect } from "next/navigation";
import Link from "next/link";
import { BookOpen } from "lucide-react";
import { Btn } from "@/components/ui";
import { WikiNav, type WikiPage } from "./WikiNav";
import { WikiPageShell } from "./WikiPageShell";

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

export default async function WikiPage({
  searchParams,
}: {
  searchParams?: Promise<{ id?: string }>;
}) {
  const session = await auth();

  const sp = searchParams ? await searchParams : undefined;
  if (sp?.id) {
    const row = await db
      .select({ slug: pages.slug })
      .from(pages)
      .where(eq(pages.id, sp.id))
      .limit(1);
    if (row[0]) redirect(`/wiki/${row[0].slug}`);
  }

  let userPages: WikiPage[] = [];

  if (session?.user?.email) {
    const userId = await resolveUserId(session.user.email);
    if (userId) {
      userPages = await fetchUserPages(userId);
    }
  }

  return (
    <WikiPageShell
      nav={<WikiNav initialPages={userPages} />}
      main={<WikiMainContent hasPages={userPages.length > 0} />}
    />
  );
}

function WikiMainContent({ hasPages }: { hasPages: boolean }) {
  if (!hasPages) {
    return (
      <div
        className="empty-card"
        style={{
          padding: "48px 32px",
          maxWidth: 560,
          margin: "80px auto 0",
        }}
      >
        <BookOpen size={24} className="empty-card__icon" />
        <div className="empty-card__title" style={{ fontSize: 16 }}>
          Your wiki hasn&apos;t been compiled yet
        </div>
        <div className="empty-card__hint">
          I&apos;ll build pages from your memos as you add them. Drop a thought,
          paste a link, or voice a note — I&apos;ll surface concepts and entities
          here.
        </div>
        <div className="flex gap-12" style={{ marginTop: 16 }}>
          <Link href="/add">
            <Btn kind="primary" size="sm">
              Add your first memo
            </Btn>
          </Link>
          <Link href="/chat">
            <Btn kind="ghost" size="sm">
              Ask me to draft
            </Btn>
          </Link>
        </div>
      </div>
    );
  }

  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        padding: "3rem 2rem",
        textAlign: "center",
        gap: "0.5rem",
        minHeight: "60vh",
      }}
    >
      <p className="ds-body-md" style={{ color: "var(--fg-subtle)" }}>
        Pick a page from the left, or search.
      </p>
    </div>
  );
}
