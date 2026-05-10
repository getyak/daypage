CREATE TYPE "public"."attachment_kind" AS ENUM('audio', 'photo', 'file');--> statement-breakpoint
CREATE TYPE "public"."compile_status" AS ENUM('pending', 'running', 'done', 'failed');--> statement-breakpoint
CREATE TYPE "public"."ingest_mode" AS ENUM('light', 'full');--> statement-breakpoint
CREATE TYPE "public"."memo_type" AS ENUM('text', 'url', 'voice', 'photo', 'file');--> statement-breakpoint
CREATE TYPE "public"."origin" AS ENUM('ios', 'web', 'api');--> statement-breakpoint
CREATE TYPE "public"."page_status" AS ENUM('draft', 'live', 'archived');--> statement-breakpoint
CREATE TYPE "public"."page_type" AS ENUM('concept', 'source', 'entity', 'synthesis', 'daily');--> statement-breakpoint
CREATE TABLE "domains" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"slug" text NOT NULL,
	"label" text NOT NULL,
	"color" text,
	"position" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "domains_user_slug_unique" UNIQUE("user_id","slug")
);
--> statement-breakpoint
CREATE TABLE "memo_attachments" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"memo_id" uuid NOT NULL,
	"kind" "attachment_kind" NOT NULL,
	"storage_key" text NOT NULL,
	"filename" text,
	"mime_type" text,
	"size_bytes" integer,
	"duration_sec" real,
	"transcript" text,
	"ocr_text" text,
	"exif" jsonb
);
--> statement-breakpoint
CREATE TABLE "memos" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"type" "memo_type" DEFAULT 'text' NOT NULL,
	"body" text DEFAULT '' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"pinned_at" timestamp with time zone,
	"location" jsonb,
	"weather" text,
	"device" text,
	"source_url" text,
	"ingest_mode" "ingest_mode" DEFAULT 'light' NOT NULL,
	"compile_status" "compile_status" DEFAULT 'pending' NOT NULL,
	"origin" "origin" DEFAULT 'web' NOT NULL,
	"vault_path" text,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "page_links" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"from_page_id" uuid NOT NULL,
	"to_page_id" uuid NOT NULL,
	"via_memo_id" uuid,
	"weight" real DEFAULT 1 NOT NULL,
	"rationale" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "page_sources" (
	"page_id" uuid NOT NULL,
	"memo_id" uuid NOT NULL,
	"contribution" text,
	"weight" real DEFAULT 1 NOT NULL,
	CONSTRAINT "page_sources_page_id_memo_id_pk" PRIMARY KEY("page_id","memo_id")
);
--> statement-breakpoint
CREATE TABLE "pages" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"slug" text NOT NULL,
	"type" "page_type" NOT NULL,
	"domain_id" uuid,
	"title" text NOT NULL,
	"status" "page_status" DEFAULT 'draft' NOT NULL,
	"body_md" text,
	"body_html" text,
	"metadata" jsonb,
	"embedding" text,
	"source_count" integer DEFAULT 0 NOT NULL,
	"backlink_count" integer DEFAULT 0 NOT NULL,
	"last_compiled_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "pages_user_slug_unique" UNIQUE("user_id","slug")
);
--> statement-breakpoint
CREATE TABLE "users" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"email" text,
	"apple_sub" text,
	"name" text,
	"avatar_url" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"onboarded_at" timestamp with time zone,
	"settings" jsonb,
	CONSTRAINT "users_email_unique" UNIQUE("email"),
	CONSTRAINT "users_apple_sub_unique" UNIQUE("apple_sub")
);
--> statement-breakpoint
ALTER TABLE "domains" ADD CONSTRAINT "domains_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "memo_attachments" ADD CONSTRAINT "memo_attachments_memo_id_memos_id_fk" FOREIGN KEY ("memo_id") REFERENCES "public"."memos"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "memos" ADD CONSTRAINT "memos_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "page_links" ADD CONSTRAINT "page_links_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "page_links" ADD CONSTRAINT "page_links_from_page_id_pages_id_fk" FOREIGN KEY ("from_page_id") REFERENCES "public"."pages"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "page_links" ADD CONSTRAINT "page_links_to_page_id_pages_id_fk" FOREIGN KEY ("to_page_id") REFERENCES "public"."pages"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "page_links" ADD CONSTRAINT "page_links_via_memo_id_memos_id_fk" FOREIGN KEY ("via_memo_id") REFERENCES "public"."memos"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "page_sources" ADD CONSTRAINT "page_sources_page_id_pages_id_fk" FOREIGN KEY ("page_id") REFERENCES "public"."pages"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "page_sources" ADD CONSTRAINT "page_sources_memo_id_memos_id_fk" FOREIGN KEY ("memo_id") REFERENCES "public"."memos"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "pages" ADD CONSTRAINT "pages_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "pages" ADD CONSTRAINT "pages_domain_id_domains_id_fk" FOREIGN KEY ("domain_id") REFERENCES "public"."domains"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "memos_user_created" ON "memos" USING btree ("user_id","created_at");--> statement-breakpoint
CREATE INDEX "memos_user_status" ON "memos" USING btree ("user_id","compile_status");--> statement-breakpoint
CREATE INDEX "pages_user_type" ON "pages" USING btree ("user_id","type");--> statement-breakpoint
CREATE INDEX "pages_user_domain" ON "pages" USING btree ("user_id","domain_id");