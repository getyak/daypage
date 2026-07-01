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
      {/* Composer 直接作为首屏主视觉 (Round 5)：删掉 hero headline 和长 sub
          文案。只留一个极轻的 section label 作为页面身份指示，呼吸感留给 Composer
          自己。Hero 文案的产品宣言转移到 Composer 自带的 placeholder 与 / 命令。 */}
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
