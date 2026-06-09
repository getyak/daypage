CREATE TYPE "public"."agent_backend" AS ENUM('claude-code', 'openclaw', 'ralph', 'sandbox');--> statement-breakpoint
CREATE TYPE "public"."agent_session_status" AS ENUM('active', 'idle', 'timed_out', 'closed');--> statement-breakpoint
CREATE TYPE "public"."work_order_gate" AS ENUM('auto', 'approve-first', 'approve-result');--> statement-breakpoint
CREATE TYPE "public"."work_order_status" AS ENUM('pending', 'gated', 'running', 'done', 'failed');--> statement-breakpoint
CREATE TABLE "agent_sessions" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"backend" "agent_backend" NOT NULL,
	"external_ref" text,
	"project" text,
	"status" "agent_session_status" DEFAULT 'active' NOT NULL,
	"last_heartbeat_at" timestamp with time zone,
	"tokens_used" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "work_orders" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"suggestion_id" uuid,
	"intent" text NOT NULL,
	"context" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"output_spec" text,
	"gate" "work_order_gate" DEFAULT 'approve-first' NOT NULL,
	"callback" jsonb,
	"budget_tokens" integer,
	"status" "work_order_status" DEFAULT 'pending' NOT NULL,
	"result_ref" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "agent_sessions" ADD CONSTRAINT "agent_sessions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "work_orders" ADD CONSTRAINT "work_orders_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "work_orders" ADD CONSTRAINT "work_orders_suggestion_id_task_suggestions_id_fk" FOREIGN KEY ("suggestion_id") REFERENCES "public"."task_suggestions"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "agent_sessions_user_status" ON "agent_sessions" USING btree ("user_id","status");--> statement-breakpoint
CREATE INDEX "work_orders_user_status" ON "work_orders" USING btree ("user_id","status");