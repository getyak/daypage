CREATE TABLE "schema_cluster_log" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"cluster_signature" text NOT NULL,
	"suggested_name" text,
	"inbox_item_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "inbox_items" ADD COLUMN "snooze_until" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "schema_cluster_log" ADD CONSTRAINT "schema_cluster_log_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "schema_cluster_log" ADD CONSTRAINT "schema_cluster_log_inbox_item_id_inbox_items_id_fk" FOREIGN KEY ("inbox_item_id") REFERENCES "public"."inbox_items"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "schema_cluster_log_user" ON "schema_cluster_log" USING btree ("user_id","created_at");