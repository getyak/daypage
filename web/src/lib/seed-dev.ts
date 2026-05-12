/**
 * Idempotent dev-data seed for dev-bypass login.
 * Inserts 3 example domains + sample pages for a new dev user.
 * Skips if the user already has domains. Never runs in production.
 */

import { db } from "@/lib/db/client";
import { domains, pages } from "@/lib/db/schema";
import { eq, count } from "drizzle-orm";

const DEV_DOMAINS = [
  {
    slug: "work",
    label: "Work",
    color: "#6366f1",
    pages: [
      { slug: "work-q2-roadmap", type: "concept" as const, title: "Q2 Roadmap", status: "live" as const },
      { slug: "work-team-sync", type: "synthesis" as const, title: "Team Sync Notes", status: "draft" as const },
      { slug: "work-onboarding", type: "entity" as const, title: "Onboarding Process", status: "live" as const },
    ],
  },
  {
    slug: "reading",
    label: "Reading",
    color: "#10b981",
    pages: [
      { slug: "reading-atomic-habits", type: "source" as const, title: "Atomic Habits", status: "live" as const },
      { slug: "reading-deep-work", type: "source" as const, title: "Deep Work", status: "live" as const },
      { slug: "reading-focus-concepts", type: "concept" as const, title: "Focus & Attention", status: "draft" as const },
    ],
  },
  {
    slug: "health",
    label: "Health",
    color: "#f59e0b",
    pages: [
      { slug: "health-sleep-log", type: "daily" as const, title: "Sleep Tracking", status: "live" as const },
      { slug: "health-exercise-routine", type: "concept" as const, title: "Exercise Routine", status: "draft" as const },
    ],
  },
];

export async function seedDevUser(userId: string): Promise<void> {
  if (process.env.NODE_ENV === "production") return;

  const existing = await db
    .select({ n: count() })
    .from(domains)
    .where(eq(domains.user_id, userId));

  if ((existing[0]?.n ?? 0) > 0) return;

  const now = new Date();
  for (let i = 0; i < DEV_DOMAINS.length; i++) {
    const spec = DEV_DOMAINS[i];

    const [domain] = await db
      .insert(domains)
      .values({
        user_id: userId,
        slug: spec.slug,
        label: spec.label,
        color: spec.color,
        position: i,
      })
      .returning({ id: domains.id });

    await db.insert(pages).values(
      spec.pages.map((p, j) => ({
        user_id: userId,
        domain_id: domain.id,
        slug: p.slug,
        type: p.type,
        title: p.title,
        status: p.status,
        source_count: 2,
        backlink_count: 1,
        updated_at: new Date(now.getTime() - j * 3_600_000),
      }))
    );
  }
}
