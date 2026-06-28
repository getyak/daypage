import { auth } from "@/lib/auth/session";
import { redirect } from "next/navigation";
import { db } from "@/lib/db/client";
import { users } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { listTrees } from "@/lib/trees/repo";
import { OrbitClient, type TreeSummary } from "./OrbitClient";

export const metadata = {
  title: "Orbit · DayPage",
};

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

// US-032: Orbit — visualise a user's task trees as a d3-force graph of
// tree_nodes, coloured by heat. The server resolves the user and ships the
// tree list (id + title) only; node data + weekly diff are fetched per-tree on
// the client via GET /api/trees/:id.
export default async function OrbitPage() {
  const session = await auth();
  if (!session?.user) redirect("/login");

  const userId = session.user.email
    ? await resolveUserId(session.user.email)
    : null;

  let trees: TreeSummary[] = [];
  if (userId) {
    const rows = await listTrees(userId);
    trees = rows.map((t) => ({ id: t.id, title: t.title, status: t.status }));
  }

  return <OrbitClient trees={trees} />;
}
