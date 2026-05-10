import { FileText } from "lucide-react";
import { UnifiedInput } from "./UnifiedInput";
import { CompileQueue, type Memo } from "./CompileQueue";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { memos, users } from "@/lib/db/schema";
import { eq, and, desc } from "drizzle-orm";

async function fetchInitialPendingMemos(userId: string) {
  try {
    return await db
      .select()
      .from(memos)
      .where(and(eq(memos.user_id, userId), eq(memos.compile_status, "pending")))
      .orderBy(desc(memos.created_at))
      .limit(20);
  } catch {
    return [];
  }
}

export default async function AddPage() {
  const session = await auth();

  let initialMemos: Memo[] = [];

  if (session?.user?.email) {
    const userRows = await db
      .select({ id: users.id })
      .from(users)
      .where(eq(users.email, session.user.email))
      .limit(1);

    if (userRows[0]) {
      const rows = await fetchInitialPendingMemos(userRows[0].id);
      initialMemos = rows.map((r) => ({
        id: r.id,
        body: r.body,
        type: r.type,
        compile_status: r.compile_status,
        ingest_mode: r.ingest_mode,
        created_at: r.created_at.toISOString(),
      }));
    }
  }

  return (
    <div
      style={{
        maxWidth: "760px",
        margin: "0 auto",
        padding: "2rem 1.5rem",
        display: "flex",
        flexDirection: "column",
        gap: "2rem",
      }}
    >
      {/* Hero block */}
      <div style={{ display: "flex", flexDirection: "column", gap: "0.375rem" }}>
        <p className="ds-section-label">Add</p>
        <h1 className="ds-h1" style={{ margin: 0 }}>
          Capture something
        </h1>
        <p className="ds-body-md" style={{ color: "var(--fg-muted)", margin: 0 }}>
          Paste a link, write a thought, drop a file, or record your voice — the
          system will handle the rest.
        </p>
      </div>

      {/* Unified input */}
      <UnifiedInput />

      {/* Compile Queue */}
      <section style={{ display: "flex", flexDirection: "column", gap: "0.75rem" }}>
        <p className="ds-section-label">Compile Queue</p>
        <div className="card" style={{ padding: "1.25rem" }}>
          <CompileQueue initialMemos={initialMemos} />
        </div>
      </section>

      {/* Recently Compiled */}
      <section style={{ display: "flex", flexDirection: "column", gap: "0.75rem" }}>
        <p className="ds-section-label">Recently Compiled</p>
        <div className="card" style={{ padding: "1.25rem" }}>
          <EmptyState
            icon={<FileText size={20} style={{ color: "var(--fg-subtle)" }} />}
            message="Nothing compiled yet"
            sub="Finished items will show up here."
          />
        </div>
      </section>
    </div>
  );
}

function EmptyState({
  icon,
  message,
  sub,
}: {
  icon: React.ReactNode;
  message: string;
  sub: string;
}) {
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        gap: "0.5rem",
        padding: "2rem 1rem",
        textAlign: "center",
      }}
    >
      {icon}
      <p
        style={{
          margin: 0,
          fontWeight: 500,
          color: "var(--fg-muted)",
          fontSize: "0.9375rem",
        }}
      >
        {message}
      </p>
      <p style={{ margin: 0, fontSize: "0.8125rem", color: "var(--fg-subtle)" }}>
        {sub}
      </p>
    </div>
  );
}
