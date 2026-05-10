import {
  pgTable,
  pgEnum,
  uuid,
  text,
  timestamp,
  jsonb,
  boolean,
  integer,
  real,
  index,
  unique,
  primaryKey,
} from "drizzle-orm/pg-core";
import { sql } from "drizzle-orm";

// ─── Enums ────────────────────────────────────────────────────────────────────

export const memoTypeEnum = pgEnum("memo_type", [
  "text",
  "url",
  "voice",
  "photo",
  "file",
]);

export const ingestModeEnum = pgEnum("ingest_mode", ["light", "full"]);

export const compileStatusEnum = pgEnum("compile_status", [
  "pending",
  "running",
  "done",
  "failed",
]);

export const originEnum = pgEnum("origin", ["ios", "web", "api"]);

export const attachmentKindEnum = pgEnum("attachment_kind", [
  "audio",
  "photo",
  "file",
]);

export const pageTypeEnum = pgEnum("page_type", [
  "concept",
  "source",
  "entity",
  "synthesis",
  "daily",
]);

export const pageStatusEnum = pgEnum("page_status", [
  "draft",
  "live",
  "archived",
]);

// ─── US-006: Wave 1b — users + memos + memo_attachments ───────────────────────

export const users = pgTable("users", {
  id: uuid("id").primaryKey().defaultRandom(),
  email: text("email").unique(),
  apple_sub: text("apple_sub").unique(),
  name: text("name"),
  avatar_url: text("avatar_url"),
  created_at: timestamp("created_at", { withTimezone: true })
    .notNull()
    .defaultNow(),
  onboarded_at: timestamp("onboarded_at", { withTimezone: true }),
  settings: jsonb("settings"),
});

export const memos = pgTable(
  "memos",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    type: memoTypeEnum("type").notNull().default("text"),
    body: text("body").notNull().default(""),
    created_at: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
    pinned_at: timestamp("pinned_at", { withTimezone: true }),
    location: jsonb("location"),
    weather: text("weather"),
    device: text("device"),
    source_url: text("source_url"),
    ingest_mode: ingestModeEnum("ingest_mode").notNull().default("light"),
    compile_status: compileStatusEnum("compile_status")
      .notNull()
      .default("pending"),
    origin: originEnum("origin").notNull().default("web"),
    vault_path: text("vault_path"),
    updated_at: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (t) => [
    index("memos_user_created").on(t.user_id, t.created_at),
    index("memos_user_status").on(t.user_id, t.compile_status),
  ]
);

export const memo_attachments = pgTable("memo_attachments", {
  id: uuid("id").primaryKey().defaultRandom(),
  memo_id: uuid("memo_id")
    .notNull()
    .references(() => memos.id, { onDelete: "cascade" }),
  kind: attachmentKindEnum("kind").notNull(),
  storage_key: text("storage_key").notNull(),
  filename: text("filename"),
  mime_type: text("mime_type"),
  size_bytes: integer("size_bytes"),
  duration_sec: real("duration_sec"),
  transcript: text("transcript"),
  ocr_text: text("ocr_text"),
  exif: jsonb("exif"),
});

// ─── US-007: Wave 1c — domains + pages + page_links + page_sources ─────────────

export const domains = pgTable(
  "domains",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    slug: text("slug").notNull(),
    label: text("label").notNull(),
    color: text("color"),
    position: integer("position").notNull().default(0),
    created_at: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (t) => [unique("domains_user_slug_unique").on(t.user_id, t.slug)]
);

export const pages = pgTable(
  "pages",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    slug: text("slug").notNull(),
    type: pageTypeEnum("type").notNull(),
    domain_id: uuid("domain_id").references(() => domains.id, {
      onDelete: "set null",
    }),
    title: text("title").notNull(),
    status: pageStatusEnum("status").notNull().default("draft"),
    body_md: text("body_md"),
    body_html: text("body_html"),
    metadata: jsonb("metadata"),
    embedding: text("embedding"), // stored as text until pgvector migration; vector(1536) added later
    source_count: integer("source_count").notNull().default(0),
    backlink_count: integer("backlink_count").notNull().default(0),
    last_compiled_at: timestamp("last_compiled_at", { withTimezone: true }),
    created_at: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
    updated_at: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (t) => [
    unique("pages_user_slug_unique").on(t.user_id, t.slug),
    index("pages_user_type").on(t.user_id, t.type),
    index("pages_user_domain").on(t.user_id, t.domain_id),
  ]
);

export const page_links = pgTable("page_links", {
  id: uuid("id").primaryKey().defaultRandom(),
  user_id: uuid("user_id")
    .notNull()
    .references(() => users.id, { onDelete: "cascade" }),
  from_page_id: uuid("from_page_id")
    .notNull()
    .references(() => pages.id, { onDelete: "cascade" }),
  to_page_id: uuid("to_page_id")
    .notNull()
    .references(() => pages.id, { onDelete: "cascade" }),
  via_memo_id: uuid("via_memo_id").references(() => memos.id, {
    onDelete: "set null",
  }),
  weight: real("weight").notNull().default(1),
  rationale: text("rationale"),
  created_at: timestamp("created_at", { withTimezone: true })
    .notNull()
    .defaultNow(),
});

export const page_sources = pgTable(
  "page_sources",
  {
    page_id: uuid("page_id")
      .notNull()
      .references(() => pages.id, { onDelete: "cascade" }),
    memo_id: uuid("memo_id")
      .notNull()
      .references(() => memos.id, { onDelete: "cascade" }),
    contribution: text("contribution"),
    weight: real("weight").notNull().default(1),
  },
  (t) => [primaryKey({ columns: [t.page_id, t.memo_id] })]
);

// ─── Re-export helper types ────────────────────────────────────────────────────

export type User = typeof users.$inferSelect;
export type NewUser = typeof users.$inferInsert;
export type Memo = typeof memos.$inferSelect;
export type NewMemo = typeof memos.$inferInsert;
export type MemoAttachment = typeof memo_attachments.$inferSelect;
export type NewMemoAttachment = typeof memo_attachments.$inferInsert;
export type Domain = typeof domains.$inferSelect;
export type NewDomain = typeof domains.$inferInsert;
export type Page = typeof pages.$inferSelect;
export type NewPage = typeof pages.$inferInsert;
export type PageLink = typeof page_links.$inferSelect;
export type NewPageLink = typeof page_links.$inferInsert;
export type PageSource = typeof page_sources.$inferSelect;
export type NewPageSource = typeof page_sources.$inferInsert;
