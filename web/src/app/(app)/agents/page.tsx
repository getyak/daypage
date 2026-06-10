import { auth } from "@/auth";
import { redirect } from "next/navigation";
import { db } from "@/lib/db/client";
import { users, agents, domains, task_suggestions } from "@/lib/db/schema";
import { eq, and, desc } from "drizzle-orm";
import { classifyGate } from "@/lib/gateway/policy";
import {
  AgentsClient,
  type AgentDTO,
  type DomainDTO,
  type SuggestionDTO,
} from "./AgentsClient";

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
  let suggestionList: SuggestionDTO[] = [];

  if (userId) {
    const [agentRows, domainRows, suggestionRows] = await Promise.all([
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
      db
        .select()
        .from(task_suggestions)
        .where(
          and(
            eq(task_suggestions.user_id, userId),
            eq(task_suggestions.status, "open")
          )
        )
        .orderBy(desc(task_suggestions.created_at)),
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
    // Predict the dispatch gate per suggestion (same classifier the work-order
    // builder uses) so the panel knows which picks need a second confirmation.
    suggestionList = suggestionRows.map((s) => ({
      id: s.id,
      title: s.title,
      rationale: s.rationale,
      estimate: s.estimate,
      suggested_target: s.suggested_target,
      gate: classifyGate(s.title),
      created_at: s.created_at.toISOString(),
    }));
  }

  return (
    <AgentsClient
      initialAgents={agentList}
      domains={domainList}
      initialSuggestions={suggestionList}
    />
  );
}
