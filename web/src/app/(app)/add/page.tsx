import { CaptureHero } from "./CaptureHero";
import { CompileServiceBanner } from "./CompileServiceBanner";
import { Composer } from "./Composer";
import { CompileQueue, type Memo } from "./CompileQueue";
import { RecentlyCompiled } from "./RecentlyCompiled";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { memos, users } from "@/lib/db/schema";
import { eq, and, desc, or } from "drizzle-orm";

async function fetchInitialQueueMemos(userId: string) {
  try {
    return await db
      .select()
      .from(memos)
      .where(
        and(
          eq(memos.user_id, userId),
          or(
            eq(memos.compile_status, "pending"),
            eq(memos.compile_status, "running"),
          ),
        ),
      )
      .orderBy(desc(memos.created_at))
      .limit(20);
  } catch {
    return [];
  }
}

async function fetchRecentlyCompiled(userId: string) {
  try {
    return await db
      .select()
      .from(memos)
      .where(and(eq(memos.user_id, userId), eq(memos.compile_status, "done")))
      .orderBy(desc(memos.updated_at))
      .limit(8);
  } catch {
    return [];
  }
}

export default async function AddPage() {
  const session = await auth();

  let initialMemos: Memo[] = [];
  let recentlyCompiled: Memo[] = [];

  if (session?.user?.email) {
    const userRows = await db
      .select({ id: users.id })
      .from(users)
      .where(eq(users.email, session.user.email))
      .limit(1);

    if (userRows[0]) {
      const [queueRows, doneRows] = await Promise.all([
        fetchInitialQueueMemos(userRows[0].id),
        fetchRecentlyCompiled(userRows[0].id),
      ]);
      initialMemos = queueRows.map((r) => ({
        id: r.id,
        body: r.body,
        type: r.type,
        compile_status: r.compile_status,
        ingest_mode: r.ingest_mode,
        created_at: r.created_at.toISOString(),
      }));
      recentlyCompiled = doneRows.map((r) => ({
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
    <main
      className="page"
      style={{
        maxWidth: "760px",
        display: "flex",
        flexDirection: "column",
        gap: "2rem",
      }}
    >
      {/* v9 signature entrance: Fraunces date + mono-caps ritual line.
          Aligns /add with /home so the app has one gallery-front-desk
          entry pattern instead of two. */}
      <CaptureHero
        queueCount={initialMemos.length}
        doneCount={recentlyCompiled.length}
      />

      {/* Single, authoritative pipeline status banner. Mirrors the /home
          `home-pipeline-warn` copy so users get the same signal in one
          place instead of six per-row "编译服务未连接" repetitions. */}
      <CompileServiceBanner />

      {/* Composer — v9 elevation + warm-brown accent border on focus. */}
      <Composer />

      {/* Compile Queue */}
      <section
        style={{ display: "flex", flexDirection: "column", gap: "0.75rem" }}
      >
        <p className="ds-section-label">Compile Queue</p>
        <div className="card" style={{ padding: "1.25rem" }}>
          <CompileQueue initialMemos={initialMemos} />
        </div>
      </section>

      {/* Recently Compiled */}
      <section
        style={{ display: "flex", flexDirection: "column", gap: "0.75rem" }}
      >
        <p className="ds-section-label">Recently Compiled</p>
        <div className="card" style={{ padding: "1.25rem" }}>
          <RecentlyCompiled initialMemos={recentlyCompiled} />
        </div>
      </section>
    </main>
  );
}
