import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, chat_threads } from "@/lib/db/schema";
import { eq, desc } from "drizzle-orm";
import Link from "next/link";
import { MessageSquare } from "lucide-react";
import { NewButton } from "./ThreadList";

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

export default async function ChatPage() {
  const session = await auth();

  let threads: { id: string; title: string; status: string; updated_at: Date }[] = [];

  if (session?.user?.email) {
    const userId = await resolveUserId(session.user.email);
    if (userId) {
      threads = await db
        .select({
          id: chat_threads.id,
          title: chat_threads.title,
          status: chat_threads.status,
          updated_at: chat_threads.updated_at,
        })
        .from(chat_threads)
        .where(eq(chat_threads.user_id, userId))
        .orderBy(desc(chat_threads.updated_at))
        .limit(50);
    }
  }

  return (
    <div style={{ display: "flex", height: "calc(100vh - 52px)" }}>
      {/* Thread list sidebar */}
      <aside
        style={{
          width: "280px",
          flexShrink: 0,
          borderRight: "1px solid var(--accent-border)",
          background: "var(--surface-white)",
          display: "flex",
          flexDirection: "column",
        }}
      >
        <div
          style={{
            padding: "1rem",
            borderBottom: "1px solid var(--accent-border)",
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
          }}
        >
          <p className="ds-section-label">Conversations</p>
          <NewButton />
        </div>

        <div style={{ flex: 1, overflowY: "auto" }}>
          {threads.length === 0 ? (
            <div
              style={{
                display: "flex",
                flexDirection: "column",
                alignItems: "center",
                gap: 12,
                padding: "40px 20px",
                color: "var(--fg-subtle)",
              }}
            >
              <MessageSquare size={16} />
              <div
                className="ds-caption"
                style={{ textAlign: "center", color: "var(--fg-muted)" }}
              >
                No conversations yet
              </div>
              <NewButton kind="secondary" label="Start one" />
            </div>
          ) : (
            <ul style={{ listStyle: "none", margin: 0, padding: "0.5rem" }}>
              {threads.map((t) => (
                <li key={t.id}>
                  <Link
                    href={`/chat/${t.id}`}
                    style={{
                      display: "block",
                      padding: "0.625rem 0.75rem",
                      borderRadius: "var(--radius-sm)",
                      textDecoration: "none",
                      color: "var(--fg-primary)",
                      transition: "background 100ms ease-out",
                    }}
                    className="sidebar-nav-item"
                  >
                    <p
                      style={{
                        fontSize: "0.875rem",
                        fontWeight: 500,
                        margin: 0,
                        overflow: "hidden",
                        textOverflow: "ellipsis",
                        whiteSpace: "nowrap",
                      }}
                    >
                      {t.title}
                    </p>
                    <p
                      className="ds-mono-11"
                      style={{ margin: "0.125rem 0 0" }}
                    >
                      {formatRelative(t.updated_at)}
                    </p>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </div>
      </aside>

      {/* Empty state */}
      <main style={{ flex: 1, overflowY: "auto" }}>
        <div
          className="empty-card"
          style={{
            padding: "48px 32px",
            maxWidth: 560,
            margin: "100px auto 0",
          }}
        >
          <MessageSquare size={24} className="empty-card__icon" />
          <div className="empty-card__title" style={{ fontSize: 16 }}>
            Ask your wiki anything
          </div>
          <div className="empty-card__hint">
            I answer only from what you&apos;ve already captured. Numbers in my
            reply link back to the source. I&apos;ll say &ldquo;I don&apos;t know
            yet&rdquo; before I make something up.
          </div>
          <div style={{ marginTop: 16 }}>
            <NewButton kind="primary" label="Start a conversation" />
          </div>
          <div
            className="ds-caption"
            style={{ marginTop: 12, color: "var(--fg-muted)" }}
          >
            Try: &ldquo;What did I read about Raft this month?&rdquo;
          </div>
        </div>
      </main>
    </div>
  );
}

function formatRelative(date: Date): string {
  const now = Date.now();
  const diff = now - date.getTime();
  const mins = Math.floor(diff / 60_000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 7) return `${days}d ago`;
  return date.toLocaleDateString();
}
