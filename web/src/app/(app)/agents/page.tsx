import { auth } from "@/auth";
import { redirect } from "next/navigation";
import { db } from "@/lib/db/client";
import { users, agents, domains } from "@/lib/db/schema";
import { eq, desc } from "drizzle-orm";
import { AgentsClient, type AgentDTO, type DomainDTO } from "./AgentsClient";

export const metadata = {
  title: "Agents · DayPage",
};

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

export default async function AgentsPage() {
  const session = await auth();
  if (!session?.user) redirect("/login");

  const userId = session.user.email
    ? await resolveUserId(session.user.email)
    : null;

  let agentList: AgentDTO[] = [];
  let domainList: DomainDTO[] = [];

  if (userId) {
    const [agentRows, domainRows] = await Promise.all([
      db
        .select()
        .from(agents)
        .where(eq(agents.user_id, userId))
        .orderBy(desc(agents.created_at)),
      db
        .select({ id: domains.id, slug: domains.slug, label: domains.label })
        .from(domains)
        .where(eq(domains.user_id, userId))
        .orderBy(domains.position, domains.created_at),
    ]);

    agentList = agentRows.map((a) => ({
      id: a.id,
      name: a.name,
      persona_prompt: a.persona_prompt,
      model: a.model,
      domain_id: a.domain_id,
      top_k: a.top_k,
    }));
    domainList = domainRows;
  }

  return <AgentsClient initialAgents={agentList} domains={domainList} />;
}
