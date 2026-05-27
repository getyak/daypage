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
  customType,
} from "drizzle-orm/pg-core";
import { sql } from "drizzle-orm";

// vector(1536) stored as text until pgvector migration lands
const vectorText = customType<{ data: number[]; driverData: string }>({
  dataType() {
    return "text";
  },
  toDriver(val: number[]): string {
    return JSON.stringify(val);
  },
  fromDriver(val: string): number[] {
    try {
      return JSON.parse(val) as number[];
    } catch {
      return [];
    }
  },
});

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
  // NextAuth (@auth/drizzle-adapter) requires these column names verbatim
  emailVerified: timestamp("emailVerified", { mode: "date", withTimezone: true }),
  image: text("image"),
  created_at: timestamp("created_at", { withTimezone: true })
    .notNull()
    .defaultNow(),
  onboarded_at: timestamp("onboarded_at", { withTimezone: true }),
  settings: jsonb("settings"),
});

// ─── NextAuth (@auth/drizzle-adapter) tables ──────────────────────────────────
// Column names match the adapter's `DefaultPostgresSchema` exactly; do not
// rename to snake_case without also passing an overridden schema to
// `PostgresDrizzleAdapter` in src/auth.ts.

export const accounts = pgTable(
  "accounts",
  {
    userId: uuid("userId")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    type: text("type").notNull(),
    provider: text("provider").notNull(),
    providerAccountId: text("providerAccountId").notNull(),
    refresh_token: text("refresh_token"),
    access_token: text("access_token"),
    expires_at: integer("expires_at"),
    token_type: text("token_type"),
    scope: text("scope"),
    id_token: text("id_token"),
    session_state: text("session_state"),
  },
  (t) => [primaryKey({ columns: [t.provider, t.providerAccountId] })],
);

export const sessions = pgTable("sessions", {
  sessionToken: text("sessionToken").primaryKey(),
  userId: uuid("userId")
    .notNull()
    .references(() => users.id, { onDelete: "cascade" }),
  expires: timestamp("expires", { mode: "date", withTimezone: true }).notNull(),
});

export const verificationTokens = pgTable(
  "verificationTokens",
  {
    identifier: text("identifier").notNull(),
    token: text("token").notNull(),
    expires: timestamp("expires", { mode: "date", withTimezone: true }).notNull(),
  },
  (t) => [primaryKey({ columns: [t.identifier, t.token] })],
);

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
    weather: jsonb("weather"),
    device: text("device"),
    source_url: text("source_url"),
    ingest_mode: ingestModeEnum("ingest_mode").notNull().default("light"),
    compile_status: compileStatusEnum("compile_status")
      .notNull()
      .default("pending"),
    origin: originEnum("origin").notNull().default("web"),
    vault_path: text("vault_path"),
    compile_error: text("compile_error"),
    compile_step: text("compile_step"), // current pipeline step: normalize|embed|recall|compile|apply|notify
    embedding: text("embedding"), // JSON-encoded number[] — pgvector vector(1536) pending migration
    idempotency_key: text("idempotency_key"),
    updated_at: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
    // US-033: iOS↔Web field alignment
    source: text("source").notNull().default("web"),
    device_id: text("device_id"),
    mood: text("mood"),
    word_count: integer("word_count").notNull().default(0),
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
    version: integer("version").notNull().default(0),
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

// ─── US-008: Wave 1d — annotations + chat_threads + chat_messages + inbox_items + activities + devices + sync_state ───

export const chatThreadStatusEnum = pgEnum("chat_thread_status", [
  "active",
  "archived",
]);

export const chatMessageRoleEnum = pgEnum("chat_message_role", [
  "user",
  "assistant",
  "system",
]);

export const inboxItemKindEnum = pgEnum("inbox_item_kind", [
  "contradiction",
  "schema",
  "orphan",
  "compiled",
]);

export const inboxItemStatusEnum = pgEnum("inbox_item_status", [
  "open",
  "resolved",
  "dismissed",
  "snoozed",
]);

export const devicePlatformEnum = pgEnum("device_platform", [
  "ios",
  "web",
  "android",
]);

export const annotations = pgTable("annotations", {
  id: uuid("id").primaryKey().defaultRandom(),
  user_id: uuid("user_id")
    .notNull()
    .references(() => users.id, { onDelete: "cascade" }),
  page_id: uuid("page_id")
    .notNull()
    .references(() => pages.id, { onDelete: "cascade" }),
  anchor: jsonb("anchor").notNull(),
  tag: text("tag").notNull(),
  note: text("note"),
  created_at: timestamp("created_at", { withTimezone: true })
    .notNull()
    .defaultNow(),
});

export const chat_threads = pgTable("chat_threads", {
  id: uuid("id").primaryKey().defaultRandom(),
  user_id: uuid("user_id")
    .notNull()
    .references(() => users.id, { onDelete: "cascade" }),
  title: text("title").notNull().default("New conversation"),
  status: chatThreadStatusEnum("status").notNull().default("active"),
  synthesis_page_id: uuid("synthesis_page_id").references(() => pages.id, {
    onDelete: "set null",
  }),
  created_at: timestamp("created_at", { withTimezone: true })
    .notNull()
    .defaultNow(),
  updated_at: timestamp("updated_at", { withTimezone: true })
    .notNull()
    .defaultNow()
    .$onUpdate(() => new Date()),
});

export const chat_messages = pgTable("chat_messages", {
  id: uuid("id").primaryKey().defaultRandom(),
  thread_id: uuid("thread_id")
    .notNull()
    .references(() => chat_threads.id, { onDelete: "cascade" }),
  role: chatMessageRoleEnum("role").notNull(),
  content: text("content").notNull(),
  citations: jsonb("citations"),
  suggested: jsonb("suggested"),
  tokens_in: integer("tokens_in"),
  tokens_out: integer("tokens_out"),
  created_at: timestamp("created_at", { withTimezone: true })
    .notNull()
    .defaultNow(),
});

export const inbox_items = pgTable(
  "inbox_items",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    kind: inboxItemKindEnum("kind").notNull(),
    title: text("title").notNull(),
    body: text("body"),
    payload: jsonb("payload"),
    status: inboxItemStatusEnum("status").notNull().default("open"),
    resolution: jsonb("resolution"),
    created_at: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
    resolved_at: timestamp("resolved_at", { withTimezone: true }),
    snooze_until: timestamp("snooze_until", { withTimezone: true }),
  },
  (t) => [index("inbox_user_status").on(t.user_id, t.status)]
);

export const activities = pgTable(
  "activities",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    verb: text("verb").notNull(),
    subject: text("subject").notNull(),
    target_type: text("target_type"),
    target_id: text("target_id"),
    created_at: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (t) => [index("activities_user_created").on(t.user_id, t.created_at)]
);

export const devices = pgTable("devices", {
  id: uuid("id").primaryKey().defaultRandom(),
  user_id: uuid("user_id")
    .notNull()
    .references(() => users.id, { onDelete: "cascade" }),
  platform: devicePlatformEnum("platform").notNull(),
  push_token: text("push_token"),
  last_seen_at: timestamp("last_seen_at", { withTimezone: true }),
  metadata: jsonb("metadata"),
  created_at: timestamp("created_at", { withTimezone: true })
    .notNull()
    .defaultNow(),
});

export const sync_state = pgTable(
  "sync_state",
  {
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    device_id: uuid("device_id")
      .notNull()
      .references(() => devices.id, { onDelete: "cascade" }),
    cursor: timestamp("cursor", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.user_id, t.device_id] })]
);

// ─── US-020: Wave 4c — prompt_log (AI token usage tracking) ──────────────────

export const prompt_log = pgTable("prompt_log", {
  id: uuid("id").primaryKey().defaultRandom(),
  user_id: uuid("user_id").references(() => users.id, { onDelete: "set null" }),
  kind: text("kind").notNull(), // 'chat' | 'embed' | 'transcribe'
  model: text("model").notNull(),
  tokens_in: integer("tokens_in").notNull().default(0),
  tokens_out: integer("tokens_out").notNull().default(0),
  created_at: timestamp("created_at", { withTimezone: true })
    .notNull()
    .defaultNow(),
});

// ─── US-022: Wave 4e — embed_cache (hash → embedding, 7-day TTL) ─────────────

export const embed_cache = pgTable("embed_cache", {
  id: uuid("id").primaryKey().defaultRandom(),
  body_hash: text("body_hash").notNull().unique(),
  embedding: text("embedding").notNull(), // JSON-encoded number[]
  created_at: timestamp("created_at", { withTimezone: true })
    .notNull()
    .defaultNow(),
});

export type EmbedCache = typeof embed_cache.$inferSelect;
export type NewEmbedCache = typeof embed_cache.$inferInsert;

// ─── US-024: Wave 4g — change_log (agent/user mutation audit) ─────────────────

export const change_log = pgTable("change_log", {
  id: uuid("id").primaryKey().defaultRandom(),
  user_id: uuid("user_id")
    .notNull()
    .references(() => users.id, { onDelete: "cascade" }),
  action_kind: text("action_kind").notNull(), // e.g. 'create_page' | 'update_page' | 'create_link' | 'extract_entity'
  target_type: text("target_type").notNull(), // e.g. 'page' | 'page_link'
  target_id: text("target_id").notNull(),
  before: jsonb("before"),
  after: jsonb("after"),
  reason: text("reason"),
  performed_by: text("performed_by").notNull().default("agent"), // 'user' | 'agent'
  agent_action_id: text("agent_action_id"),
  created_at: timestamp("created_at", { withTimezone: true })
    .notNull()
    .defaultNow(),
});

export type ChangeLog = typeof change_log.$inferSelect;
export type NewChangeLog = typeof change_log.$inferInsert;

// ─── US-041: Wave 8b — schema_cluster_log (idempotency for schema-detect) ─────

export const schema_cluster_log = pgTable(
  "schema_cluster_log",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    cluster_signature: text("cluster_signature").notNull(),
    suggested_name: text("suggested_name"),
    inbox_item_id: uuid("inbox_item_id").references(() => inbox_items.id, {
      onDelete: "set null",
    }),
    created_at: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (t) => [index("schema_cluster_log_user").on(t.user_id, t.created_at)]
);

export type SchemaClusterLog = typeof schema_cluster_log.$inferSelect;
export type NewSchemaClusterLog = typeof schema_cluster_log.$inferInsert;

// ─── US-008: api_keys (API key management) ────────────────────────────────────

export const api_keys = pgTable(
  "api_keys",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    name: text("name").notNull(),
    key_hash: text("key_hash").notNull().unique(),
    key_prefix: text("key_prefix").notNull(), // first 8 chars of raw key for display
    scopes: jsonb("scopes").notNull().default(sql`'["read"]'::jsonb`),
    last_used_at: timestamp("last_used_at", { withTimezone: true }),
    created_at: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
    expires_at: timestamp("expires_at", { withTimezone: true }),
  },
  (t) => [
    index("api_keys_user_name").on(t.user_id, t.name),
  ]
);

export type ApiKey = typeof api_keys.$inferSelect;
export type NewApiKey = typeof api_keys.$inferInsert;

// ─── US-013: ingest_sources (external ingest channel configuration) ──────────

export const ingestSourceTypeEnum = pgEnum("ingest_source_type", [
  "telegram",
  "email",
  "rss",
  "webhook",
  "api_claude",
]);

export const ingest_sources = pgTable(
  "ingest_sources",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    name: text("name").notNull(),
    source_type: ingestSourceTypeEnum("source_type").notNull(),
    config: jsonb("config").notNull().default(sql`'{}'::jsonb`),
    enabled: boolean("enabled").notNull().default(true),
    created_at: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
    updated_at: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (t) => [index("ingest_sources_user_type").on(t.user_id, t.source_type)]
);

export type IngestSource = typeof ingest_sources.$inferSelect;
export type NewIngestSource = typeof ingest_sources.$inferInsert;

// ─── US-029: user_settings (cloud sync for settings) ─────────────────────────

export const user_settings = pgTable("user_settings", {
  user_id: uuid("user_id")
    .primaryKey()
    .references(() => users.id, { onDelete: "cascade" }),
  settings: jsonb("settings").notNull().default(sql`'{}'::jsonb`),
  updated_at: timestamp("updated_at", { withTimezone: true })
    .notNull()
    .defaultNow()
    .$onUpdate(() => new Date()),
});

export type UserSettings = typeof user_settings.$inferSelect;
export type NewUserSettings = typeof user_settings.$inferInsert;

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
export type Annotation = typeof annotations.$inferSelect;
export type NewAnnotation = typeof annotations.$inferInsert;
export type ChatThread = typeof chat_threads.$inferSelect;
export type NewChatThread = typeof chat_threads.$inferInsert;
export type ChatMessage = typeof chat_messages.$inferSelect;
export type NewChatMessage = typeof chat_messages.$inferInsert;
export type InboxItem = typeof inbox_items.$inferSelect;
export type NewInboxItem = typeof inbox_items.$inferInsert;
export type Activity = typeof activities.$inferSelect;
export type NewActivity = typeof activities.$inferInsert;
export type Device = typeof devices.$inferSelect;
export type NewDevice = typeof devices.$inferInsert;
export type SyncState = typeof sync_state.$inferSelect;
export type NewSyncState = typeof sync_state.$inferInsert;
export type PromptLog = typeof prompt_log.$inferSelect;
export type NewPromptLog = typeof prompt_log.$inferInsert;
