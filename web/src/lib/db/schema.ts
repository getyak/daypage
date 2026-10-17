import {
  pgTable,
  pgEnum,
  uuid,
  text,
  timestamp,
  jsonb,
  boolean,
  integer,
  bigint,
  real,
  index,
  unique,
  uniqueIndex,
  foreignKey,
  primaryKey,
  customType,
  check,
  type AnyPgColumn,
} from "drizzle-orm/pg-core";
import { sql } from "drizzle-orm";

// vector(1536) — native pgvector type after migration 0006_pgvector_hnsw.sql
const vectorText = customType<{ data: number[]; driverData: string }>({
  dataType() {
    return "vector(1536)";
  },
  toDriver(val: number[]): string {
    return `[${val.join(",")}]`;
  },
  fromDriver(val: string): number[] {
    try {
      // pgvector returns "[0.1,0.2,...]" format
      return (val as string)
        .replace(/^\[/, "")
        .replace(/\]$/, "")
        .split(",")
        .map(Number);
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

// ─── US-001: task tree (Git-style goal evolution) enums ───────────────────────

export const treeStatusEnum = pgEnum("tree_status", ["active", "archived"]);

export const treeNodeKindEnum = pgEnum("tree_node_kind", [
  "goal",
  "branch",
  "leaf",
]);

export const treeNodeStatusEnum = pgEnum("tree_node_status", [
  "growing",
  "mature",
  "merged",
  "pruned",
]);

// US-002: lifecycle of a durable orchestrator job. `gated` = paused awaiting a
// gate (e.g. user choice / budget); `dead` = exhausted retries, parked.
export const gatewayJobStatusEnum = pgEnum("gateway_job_status", [
  "queued",
  "running",
  "gated",
  "done",
  "failed",
  "dead",
]);

// US-003: lifecycle of an AI-generated task suggestion awaiting user choice.
// `open` = surfaced, awaiting selection; `selected` = user picked it; `dispatched`
// = handed to the executor; `dismissed` = user declined.
export const taskSuggestionStatusEnum = pgEnum("task_suggestion_status", [
  "open",
  "selected",
  "dispatched",
  "dismissed",
]);

// US-004: gating policy for a dispatched work order. `auto` = run with no human
// gate; `approve-first` = pause for user OK before dispatch; `approve-result` =
// run, then pause for user review of the result before it flows back.
export const workOrderGateEnum = pgEnum("work_order_gate", [
  "auto",
  "approve-first",
  "approve-result",
]);

// US-004: lifecycle of a work order. `gated` = paused at its gate awaiting user
// action; otherwise the usual pending→running→done/failed progression.
export const workOrderStatusEnum = pgEnum("work_order_status", [
  "pending",
  "gated",
  "approved",
  "rejected",
  "running",
  "done",
  "failed",
]);

// US-004: which executor backend an agent session runs on. `sandbox` = the
// self-hosted lightweight runner for cheap work; the others are outsourced
// heavy-lifting backends.
export const agentBackendEnum = pgEnum("agent_backend", [
  "claude-code",
  "openclaw",
  "ralph",
  "sandbox",
]);

// US-004: liveness of an agent backend session. Driven by heartbeats: `idle` =
// connected but no active work; `timed_out` = missed heartbeats; `closed` =
// torn down.
export const agentSessionStatusEnum = pgEnum("agent_session_status", [
  "active",
  "idle",
  "timed_out",
  "closed",
]);

// ─── Backend-first Agent Data Plane enums ───────────────────────────────────

export const skillVersionStatusEnum = pgEnum("skill_version_status", [
  "active",
  "deprecated",
  "disabled",
]);

export const toolEffectEnum = pgEnum("tool_effect", [
  "read",
  "internal_write",
  "external_write",
  "destructive",
]);

export const approvalModeEnum = pgEnum("approval_mode", [
  "auto",
  "confirm",
  "forbidden",
]);

export const automationTriggerTypeEnum = pgEnum("automation_trigger_type", [
  "event",
  "schedule",
  "manual",
]);

export const agentRunStatusEnum = pgEnum("agent_run_status", [
  "queued",
  "running",
  "completed",
  "failed",
  "cancelled",
  "needs_review",
]);

export const agentRunStepStatusEnum = pgEnum("agent_run_step_status", [
  "pending",
  "running",
  "completed",
  "failed",
  "skipped",
]);

export const artifactStatusEnum = pgEnum("artifact_status", [
  "draft",
  "live",
  "superseded",
  "archived",
  "needs_review",
]);

export const toolExecutionStatusEnum = pgEnum("tool_execution_status", [
  "pending",
  "running",
  "completed",
  "failed",
  "dead",
]);

export const evaluationExportStatusEnum = pgEnum("evaluation_export_status", [
  "pending",
  "running",
  "completed",
  "dead",
]);

// ─── US-006: Wave 1b — users + memos + memo_attachments ───────────────────────

// `public.users` is now a profile table: id mirrors `auth.users.id` (synced by
// the `handle_new_auth_user` trigger from migration 0024). The legacy
// `emailVerified`/`image` columns (required by @auth/drizzle-adapter) are gone.
export const users = pgTable("users", {
  id: uuid("id").primaryKey(),
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
    embedding: vectorText("embedding"),
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
    // #873: device outbox revision and tombstone fields. Vault remains the
    // capture source of truth; these fields make retries and deletes explicit.
    sync_revision: bigint("sync_revision", { mode: "number" }).notNull().default(0),
    source_modified_at: timestamp("source_modified_at", { withTimezone: true }),
    content_hash: text("content_hash"),
    attachment_manifest_hash: text("attachment_manifest_hash"),
    deleted_at: timestamp("deleted_at", { withTimezone: true }),
    last_sync_device_id: text("last_sync_device_id"),
    sync_change_sequence: bigint("sync_change_sequence", { mode: "number" })
      .notNull()
      .default(sql`nextval('public.daypage_memo_change_sequence')`),
  },
  (t) => [
    index("memos_user_created").on(t.user_id, t.created_at),
    index("memos_user_status").on(t.user_id, t.compile_status),
    index("memos_user_sync_cursor").on(t.user_id, t.updated_at, t.id),
    index("memos_user_sync_change_sequence").on(t.user_id, t.sync_change_sequence),
    index("memos_user_active_created")
      .on(t.user_id, t.created_at)
      .where(sql`${t.deleted_at} is null`),
    index("memos_embedding_hnsw").using("hnsw", t.embedding.op("vector_cosine_ops")),
    // #884: composite ownership key for memo_tag_links(user_id, memo_id) FKs.
    uniqueIndex("memos_user_id_id_unique").on(t.user_id, t.id),
  ]
);

export const memo_attachments = pgTable(
  "memo_attachments",
  {
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
    // #884: non-null only for a server-verified v2 manifest row. Legacy bulk
    // metadata remains readable but can never be mistaken for durable media.
    protocol_version: integer("protocol_version"),
    position: integer("position"),
    content_sha256: text("content_sha256"),
    duration_ms: integer("duration_ms"),
    transcription_status: text("transcription_status"),
    verified_at: timestamp("verified_at", { withTimezone: true }),
  },
  (t) => [
    uniqueIndex("memo_attachments_memo_position_v2")
      .on(t.memo_id, t.position)
      .where(sql`${t.content_sha256} is not null`),
    uniqueIndex("memo_attachments_memo_storage_v2")
      .on(t.memo_id, t.storage_key)
      .where(sql`${t.content_sha256} is not null`),
  ],
);

export const attachment_upload_reservations = pgTable(
  "attachment_upload_reservations",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    // A memo may not exist remotely until the v2 commit, so this deliberately
    // is not a foreign key.
    memo_id: uuid("memo_id").notNull(),
    object_key: text("object_key").notNull(),
    content_sha256: text("content_sha256").notNull(),
    size_bytes: bigint("size_bytes", { mode: "number" }).notNull(),
    mime_type: text("mime_type").notNull(),
    status: text("status").notNull().default("prepared"),
    expires_at: timestamp("expires_at", { withTimezone: true }).notNull(),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    committed_at: timestamp("committed_at", { withTimezone: true }),
  },
  (t) => [
    unique("attachment_upload_reservations_user_object_unique").on(t.user_id, t.object_key),
    index("attachment_upload_reservations_user_expiry").on(t.user_id, t.expires_at),
    index("attachment_upload_reservations_user_created").on(t.user_id, t.created_at),
  ],
);

export const attachment_gc_queue = pgTable(
  "attachment_gc_queue",
  {
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    object_key: text("object_key").notNull(),
    content_sha256: text("content_sha256").notNull(),
    reason: text("reason").notNull(),
    not_before: timestamp("not_before", { withTimezone: true }).notNull(),
    attempts: integer("attempts").notNull().default(0),
    status: text("status").notNull().default("pending"),
    last_error: text("last_error"),
    claimed_at: timestamp("claimed_at", { withTimezone: true }),
    lease_token: uuid("lease_token"),
    lease_expires_at: timestamp("lease_expires_at", { withTimezone: true }),
    deleted_at: timestamp("deleted_at", { withTimezone: true }),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    primaryKey({ columns: [t.user_id, t.object_key] }),
    index("attachment_gc_queue_due").on(t.not_before, t.lease_expires_at),
  ],
);

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
    embedding: vectorText("embedding"),
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

export const page_links = pgTable(
  "page_links",
  {
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
    // ─── US-040: temporal validity window ─────────────────────────────────────
    // A link is a *fact observed at a point in time*. `valid_from` is the day the
    // fact first held (defaults to created_at). `valid_to` is the day the fact was
    // superseded/invalidated — NULL means still valid. We invalidate by setting
    // valid_to rather than deleting the row, so an "as-of" query before that date
    // still sees the fact and an entity's history is a sequence, not an overwrite.
    valid_from: timestamp("valid_from", { withTimezone: true })
      .notNull()
      .defaultNow(),
    valid_to: timestamp("valid_to", { withTimezone: true }),
    created_at: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (t) => [
    index("page_links_user_valid").on(t.user_id, t.valid_from, t.valid_to),
  ]
);

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
  // US-041: structural gap — two clusters in the knowledge graph that the user
  // has written about for weeks but never connected. Payload carries the two
  // cluster summaries and an LLM-generated bridging question.
  "gap",
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
  // US-031: when set, this thread is a conversation with a user-defined agent.
  // Agent config (persona, model, retrieval scope) is resolved from this id at
  // chat time. NULL = the default wiki chat.
  agent_id: uuid("agent_id"),
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
    revoked_at: timestamp("revoked_at", { withTimezone: true }),
  },
  (t) => [
    index("api_keys_user_name").on(t.user_id, t.name),
  ]
);

export type ApiKey = typeof api_keys.$inferSelect;
export type NewApiKey = typeof api_keys.$inferInsert;

// ─── #873: exact sync receipts + OAuth MCP grants ────────────────────────────

export const sync_operations = pgTable(
  "sync_operations",
  {
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    operation_id: uuid("operation_id").notNull(),
    memo_id: uuid("memo_id").notNull(),
    kind: text("kind").notNull(),
    revision: bigint("revision", { mode: "number" }).notNull(),
    status: text("status").notNull(),
    protocol_version: integer("protocol_version").notNull().default(1),
    content_hash: text("content_hash"),
    attachment_manifest_hash: text("attachment_manifest_hash"),
    remote_revision: bigint("remote_revision", { mode: "number" }),
    applied_at: timestamp("applied_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    primaryKey({ columns: [t.user_id, t.operation_id] }),
    index("sync_operations_user_memo_revision").on(t.user_id, t.memo_id, t.revision),
  ],
);

export const mcp_client_grants = pgTable(
  "mcp_client_grants",
  {
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    client_id: text("client_id").notNull(),
    can_read: boolean("can_read").notNull().default(true),
    can_write: boolean("can_write").notNull().default(false),
    can_read_actions: boolean("can_read_actions").notNull().default(false),
    can_propose_actions: boolean("can_propose_actions").notNull().default(false),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updated_at: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
    revoked_at: timestamp("revoked_at", { withTimezone: true }),
  },
  (t) => [
    primaryKey({ columns: [t.user_id, t.client_id] }),
    index("mcp_client_grants_client_active").on(t.client_id, t.user_id),
  ],
);

export type SyncOperation = typeof sync_operations.$inferSelect;
export type AttachmentUploadReservation = typeof attachment_upload_reservations.$inferSelect;
export type AttachmentGcQueueItem = typeof attachment_gc_queue.$inferSelect;
export type McpClientGrant = typeof mcp_client_grants.$inferSelect;

// ─── #887: local-first Apple system action cloud replica ─────────────────────

export const system_action_proposals = pgTable(
  "system_action_proposals",
  {
    user_id: uuid("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
    proposal_id: uuid("proposal_id").notNull(),
    schema_version: integer("schema_version").notNull().default(1),
    revision: bigint("revision", { mode: "number" }).notNull(),
    kind: text("kind").notNull(),
    payload: jsonb("payload").notNull(),
    payload_hash: text("payload_hash").notNull(),
    title: text("title").notNull(),
    rationale: text("rationale").notNull().default(""),
    source_refs: jsonb("source_refs").notNull().default(sql`'[]'::jsonb`),
    creator_source: text("creator_source").notNull(),
    creator_device_id_hash: text("creator_device_id_hash"),
    redaction_level: text("redaction_level").notNull(),
    target_device_preference: text("target_device_preference").notNull(),
    target_device_id_hash: text("target_device_id_hash"),
    state: text("state").notNull().default("pending"),
    expires_at: timestamp("expires_at", { withTimezone: true }),
    deleted_at: timestamp("deleted_at", { withTimezone: true }),
    change_sequence: bigint("change_sequence", { mode: "number" }).notNull()
      .default(sql`nextval('public.daypage_system_action_change_sequence')`),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updated_at: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    primaryKey({ columns: [t.user_id, t.proposal_id] }),
    index("system_action_proposals_user_change").on(t.user_id, t.change_sequence),
    index("system_action_proposals_user_state_updated").on(t.user_id, t.state, t.updated_at),
  ],
);

export const system_action_approvals = pgTable(
  "system_action_approvals",
  {
    user_id: uuid("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
    approval_id: uuid("approval_id").notNull(),
    proposal_id: uuid("proposal_id").notNull(),
    schema_version: integer("schema_version").notNull().default(1),
    phase: text("phase").notNull(),
    proposal_revision: bigint("proposal_revision", { mode: "number" }).notNull(),
    payload_hash: text("payload_hash").notNull(),
    decision: text("decision").notNull(),
    device_id_hash: text("device_id_hash").notNull(),
    replacement_proposal_id: uuid("replacement_proposal_id"),
    change_sequence: bigint("change_sequence", { mode: "number" }).notNull()
      .default(sql`nextval('public.daypage_system_action_change_sequence')`),
    decided_at: timestamp("decided_at", { withTimezone: true }).notNull(),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    primaryKey({ columns: [t.user_id, t.approval_id] }),
    uniqueIndex("system_action_approvals_exact_decision").on(t.user_id, t.proposal_id, t.phase, t.proposal_revision),
    index("system_action_approvals_user_change").on(t.user_id, t.change_sequence),
  ],
);

export const system_action_receipts = pgTable(
  "system_action_receipts",
  {
    user_id: uuid("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
    receipt_id: uuid("receipt_id").notNull(),
    proposal_id: uuid("proposal_id").notNull(),
    schema_version: integer("schema_version").notNull().default(1),
    phase: text("phase").notNull(),
    proposal_revision: bigint("proposal_revision", { mode: "number" }).notNull(),
    payload_hash: text("payload_hash").notNull(),
    attempt: integer("attempt").notNull(),
    outcome: text("outcome").notNull(),
    device_id_hash: text("device_id_hash").notNull(),
    execution_mode: text("execution_mode").notNull(),
    lease_id: uuid("lease_id"),
    result: jsonb("result").notNull().default(sql`'{}'::jsonb`),
    error_code: text("error_code"),
    reconciliation_state: text("reconciliation_state").notNull(),
    undo_capability: text("undo_capability").notNull(),
    external_id_hash: text("external_id_hash"),
    change_sequence: bigint("change_sequence", { mode: "number" }).notNull()
      .default(sql`nextval('public.daypage_system_action_change_sequence')`),
    started_at: timestamp("started_at", { withTimezone: true }).notNull(),
    completed_at: timestamp("completed_at", { withTimezone: true }).notNull(),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    primaryKey({ columns: [t.user_id, t.receipt_id] }),
    uniqueIndex("system_action_receipts_attempt").on(
      t.user_id,
      t.proposal_id,
      t.phase,
      t.device_id_hash,
      t.attempt,
    ),
    index("system_action_receipts_user_change").on(t.user_id, t.change_sequence),
  ],
);

export const system_action_capability_policies = pgTable(
  "system_action_capability_policies",
  {
    user_id: uuid("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
    policy_id: uuid("policy_id").notNull(),
    schema_version: integer("schema_version").notNull().default(1),
    capability: text("capability").notNull(),
    revision: bigint("revision", { mode: "number" }).notNull(),
    is_offered: boolean("is_offered").notNull(),
    sync_enabled: boolean("sync_enabled").notNull(),
    disclosure_level: text("disclosure_level").notNull(),
    deleted_at: timestamp("deleted_at", { withTimezone: true }),
    change_sequence: bigint("change_sequence", { mode: "number" }).notNull()
      .default(sql`nextval('public.daypage_system_action_change_sequence')`),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updated_at: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    primaryKey({ columns: [t.user_id, t.policy_id] }),
    uniqueIndex("system_action_capability_policies_capability").on(t.user_id, t.capability),
    index("system_action_capability_policies_user_change").on(t.user_id, t.change_sequence),
  ],
);

export const system_action_sync_operations = pgTable(
  "system_action_sync_operations",
  {
    user_id: uuid("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
    operation_id: uuid("operation_id").notNull(),
    entity_type: text("entity_type").notNull(),
    entity_id: uuid("entity_id").notNull(),
    operation_kind: text("operation_kind").notNull(),
    revision: bigint("revision", { mode: "number" }).notNull(),
    request_fingerprint: text("request_fingerprint").notNull(),
    result: jsonb("result").notNull(),
    applied_at: timestamp("applied_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    primaryKey({ columns: [t.user_id, t.operation_id] }),
    index("system_action_sync_operations_entity").on(t.user_id, t.entity_type, t.entity_id),
  ],
);

export const system_action_execution_leases = pgTable(
  "system_action_execution_leases",
  {
    user_id: uuid("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
    lease_id: uuid("lease_id").notNull(),
    claim_operation_id: uuid("claim_operation_id").notNull(),
    proposal_id: uuid("proposal_id").notNull(),
    phase: text("phase").notNull(),
    proposal_revision: bigint("proposal_revision", { mode: "number" }).notNull(),
    payload_hash: text("payload_hash").notNull(),
    device_id_hash: text("device_id_hash").notNull(),
    expires_at: timestamp("expires_at", { withTimezone: true }).notNull(),
    released_at: timestamp("released_at", { withTimezone: true }),
    release_reason: text("release_reason"),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    primaryKey({ columns: [t.user_id, t.lease_id] }),
    uniqueIndex("system_action_execution_leases_claim").on(t.user_id, t.claim_operation_id),
    index("system_action_execution_leases_lookup").on(t.user_id, t.proposal_id, t.phase, t.expires_at),
  ],
);

export type SystemActionProposal = typeof system_action_proposals.$inferSelect;
export type SystemActionApproval = typeof system_action_approvals.$inferSelect;
export type SystemActionReceipt = typeof system_action_receipts.$inferSelect;
export type SystemActionCapabilityPolicy = typeof system_action_capability_policies.$inferSelect;
export type SystemActionSyncOperation = typeof system_action_sync_operations.$inferSelect;
export type SystemActionExecutionLease = typeof system_action_execution_leases.$inferSelect;

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
    // US-022: the compile tier memos from this source default to. High-value
    // sources (e.g. Readwise highlights) should declare "full" so they are not
    // under-processed; low-signal firehoses (RSS) stay "light".
    default_ingest_mode: ingestModeEnum("default_ingest_mode")
      .notNull()
      .default("light"),
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

// ─── US-036: api_logs (request-level error logging) ──────────────────────────

export const api_logs = pgTable(
  "api_logs",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    method: text("method").notNull(),
    path: text("path").notNull(),
    status: integer("status").notNull(),
    duration_ms: integer("duration_ms").notNull(),
    user_id: uuid("user_id").references(() => users.id, { onDelete: "set null" }),
    error: text("error"),
    created_at: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (t) => [index("api_logs_created").on(t.created_at)]
);

export type ApiLog = typeof api_logs.$inferSelect;
export type NewApiLog = typeof api_logs.$inferInsert;

// ─── US-031: agents (wiki-grounded, configurable AI agents) ──────────────────
// A user-defined agent is a persona prompt + a model choice + an optional
// retrieval scope (a domain). At chat time the agent grounds its answers by
// calling the SAME rag.ts retrievePages used by the MCP server (US-010), so
// answers cite real wiki content. The conversation history reuses the existing
// chat_threads / chat_messages tables, tagged with `agent_id`.

export const agents = pgTable(
  "agents",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    name: text("name").notNull(),
    persona_prompt: text("persona_prompt").notNull(),
    model: text("model").notNull().default("gpt-4o-mini"),
    // Optional retrieval scope: when set, RAG recall is restricted to pages in
    // this domain (passed through to retrievePages' `domain` option).
    domain_id: uuid("domain_id").references(() => domains.id, {
      onDelete: "set null",
    }),
    // Max wiki pages to recall per turn (passed to retrievePages topK).
    top_k: integer("top_k").notNull().default(8),
    instructions: text("instructions").notNull().default(""),
    model_policy: jsonb("model_policy")
      .notNull()
      .default(sql`'{"preferredModel":"gpt-4o-mini"}'::jsonb`),
    knowledge_scope: jsonb("knowledge_scope")
      .notNull()
      .default(sql`'{"topK":8}'::jsonb`),
    budget_policy: jsonb("budget_policy")
      .notNull()
      .default(sql`'{"maxInputTokens":16000,"maxOutputTokens":2048,"maxToolCalls":4,"timeoutSeconds":120}'::jsonb`),
    created_at: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
    updated_at: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (t) => [index("agents_user").on(t.user_id, t.created_at)]
);

export type Agent = typeof agents.$inferSelect;
export type NewAgent = typeof agents.$inferInsert;

// ─── US-001: trees + tree_nodes (Git-style task tree) ─────────────────────────
// A `tree` is a long-term goal; its `tree_nodes` form a Git-style branch graph
// that evolves over time. A node is a `goal` (root), a `branch` (a line of
// pursuit), or a `leaf` (a concrete actionable). `parent_id` self-references to
// build the tree; the root goal node has parent_id = NULL. `heat` ranks nodes
// for the Suggester; `evidence_memo_ids` cites the raw memos that grew the node;
// `page_id` optionally links a node to its compiled wiki page.

export const trees = pgTable("trees", {
  id: uuid("id").primaryKey().defaultRandom(),
  user_id: uuid("user_id")
    .notNull()
    .references(() => users.id, { onDelete: "cascade" }),
  title: text("title").notNull(),
  status: treeStatusEnum("status").notNull().default("active"),
  created_at: timestamp("created_at", { withTimezone: true })
    .notNull()
    .defaultNow(),
});

export const tree_nodes = pgTable(
  "tree_nodes",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    tree_id: uuid("tree_id")
      .notNull()
      .references(() => trees.id, { onDelete: "cascade" }),
    // Self-reference for the Git-style branch graph; NULL on the root goal node.
    parent_id: uuid("parent_id").references((): AnyPgColumn => tree_nodes.id, {
      onDelete: "cascade",
    }),
    kind: treeNodeKindEnum("kind").notNull(),
    status: treeNodeStatusEnum("status").notNull().default("growing"),
    title: text("title").notNull(),
    heat: real("heat").notNull().default(0),
    evidence_memo_ids: jsonb("evidence_memo_ids")
      .notNull()
      .default(sql`'[]'::jsonb`),
    page_id: uuid("page_id").references(() => pages.id, {
      onDelete: "set null",
    }),
    created_at: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
    updated_at: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (t) => [
    index("tree_nodes_tree").on(t.tree_id),
    // "user 经由 tree": tree_nodes have no direct user_id; scoping a user's nodes
    // goes through tree_id, so the per-tree index also serves user-scoped reads.
    index("tree_nodes_tree_parent").on(t.tree_id, t.parent_id),
  ]
);

export type Tree = typeof trees.$inferSelect;
export type NewTree = typeof trees.$inferInsert;
export type TreeNode = typeof tree_nodes.$inferSelect;
export type NewTreeNode = typeof tree_nodes.$inferInsert;

// ─── US-002: gateway_jobs (durable orchestrator job state machine) ────────────
// The Gateway scheduler enqueues durable jobs here so the orchestrator survives
// restarts. `idempotency_key` dedupes re-enqueues of the same logical job;
// `attempts`/`last_error` drive retry/backoff; `gate_state` carries opaque
// context while a job is `gated` (paused awaiting a user choice or budget).

export const gateway_jobs = pgTable(
  "gateway_jobs",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    type: text("type").notNull(),
    tree_id: uuid("tree_id").references(() => trees.id, {
      onDelete: "set null",
    }),
    payload: jsonb("payload").notNull().default(sql`'{}'::jsonb`),
    status: gatewayJobStatusEnum("status").notNull().default("queued"),
    idempotency_key: text("idempotency_key").notNull(),
    gate_state: text("gate_state"),
    attempts: integer("attempts").notNull().default(0),
    last_error: text("last_error"),
    available_at: timestamp("available_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
    lease_token: uuid("lease_token"),
    lease_expires_at: timestamp("lease_expires_at", { withTimezone: true }),
    coalesce_key: text("coalesce_key"),
    created_at: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
    updated_at: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (t) => [
    index("gateway_jobs_user_status").on(t.user_id, t.status),
    index("gateway_jobs_claimable").on(t.status, t.available_at, t.lease_expires_at),
    unique("gateway_jobs_idempotency_key_unique").on(t.idempotency_key),
  ]
);

export type GatewayJob = typeof gateway_jobs.$inferSelect;
export type NewGatewayJob = typeof gateway_jobs.$inferInsert;

// ─── US-003: task_suggestions (AI suggestions awaiting user selection) ─────────
// The Suggester writes candidate tasks here for the user to pick from. Each row
// optionally links to the `tree_node` it grew from (set null if that node is
// pruned). `estimate`/`suggested_target` hint the executor tier; `payload`
// carries opaque dispatch context (prompt, params) consumed when selected.

export const task_suggestions = pgTable(
  "task_suggestions",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    tree_node_id: uuid("tree_node_id").references(() => tree_nodes.id, {
      onDelete: "set null",
    }),
    title: text("title").notNull(),
    rationale: text("rationale").notNull(),
    estimate: text("estimate"),
    suggested_target: text("suggested_target"),
    status: taskSuggestionStatusEnum("status").notNull().default("open"),
    payload: jsonb("payload").notNull().default(sql`'{}'::jsonb`),
    created_at: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (t) => [index("task_suggestions_user_status").on(t.user_id, t.status)]
);

export type TaskSuggestion = typeof task_suggestions.$inferSelect;
export type NewTaskSuggestion = typeof task_suggestions.$inferInsert;

// ─── US-004: work_orders + agent_sessions (dispatch + executor sessions) ───────
// A `work_order` is a concrete unit of work dispatched to an executor. It may
// originate from a `task_suggestion` (set null if that suggestion is removed).
// `gate` controls whether/when it pauses for the user; `context`/`output_spec`
// brief the executor; `callback` carries where to report back; `result_ref`
// points at the produced artifact once `done`. An `agent_session` is a live
// connection to an executor `backend` (sandbox or an outsourced agent), tracked
// by heartbeats and token spend.

export const work_orders = pgTable(
  "work_orders",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    suggestion_id: uuid("suggestion_id").references(
      () => task_suggestions.id,
      { onDelete: "set null" },
    ),
    intent: text("intent").notNull(),
    context: jsonb("context").notNull().default(sql`'{}'::jsonb`),
    output_spec: text("output_spec"),
    gate: workOrderGateEnum("gate").notNull().default("approve-first"),
    callback: jsonb("callback"),
    budget_tokens: integer("budget_tokens"),
    status: workOrderStatusEnum("status").notNull().default("pending"),
    result_ref: text("result_ref"),
    run_id: uuid("run_id"),
    tool_key: text("tool_key"),
    arguments: jsonb("arguments"),
    effect: toolEffectEnum("effect"),
    approval_required: boolean("approval_required").notNull().default(true),
    approved_at: timestamp("approved_at", { withTimezone: true }),
    approved_by: uuid("approved_by"),
    rejected_at: timestamp("rejected_at", { withTimezone: true }),
    rejection_reason: text("rejection_reason"),
    provider_idempotency_key: text("provider_idempotency_key"),
    provider_receipt: jsonb("provider_receipt"),
    updated_at: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
    created_at: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (t) => [index("work_orders_user_status").on(t.user_id, t.status)]
);

export const agent_sessions = pgTable(
  "agent_sessions",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    backend: agentBackendEnum("backend").notNull(),
    external_ref: text("external_ref"),
    project: text("project"),
    status: agentSessionStatusEnum("status").notNull().default("active"),
    last_heartbeat_at: timestamp("last_heartbeat_at", { withTimezone: true }),
    tokens_used: integer("tokens_used").notNull().default(0),
    created_at: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (t) => [index("agent_sessions_user_status").on(t.user_id, t.status)]
);

export type WorkOrder = typeof work_orders.$inferSelect;
export type NewWorkOrder = typeof work_orders.$inferInsert;
export type AgentSession = typeof agent_sessions.$inferSelect;
export type NewAgentSession = typeof agent_sessions.$inferInsert;

// ─── Backend-first Agent Data Plane ─────────────────────────────────────────

export const skill_versions = pgTable(
  "skill_versions",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    key: text("key").notNull(),
    version: text("version").notNull(),
    description: text("description").notNull().default(""),
    manifest: jsonb("manifest").notNull().default(sql`'{}'::jsonb`),
    input_schema: jsonb("input_schema").notNull().default(sql`'{}'::jsonb`),
    output_schema: jsonb("output_schema").notNull().default(sql`'{}'::jsonb`),
    required_tools: jsonb("required_tools").notNull().default(sql`'[]'::jsonb`),
    optional_tools: jsonb("optional_tools").notNull().default(sql`'[]'::jsonb`),
    default_risk: toolEffectEnum("default_risk").notNull().default("read"),
    implementation_ref: text("implementation_ref").notNull(),
    checksum: text("checksum").notNull(),
    status: skillVersionStatusEnum("status").notNull().default("active"),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    unique("skill_versions_key_version_unique").on(t.key, t.version),
    unique("skill_versions_checksum_unique").on(t.checksum),
    index("skill_versions_key_status").on(t.key, t.status),
  ],
);

export const tool_definitions = pgTable("tool_definitions", {
  key: text("key").primaryKey(),
  source: text("source").notNull(),
  effect: toolEffectEnum("effect").notNull(),
  input_schema: jsonb("input_schema").notNull().default(sql`'{}'::jsonb`),
  output_schema: jsonb("output_schema").notNull().default(sql`'{}'::jsonb`),
  default_approval: approvalModeEnum("default_approval").notNull().default("forbidden"),
  required_scopes: jsonb("required_scopes").notNull().default(sql`'[]'::jsonb`),
  timeout_seconds: integer("timeout_seconds").notNull().default(30),
  max_result_bytes: integer("max_result_bytes").notNull().default(65_536),
  enabled: boolean("enabled").notNull().default(true),
  created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updated_at: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
});

export const tool_connections = pgTable(
  "tool_connections",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    provider: text("provider").notNull(),
    auth_ref: text("auth_ref").notNull(),
    scopes: jsonb("scopes").notNull().default(sql`'[]'::jsonb`),
    status: text("status").notNull().default("active"),
    metadata: jsonb("metadata").notNull().default(sql`'{}'::jsonb`),
    revoked_at: timestamp("revoked_at", { withTimezone: true }),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updated_at: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    index("tool_connections_user_status").on(t.user_id, t.status),
    unique("tool_connections_user_provider_auth_unique").on(t.user_id, t.provider, t.auth_ref),
  ],
);

export const agent_skill_bindings = pgTable(
  "agent_skill_bindings",
  {
    agent_id: uuid("agent_id")
      .notNull()
      .references(() => agents.id, { onDelete: "cascade" }),
    skill_version_id: uuid("skill_version_id")
      .notNull()
      .references(() => skill_versions.id, { onDelete: "cascade" }),
    enabled: boolean("enabled").notNull().default(true),
    priority: integer("priority").notNull().default(0),
    config: jsonb("config").notNull().default(sql`'{}'::jsonb`),
  },
  (t) => [primaryKey({ columns: [t.agent_id, t.skill_version_id] })],
);

export const agent_tool_bindings = pgTable(
  "agent_tool_bindings",
  {
    agent_id: uuid("agent_id")
      .notNull()
      .references(() => agents.id, { onDelete: "cascade" }),
    tool_key: text("tool_key")
      .notNull()
      .references(() => tool_definitions.key, { onDelete: "cascade" }),
    connection_id: uuid("connection_id").references(() => tool_connections.id, {
      onDelete: "set null",
    }),
    approval_override: approvalModeEnum("approval_override"),
    enabled: boolean("enabled").notNull().default(true),
  },
  (t) => [primaryKey({ columns: [t.agent_id, t.tool_key] })],
);

export const automations = pgTable(
  "automations",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    name: text("name").notNull(),
    trigger_type: automationTriggerTypeEnum("trigger_type").notNull(),
    trigger: jsonb("trigger").notNull().default(sql`'{}'::jsonb`),
    timezone: text("timezone").notNull().default("UTC"),
    agent_id: uuid("agent_id").references(() => agents.id, { onDelete: "set null" }),
    skill_version_id: uuid("skill_version_id")
      .notNull()
      .references(() => skill_versions.id, { onDelete: "restrict" }),
    input_selector: jsonb("input_selector").notNull().default(sql`'{}'::jsonb`),
    coalesce_policy: jsonb("coalesce_policy").notNull().default(sql`'{}'::jsonb`),
    enabled: boolean("enabled").notNull().default(true),
    next_due_at: timestamp("next_due_at", { withTimezone: true }),
    last_enqueued_at: timestamp("last_enqueued_at", { withTimezone: true }),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updated_at: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [index("automations_due").on(t.enabled, t.next_due_at)],
);

export const agent_runs = pgTable(
  "agent_runs",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    trigger_type: text("trigger_type").notNull(),
    trigger_ref: text("trigger_ref"),
    trigger_snapshot: jsonb("trigger_snapshot").notNull().default(sql`'{}'::jsonb`),
    memo_id: uuid("memo_id").references(() => memos.id, { onDelete: "set null" }),
    memo_revision: bigint("memo_revision", { mode: "number" }),
    agent_id: uuid("agent_id").references(() => agents.id, { onDelete: "set null" }),
    skill_version_id: uuid("skill_version_id")
      .notNull()
      .references(() => skill_versions.id, { onDelete: "restrict" }),
    agent_snapshot: jsonb("agent_snapshot").notNull().default(sql`'{}'::jsonb`),
    skill_snapshot: jsonb("skill_snapshot").notNull().default(sql`'{}'::jsonb`),
    tool_policy_snapshot: jsonb("tool_policy_snapshot").notNull().default(sql`'{}'::jsonb`),
    skill_checksum: text("skill_checksum").notNull(),
    idempotency_key: text("idempotency_key").notNull(),
    attempt: integer("attempt").notNull().default(1),
    is_canonical: boolean("is_canonical").notNull().default(true),
    shadow: boolean("shadow").notNull().default(false),
    status: agentRunStatusEnum("status").notNull().default("queued"),
    summary: text("summary"),
    budget: jsonb("budget").notNull().default(sql`'{}'::jsonb`),
    error: jsonb("error"),
    started_at: timestamp("started_at", { withTimezone: true }),
    completed_at: timestamp("completed_at", { withTimezone: true }),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updated_at: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    unique("agent_runs_user_key_attempt_unique").on(t.user_id, t.idempotency_key, t.attempt),
    uniqueIndex("agent_runs_one_canonical")
      .on(t.user_id, t.idempotency_key)
      .where(sql`${t.is_canonical} = true`),
    index("agent_runs_user_status_created").on(t.user_id, t.status, t.created_at),
    index("agent_runs_memo").on(t.user_id, t.memo_id, t.created_at),
  ],
);

export const agent_run_steps = pgTable(
  "agent_run_steps",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    run_id: uuid("run_id")
      .notNull()
      .references(() => agent_runs.id, { onDelete: "cascade" }),
    ordinal: integer("ordinal").notNull(),
    step_key: text("step_key").notNull(),
    tool_key: text("tool_key").references(() => tool_definitions.key, {
      onDelete: "set null",
    }),
    status: agentRunStepStatusEnum("status").notNull().default("pending"),
    input_hash: text("input_hash"),
    output_hash: text("output_hash"),
    tokens_in: integer("tokens_in").notNull().default(0),
    tokens_out: integer("tokens_out").notNull().default(0),
    duration_ms: integer("duration_ms").notNull().default(0),
    receipt: jsonb("receipt").notNull().default(sql`'{}'::jsonb`),
    error: jsonb("error"),
    started_at: timestamp("started_at", { withTimezone: true }),
    completed_at: timestamp("completed_at", { withTimezone: true }),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    unique("agent_run_steps_run_ordinal_unique").on(t.run_id, t.ordinal),
    unique("agent_run_steps_run_key_unique").on(t.run_id, t.step_key),
  ],
);

export const agent_artifacts = pgTable(
  "agent_artifacts",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    run_id: uuid("run_id")
      .notNull()
      .references(() => agent_runs.id, { onDelete: "cascade" }),
    kind: text("kind").notNull(),
    schema_version: integer("schema_version").notNull().default(1),
    logical_key: text("logical_key").notNull(),
    payload: jsonb("payload").notNull().default(sql`'{}'::jsonb`),
    body_md: text("body_md"),
    status: artifactStatusEnum("status").notNull().default("draft"),
    revision: integer("revision").notNull().default(1),
    source_set_hash: text("source_set_hash"),
    local_date: text("local_date"),
    timezone: text("timezone"),
    perspective_key: text("perspective_key").notNull().default("canonical"),
    supersedes_id: uuid("supersedes_id").references(
      (): AnyPgColumn => agent_artifacts.id,
      { onDelete: "set null" },
    ),
    finalized_at: timestamp("finalized_at", { withTimezone: true }),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updated_at: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    unique("agent_artifacts_logical_revision_unique").on(
      t.user_id,
      t.logical_key,
      t.perspective_key,
      t.revision,
    ),
    index("agent_artifacts_user_kind_status").on(t.user_id, t.kind, t.status),
    index("agent_artifacts_local_date").on(t.user_id, t.local_date, t.kind),
  ],
);

export const artifact_sources = pgTable(
  "artifact_sources",
  {
    artifact_id: uuid("artifact_id")
      .notNull()
      .references(() => agent_artifacts.id, { onDelete: "cascade" }),
    memo_id: uuid("memo_id").references(() => memos.id, { onDelete: "set null" }),
    page_id: uuid("page_id").references(() => pages.id, { onDelete: "set null" }),
    source_artifact_id: uuid("source_artifact_id").references(
      () => agent_artifacts.id,
      { onDelete: "set null" },
    ),
    span_start: integer("span_start"),
    span_end: integer("span_end"),
    provenance: text("provenance").notNull().default("direct"),
    weight: real("weight").notNull().default(1),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    unique("artifact_sources_unique").on(
      t.artifact_id,
      t.memo_id,
      t.page_id,
      t.source_artifact_id,
      t.span_start,
      t.span_end,
    ),
    index("artifact_sources_memo").on(t.memo_id, t.artifact_id),
  ],
);

export const tool_execution_outbox = pgTable(
  "tool_execution_outbox",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    work_order_id: uuid("work_order_id")
      .notNull()
      .references(() => work_orders.id, { onDelete: "cascade" }),
    tool_key: text("tool_key")
      .notNull()
      .references(() => tool_definitions.key, { onDelete: "restrict" }),
    connection_id: uuid("connection_id").references(() => tool_connections.id, {
      onDelete: "set null",
    }),
    arguments: jsonb("arguments").notNull().default(sql`'{}'::jsonb`),
    idempotency_key: text("idempotency_key").notNull(),
    status: toolExecutionStatusEnum("status").notNull().default("pending"),
    attempts: integer("attempts").notNull().default(0),
    available_at: timestamp("available_at", { withTimezone: true }).notNull().defaultNow(),
    lease_token: uuid("lease_token"),
    lease_expires_at: timestamp("lease_expires_at", { withTimezone: true }),
    provider_receipt: jsonb("provider_receipt"),
    last_error: text("last_error"),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updated_at: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    unique("tool_execution_outbox_idempotency_unique").on(t.idempotency_key),
    index("tool_execution_outbox_due").on(t.status, t.available_at, t.lease_expires_at),
  ],
);

// ─── Agent Evaluation Plane ─────────────────────────────────────────────────

export const agent_feedback_events = pgTable(
  "agent_feedback_events",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    run_id: uuid("run_id")
      .notNull()
      .references(() => agent_runs.id, { onDelete: "cascade" }),
    artifact_id: uuid("artifact_id").references(() => agent_artifacts.id, {
      onDelete: "set null",
    }),
    work_order_id: uuid("work_order_id").references(() => work_orders.id, {
      onDelete: "set null",
    }),
    event_type: text("event_type").notNull(),
    value: real("value"),
    reason_code: text("reason_code"),
    correction: jsonb("correction"),
    metadata: jsonb("metadata").notNull().default(sql`'{}'::jsonb`),
    idempotency_key: text("idempotency_key").notNull(),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    unique("agent_feedback_events_idempotency_unique").on(t.idempotency_key),
    index("agent_feedback_events_run_created").on(t.run_id, t.created_at),
    index("agent_feedback_events_user_type_created").on(t.user_id, t.event_type, t.created_at),
    check(
      "agent_feedback_events_value_check",
      sql`${t.value} is null or (${t.value} >= -1 and ${t.value} <= 1)`,
    ),
    check(
      "agent_feedback_events_target_check",
      sql`${t.artifact_id} is null or ${t.work_order_id} is null`,
    ),
  ],
);

export const evaluation_results = pgTable(
  "evaluation_results",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    run_id: uuid("run_id")
      .notNull()
      .references(() => agent_runs.id, { onDelete: "cascade" }),
    step_id: uuid("step_id").references(() => agent_run_steps.id, { onDelete: "cascade" }),
    evaluator_key: text("evaluator_key").notNull(),
    evaluator_version: text("evaluator_version").notNull(),
    source: text("source").notNull(),
    score: real("score").notNull(),
    passed: boolean("passed").notNull(),
    reason: text("reason"),
    evidence: jsonb("evidence").notNull().default(sql`'{}'::jsonb`),
    idempotency_key: text("idempotency_key").notNull(),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    unique("evaluation_results_idempotency_unique").on(t.idempotency_key),
    index("evaluation_results_run_key").on(t.run_id, t.evaluator_key),
    index("evaluation_results_user_passed_created").on(t.user_id, t.passed, t.created_at),
    check("evaluation_results_score_check", sql`${t.score} >= 0 and ${t.score} <= 1`),
    check(
      "evaluation_results_source_check",
      sql`${t.source} in ('deterministic', 'llm_judge', 'human', 'behavior')`,
    ),
  ],
);

export const evaluation_case_candidates = pgTable(
  "evaluation_case_candidates",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    run_id: uuid("run_id")
      .notNull()
      .references(() => agent_runs.id, { onDelete: "cascade" }),
    feedback_event_id: uuid("feedback_event_id").references(() => agent_feedback_events.id, {
      onDelete: "set null",
    }),
    reason: text("reason").notNull(),
    privacy_class: text("privacy_class").notNull().default("private"),
    sanitization_status: text("sanitization_status").notNull().default("pending"),
    review_status: text("review_status").notNull().default("candidate"),
    sanitized_case: jsonb("sanitized_case"),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updated_at: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    index("evaluation_case_candidates_review").on(t.review_status, t.created_at),
    unique("evaluation_case_candidates_feedback_unique").on(t.feedback_event_id),
    check(
      "evaluation_case_candidates_privacy_check",
      sql`${t.privacy_class} in ('private', 'redacted', 'synthetic', 'consented')`,
    ),
    check(
      "evaluation_case_candidates_sanitization_check",
      sql`${t.sanitization_status} in ('pending', 'redacted', 'approved', 'rejected')`,
    ),
    check(
      "evaluation_case_candidates_review_check",
      sql`${t.review_status} in ('candidate', 'reviewing', 'accepted', 'rejected')`,
    ),
  ],
);

export const evaluation_export_outbox = pgTable(
  "evaluation_export_outbox",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    run_id: uuid("run_id").references(() => agent_runs.id, { onDelete: "cascade" }),
    entity_type: text("entity_type").notNull(),
    entity_id: uuid("entity_id").notNull(),
    operation: text("operation").notNull(),
    privacy_mode: text("privacy_mode").notNull().default("metadata_only"),
    payload: jsonb("payload").notNull().default(sql`'{}'::jsonb`),
    idempotency_key: text("idempotency_key").notNull(),
    status: evaluationExportStatusEnum("status").notNull().default("pending"),
    attempts: integer("attempts").notNull().default(0),
    available_at: timestamp("available_at", { withTimezone: true }).notNull().defaultNow(),
    lease_token: uuid("lease_token"),
    lease_expires_at: timestamp("lease_expires_at", { withTimezone: true }),
    external_id: text("external_id"),
    last_error: text("last_error"),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updated_at: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    unique("evaluation_export_outbox_idempotency_unique").on(t.idempotency_key),
    index("evaluation_export_outbox_due").on(t.status, t.available_at, t.lease_expires_at),
    index("evaluation_export_outbox_run").on(t.run_id, t.created_at),
    check("evaluation_export_outbox_attempts_check", sql`${t.attempts} >= 0`),
    check(
      "evaluation_export_outbox_entity_check",
      sql`${t.entity_type} in ('trace', 'feedback', 'evaluation_result', 'dataset_item', 'experiment')`,
    ),
    check(
      "evaluation_export_outbox_operation_check",
      sql`${t.operation} in ('upsert', 'score', 'insert', 'delete')`,
    ),
    check(
      "evaluation_export_outbox_privacy_check",
      sql`${t.privacy_mode} in ('metadata_only', 'redacted', 'full_content_opt_in')`,
    ),
  ],
);

export const evaluation_experiments = pgTable(
  "evaluation_experiments",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    created_by: uuid("created_by").references(() => users.id, { onDelete: "set null" }),
    name: text("name").notNull(),
    dataset_name: text("dataset_name").notNull(),
    dataset_version: text("dataset_version").notNull(),
    baseline_config: jsonb("baseline_config").notNull().default(sql`'{}'::jsonb`),
    candidate_config: jsonb("candidate_config").notNull().default(sql`'{}'::jsonb`),
    thresholds: jsonb("thresholds").notNull().default(sql`'{}'::jsonb`),
    results: jsonb("results").notNull().default(sql`'{}'::jsonb`),
    git_sha: text("git_sha"),
    status: text("status").notNull().default("pending"),
    promotion_decision: text("promotion_decision"),
    opik_experiment_id: text("opik_experiment_id"),
    opik_url: text("opik_url"),
    started_at: timestamp("started_at", { withTimezone: true }),
    completed_at: timestamp("completed_at", { withTimezone: true }),
    created_at: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updated_at: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    unique("evaluation_experiments_name_unique").on(t.name),
    index("evaluation_experiments_dataset_created").on(t.dataset_name, t.created_at),
    check(
      "evaluation_experiments_status_check",
      sql`${t.status} in ('pending', 'running', 'completed', 'failed')`,
    ),
    check(
      "evaluation_experiments_promotion_check",
      sql`${t.promotion_decision} is null or ${t.promotion_decision} in ('promote', 'hold', 'reject')`,
    ),
  ],
);

export type SkillVersion = typeof skill_versions.$inferSelect;
export type ToolDefinition = typeof tool_definitions.$inferSelect;
export type ToolConnection = typeof tool_connections.$inferSelect;
export type Automation = typeof automations.$inferSelect;
export type AgentRun = typeof agent_runs.$inferSelect;
export type AgentRunStep = typeof agent_run_steps.$inferSelect;
export type AgentArtifact = typeof agent_artifacts.$inferSelect;
export type ArtifactSource = typeof artifact_sources.$inferSelect;
export type ToolExecutionOutboxItem = typeof tool_execution_outbox.$inferSelect;
export type AgentFeedbackEvent = typeof agent_feedback_events.$inferSelect;
export type EvaluationResult = typeof evaluation_results.$inferSelect;
export type EvaluationCaseCandidate = typeof evaluation_case_candidates.$inferSelect;
export type EvaluationExportOutboxItem = typeof evaluation_export_outbox.$inferSelect;
export type EvaluationExperiment = typeof evaluation_experiments.$inferSelect;

// ─── #884: account-scoped imported flomo tag preservation ───────────────────

// Exact label text: byte-exact equality/ordering via text COLLATE "C" in the
// database. Labels keep their original leading '#', Unicode, case, punctuation,
// and hierarchy; there is no normalization, splitting, or parent invention.
const collateCText = customType<{ data: string; driverData: string }>({
  dataType() {
    return 'text COLLATE "C"';
  },
});

export const user_tags = pgTable(
  "user_tags",
  {
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    label: collateCText("label").notNull(),
    in_import_catalog: boolean("in_import_catalog").notNull().default(false),
  },
  (t) => [
    primaryKey({ name: "user_tags_pk", columns: [t.user_id, t.label] }),
  ],
);

export const memo_tag_links = pgTable(
  "memo_tag_links",
  {
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    memo_id: uuid("memo_id").notNull(),
    label: collateCText("label").notNull(),
  },
  (t) => [
    primaryKey({ name: "memo_tag_links_pk", columns: [t.user_id, t.memo_id, t.label] }),
    index("memo_tag_links_user_label_memo").on(t.user_id, t.label, t.memo_id),
    foreignKey({
      name: "memo_tag_links_user_memo_fk",
      columns: [t.user_id, t.memo_id],
      foreignColumns: [memos.user_id, memos.id],
    }).onDelete("cascade"),
    foreignKey({
      name: "memo_tag_links_user_label_fk",
      columns: [t.user_id, t.label],
      foreignColumns: [user_tags.user_id, user_tags.label],
    }).onDelete("cascade"),
  ],
);

// Immutable import receipts: one row per (account, source digest). The payload
// is canonical version-1 metadata ({version,catalog,memos}); it holds no note
// body and no auth state, and later tombstones never rewrite it or its counts.
// payload_hash is the opaque server-side fingerprint over PostgreSQL
// jsonb::text (lowerhex text) - not a portable Swift/JS JSON digest.
export const memo_tag_imports = pgTable(
  "memo_tag_imports",
  {
    user_id: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    source_sha256: text("source_sha256").notNull(),
    payload_hash: text("payload_hash").notNull(),
    payload: jsonb("payload").notNull(),
    version: integer("version").notNull().default(1),
    created_at: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (t) => [
    primaryKey({ name: "memo_tag_imports_pk", columns: [t.user_id, t.source_sha256] }),
    check("memo_tag_imports_source_sha256_check", sql`${t.source_sha256} ~ '^[0-9a-f]{64}$'`),
    check("memo_tag_imports_payload_hash_check", sql`${t.payload_hash} ~ '^[0-9a-f]{64}$'`),
    check("memo_tag_imports_version_check", sql`${t.version} = 1`),
    check("memo_tag_imports_payload_shape_check", sql`jsonb_typeof(${t.payload}) = 'object'`),
  ],
);

export type UserTag = typeof user_tags.$inferSelect;
export type NewUserTag = typeof user_tags.$inferInsert;
export type MemoTagLink = typeof memo_tag_links.$inferSelect;
export type NewMemoTagLink = typeof memo_tag_links.$inferInsert;
export type MemoTagImport = typeof memo_tag_imports.$inferSelect;
export type NewMemoTagImport = typeof memo_tag_imports.$inferInsert;

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
