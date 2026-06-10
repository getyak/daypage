CREATE TYPE "public"."gateway_job_status" AS ENUM('queued', 'running', 'gated', 'done', 'failed', 'dead');--> statement-breakpoint
CREATE TABLE "gateway_jobs" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"type" text NOT NULL,
	"tree_id" uuid,
	"payload" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"status" "gateway_job_status" DEFAULT 'queued' NOT NULL,
	"idempotency_key" text NOT NULL,
	"gate_state" text,
	"attempts" integer DEFAULT 0 NOT NULL,
	"last_error" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "gateway_jobs_idempotency_key_unique" UNIQUE("idempotency_key")
);
--> statement-breakpoint
ALTER TABLE "gateway_jobs" ADD CONSTRAINT "gateway_jobs_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "gateway_jobs" ADD CONSTRAINT "gateway_jobs_tree_id_trees_id_fk" FOREIGN KEY ("tree_id") REFERENCES "public"."trees"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "gateway_jobs_user_status" ON "gateway_jobs" USING btree ("user_id","status");