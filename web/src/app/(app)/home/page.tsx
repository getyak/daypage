// Home view — the unified capture→compile→wiki stream up top (HomeStream),
// followed by the knowledge-network panels (observations, activity).
//
// The top stream mirrors the iOS Today→DailyPage pipeline: capture raw memos,
// see today's as flomo cards, browse yesterday-and-earlier as compiled daily
// wiki pages, and trigger the day's compile on demand (the inngest daily-page
// cron handles midnight automatically).
import Link from "next/link";
import { ArrowUpRight, ChevronRight, Sparkles, Inbox, Activity, Clock } from "lucide-react";
import { Btn, Card, Chip, Icon, SectionLabel } from "@/components/ui";
import { HomeStream, type DailyPageCard } from "./HomeStream";
import type { MemoCardData } from "../today/MemoCard";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import {
  users,
  inbox_items,
  memos,
  memo_attachments,
  pages,
  activities,
} from "@/lib/db/schema";
import { eq, and, gte, lt, desc, inArray } from "drizzle-orm";

// ── Data helpers ──────────────────────────────────────────────────────────────

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

// Today's memos as flomo-card data (same shape the /today stream serves).
async function getTodayMemos(userId: string): Promise<MemoCardData[]> {
  try {
    const now = new Date();
    const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const tomorrowStart = new Date(todayStart.getTime() + 86_400_000);

    const rows = await db
      .select({
        id: memos.id,
        type: memos.type,
        body: memos.body,
        created_at: memos.created_at,
        compile_status: memos.compile_status,
        compile_step: memos.compile_step,
        compile_error: memos.compile_error,
      })
      .from(memos)
      .where(
        and(
          eq(memos.user_id, userId),
          gte(memos.created_at, todayStart),
          lt(memos.created_at, tomorrowStart)
        )
      )
      .orderBy(desc(memos.created_at))
      .limit(50);

    const photoMemoIds = rows.filter((m) => m.type === "photo").map((m) => m.id);
    // Scope the attachment lookup to today's photo memos — without the memo_id
    // constraint this would scan every photo attachment in the table.
    const attachments =
      photoMemoIds.length > 0
        ? await db
            .select({
              memo_id: memo_attachments.memo_id,
              storage_key: memo_attachments.storage_key,
            })
            .from(memo_attachments)
            .where(
              and(
                eq(memo_attachments.kind, "photo"),
                inArray(memo_attachments.memo_id, photoMemoIds)
              )
            )
        : [];
    const photoByMemoId = new Map(
      attachments.map((a) => [a.memo_id, `/api/img/${a.storage_key}`])
    );

    return rows.map((m) => {
      const photoUrl = photoByMemoId.get(m.id) ?? null;
      const displayType: MemoCardData["type"] =
        m.type === "photo" && m.body.trim().length > 0
          ? "mixed"
          : (m.type as MemoCardData["type"]);
      return {
        id: m.id,
        type: displayType,
        body: m.body,
        created_at: m.created_at.toISOString(),
        photo_url: photoUrl,
        compile_status: m.compile_status ?? undefined,
        compile_step: m.compile_step ?? null,
        compile_error: m.compile_error ?? null,
      };
    });
  } catch {
    return [];
  }
}

// Yesterday-and-earlier compiled daily pages (type="daily", live), newest first.
async function getDailyPages(userId: string): Promise<DailyPageCard[]> {
  try {
    const rows = await db
      .select({
        slug: pages.slug,
        title: pages.title,
        body_md: pages.body_md,
        source_count: pages.source_count,
        last_compiled_at: pages.last_compiled_at,
      })
      .from(pages)
      .where(
        and(eq(pages.user_id, userId), eq(pages.type, "daily"), eq(pages.status, "live"))
      )
      .orderBy(desc(pages.slug))
      .limit(12);

    const todayIso = (() => {
      const n = new Date();
      return `${n.getFullYear()}-${String(n.getMonth() + 1).padStart(2, "0")}-${String(
        n.getDate()
      ).padStart(2, "0")}`;
    })();

    return rows
      .map((r) => {
        const date = r.slug.replace(/^daily\//, "");
        return {
          slug: r.slug,
          date,
          title: r.title,
          excerpt: excerptFromMarkdown(r.body_md ?? ""),
          source_count: r.source_count ?? 0,
          last_compiled_at: r.last_compiled_at ? r.last_compiled_at.toISOString() : null,
        };
      })
      // Don't echo today's page in the "yesterday & earlier" rail.
      .filter((p) => p.date !== todayIso);
  } catch {
    return [];
  }
}

// First ~160 chars of body, stripped of markdown noise — a calm card preview.
// We deliberately drop section headings like "### Highlights" *with their text*
// (not just the `#` prefix). If we kept the word "Highlights" the excerpt would
// read "Highlights - You noted… Mood 清晨的咖啡馆…" — visually that looks like
// the same content rendered twice when paired with the card's pull line.
function excerptFromMarkdown(md: string): string {
  const SECTION_HEADINGS = /^#{1,6}\s+(highlights|locations|themes|mood|tags|topics|summary|wiki)\s*$/gim;
  const plain = md
    .replace(/^---[\s\S]*?\r?\n---\r?\n/, "") // strip YAML frontmatter (LF or CRLF)
    .replace(SECTION_HEADINGS, "") // drop boilerplate section headings entirely
    .replace(/^#{1,6}\s+/gm, "") // strip leading # on remaining headings
    .replace(/^\s*[-*_]{3,}\s*$/gm, "") // strip horizontal rules
    .replace(/^[|].*[|]\s*$/gm, "") // strip table rows
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/^\s*[-*+]\s+/gm, "") // strip list bullets so excerpt reads as prose
    .replace(/[*_`>#]/g, "")
    .replace(/\s+/g, " ")
    .trim();
  return plain.length > 160 ? `${plain.slice(0, 160)}…` : plain;
}

type ActivityRow = {
  id: string;
  verb: string;
  subject: string;
  target_type: string | null;
  target_id: string | null;
  created_at: Date;
};

async function getActivities(userId: string): Promise<ActivityRow[]> {
  try {
    return await db
      .select({
        id: activities.id,
        verb: activities.verb,
        subject: activities.subject,
        target_type: activities.target_type,
        target_id: activities.target_id,
        created_at: activities.created_at,
      })
      .from(activities)
      .where(eq(activities.user_id, userId))
      .orderBy(desc(activities.created_at))
      .limit(6);
  } catch {
    return [];
  }
}

type InboxItemRow = {
  id: string;
  kind: string;
  title: string;
  body: string | null;
  created_at: Date;
};

async function getOpenInboxItems(
  userId: string
): Promise<{ items: InboxItemRow[]; total: number }> {
  try {
    const rows = await db
      .select({
        id: inbox_items.id,
        kind: inbox_items.kind,
        title: inbox_items.title,
        body: inbox_items.body,
        created_at: inbox_items.created_at,
      })
      .from(inbox_items)
      .where(and(eq(inbox_items.user_id, userId), eq(inbox_items.status, "open")))
      .orderBy(desc(inbox_items.created_at))
      .limit(3);
    // The inbox page owns the precise count — here we only need "are there any".
    return { items: rows, total: rows.length };
  } catch {
    return { items: [], total: 0 };
  }
}

// ── Formatting helpers ────────────────────────────────────────────────────────

function formatRelative(date: Date): string {
  const diffMs = Date.now() - date.getTime();
  const diffMin = Math.floor(diffMs / 60_000);
  if (diffMin < 1) return "刚刚";
  if (diffMin < 60) return `${diffMin} 分钟前`;
  const diffH = Math.floor(diffMin / 60);
  if (diffH < 24) return `${diffH} 小时前`;
  const diffD = Math.floor(diffH / 24);
  if (diffD === 1) return "昨天";
  return `${diffD} 天前`;
}

function kindLabel(kind: string): string {
  switch (kind) {
    case "contradiction":
      return "矛盾";
    case "schema":
      return "结构";
    case "orphan":
      return "孤立";
    case "compiled":
      return "已编译";
    default:
      return kind;
  }
}

// ── Page ──────────────────────────────────────────────────────────────────────

export default async function HomePage() {
  const session = await auth();
  const userId = session?.user?.email ? await resolveUserId(session.user.email) : null;

  const [todayMemos, dailyPages, recentActivities, inboxData] = userId
    ? await Promise.all([
        getTodayMemos(userId),
        getDailyPages(userId),
        getActivities(userId),
        getOpenInboxItems(userId),
      ])
    : [
        [] as MemoCardData[],
        [] as DailyPageCard[],
        [] as ActivityRow[],
        { items: [] as InboxItemRow[], total: 0 },
      ];

  const openInboxCount = inboxData.total;

  return (
    <>
      {/* ── The capture→compile→wiki stream (main act) ─────────────────── */}
      <HomeStream initialToday={todayMemos} dailyPages={dailyPages} />

      {/* ── Knowledge-network panels (supporting act) ──────────────────── */}
      <div className="page home-panels">
        {/* Observations */}
        <div>
          <SectionLabel
            right={
              openInboxCount > 0 ? (
                <Link href="/inbox">
                  <Chip tone="accent">{openInboxCount} open</Chip>
                </Link>
              ) : null
            }
          >
            系统注意到的
          </SectionLabel>
          {inboxData.items.length === 0 ? (
            <Card>
              <div
                style={{
                  display: "flex",
                  flexDirection: "column",
                  alignItems: "center",
                  justifyContent: "center",
                  gap: 12,
                  padding: "40px 24px",
                  textAlign: "center",
                }}
              >
                <span style={{ color: "var(--fg-subtle)", opacity: 0.5, display: "flex" }}>
                  <Icon as={Sparkles} size={26} />
                </span>
                <p style={{ color: "var(--fg-subtle)", margin: 0, fontSize: "0.9rem" }}>
                  暂无待处理的观察
                </p>
                <Link href="/inbox">
                  <Btn kind="ghost" size="sm" icon={<Inbox size={14} />}>
                    打开收件箱
                  </Btn>
                </Link>
              </div>
            </Card>
          ) : (
            <Card>
              {inboxData.items.map((item, i) => (
                <div key={item.id}>
                  <Link href="/inbox" style={{ textDecoration: "none", color: "inherit" }}>
                    <div className="observation">
                      <div className="observation__lead">
                        <span className="pulse" />
                        {kindLabel(item.kind)}
                      </div>
                      <div className="observation__body">
                        <p style={{ fontWeight: 500, margin: "0 0 4px" }}>{item.title}</p>
                        {item.body && (
                          <p
                            style={{
                              color: "var(--fg-subtle)",
                              margin: 0,
                              fontSize: "0.875rem",
                            }}
                          >
                            {item.body}
                          </p>
                        )}
                        <div
                          style={{
                            display: "flex",
                            alignItems: "center",
                            gap: 4,
                            marginTop: 6,
                            color: "var(--fg-subtle)",
                            fontSize: "0.8rem",
                          }}
                        >
                          <Icon as={Clock} size={11} />
                          {formatRelative(item.created_at)}
                        </div>
                      </div>
                    </div>
                  </Link>
                  {i < inboxData.items.length - 1 && <div className="divider" />}
                </div>
              ))}
            </Card>
          )}
        </div>

        {/* Recent activity */}
        <div className="mt-32">
          <SectionLabel
            right={
              <Link href="/inbox?filter=compiled">
                <Btn kind="ghost" size="sm" iconRight={<Icon as={ArrowUpRight} size={14} />}>
                  全部
                </Btn>
              </Link>
            }
          >
            最近动态
          </SectionLabel>
          {recentActivities.length === 0 ? (
            <Card>
              <div
                style={{
                  display: "flex",
                  flexDirection: "column",
                  alignItems: "center",
                  justifyContent: "center",
                  gap: 12,
                  padding: "40px 24px",
                  textAlign: "center",
                }}
              >
                <span style={{ color: "var(--fg-subtle)", opacity: 0.5, display: "flex" }}>
                  <Icon as={Activity} size={26} />
                </span>
                <p style={{ color: "var(--fg-subtle)", margin: 0, fontSize: "0.9rem" }}>
                  暂无动态 —— 记录满一天，编译后这里会亮起来
                </p>
              </div>
            </Card>
          ) : (
            <Card>
              {recentActivities.map((a) => (
                <div className="activity-row" key={a.id}>
                  <div className="when">{formatRelative(a.created_at)}</div>
                  <div className="what">
                    <strong>{a.verb}</strong> {a.subject}
                    {a.target_id && a.target_type === "page" && (
                      <Link href={`/wiki/${a.target_id}`} className="activity-target">
                        <em>{a.target_id}</em>
                      </Link>
                    )}
                  </div>
                  <Icon as={ChevronRight} size={14} />
                </div>
              ))}
            </Card>
          )}
        </div>
      </div>
    </>
  );
}
