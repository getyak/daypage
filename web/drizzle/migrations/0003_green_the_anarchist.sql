CREATE TABLE "embed_cache" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"body_hash" text NOT NULL,
	"embedding" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "embed_cache_body_hash_unique" UNIQUE("body_hash")
);
--> statement-breakpoint
ALTER TABLE "memos" ADD COLUMN "compile_error" text;--> statement-breakpoint
ALTER TABLE "memos" ADD COLUMN "embedding" text;