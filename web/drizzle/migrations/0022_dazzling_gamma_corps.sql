CREATE TYPE "public"."task_suggestion_status" AS ENUM('open', 'selected', 'dispatched', 'dismissed');--> statement-breakpoint
CREATE TABLE "task_suggestions" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"tree_node_id" uuid,
	"title" text NOT NULL,
	"rationale" text NOT NULL,
	"estimate" text,
	"suggested_target" text,
	"status" "task_suggestion_status" DEFAULT 'open' NOT NULL,
	"payload" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "task_suggestions" ADD CONSTRAINT "task_suggestions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "task_suggestions" ADD CONSTRAINT "task_suggestions_tree_node_id_tree_nodes_id_fk" FOREIGN KEY ("tree_node_id") REFERENCES "public"."tree_nodes"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "task_suggestions_user_status" ON "task_suggestions" USING btree ("user_id","status");