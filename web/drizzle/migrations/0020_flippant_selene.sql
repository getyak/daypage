CREATE TYPE "public"."tree_node_kind" AS ENUM('goal', 'branch', 'leaf');--> statement-breakpoint
CREATE TYPE "public"."tree_node_status" AS ENUM('growing', 'mature', 'merged', 'pruned');--> statement-breakpoint
CREATE TYPE "public"."tree_status" AS ENUM('active', 'archived');--> statement-breakpoint
ALTER TYPE "public"."inbox_item_kind" ADD VALUE 'gap';--> statement-breakpoint
CREATE TABLE "agents" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"name" text NOT NULL,
	"persona_prompt" text NOT NULL,
	"model" text DEFAULT 'gpt-4o-mini' NOT NULL,
	"domain_id" uuid,
	"top_k" integer DEFAULT 8 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "tree_nodes" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"tree_id" uuid NOT NULL,
	"parent_id" uuid,
	"kind" "tree_node_kind" NOT NULL,
	"status" "tree_node_status" DEFAULT 'growing' NOT NULL,
	"title" text NOT NULL,
	"heat" real DEFAULT 0 NOT NULL,
	"evidence_memo_ids" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"page_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "trees" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"title" text NOT NULL,
	"status" "tree_status" DEFAULT 'active' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "chat_threads" ADD COLUMN "agent_id" uuid;--> statement-breakpoint
ALTER TABLE "ingest_sources" ADD COLUMN "default_ingest_mode" "ingest_mode" DEFAULT 'light' NOT NULL;--> statement-breakpoint
ALTER TABLE "page_links" ADD COLUMN "valid_from" timestamp with time zone DEFAULT now() NOT NULL;--> statement-breakpoint
ALTER TABLE "page_links" ADD COLUMN "valid_to" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "agents" ADD CONSTRAINT "agents_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agents" ADD CONSTRAINT "agents_domain_id_domains_id_fk" FOREIGN KEY ("domain_id") REFERENCES "public"."domains"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "tree_nodes" ADD CONSTRAINT "tree_nodes_tree_id_trees_id_fk" FOREIGN KEY ("tree_id") REFERENCES "public"."trees"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "tree_nodes" ADD CONSTRAINT "tree_nodes_parent_id_tree_nodes_id_fk" FOREIGN KEY ("parent_id") REFERENCES "public"."tree_nodes"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "tree_nodes" ADD CONSTRAINT "tree_nodes_page_id_pages_id_fk" FOREIGN KEY ("page_id") REFERENCES "public"."pages"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "trees" ADD CONSTRAINT "trees_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "agents_user" ON "agents" USING btree ("user_id","created_at");--> statement-breakpoint
CREATE INDEX "tree_nodes_tree" ON "tree_nodes" USING btree ("tree_id");--> statement-breakpoint
CREATE INDEX "tree_nodes_tree_parent" ON "tree_nodes" USING btree ("tree_id","parent_id");--> statement-breakpoint
CREATE INDEX "page_links_user_valid" ON "page_links" USING btree ("user_id","valid_from","valid_to");