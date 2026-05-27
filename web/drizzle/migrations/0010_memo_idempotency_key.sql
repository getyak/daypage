ALTER TABLE "memos" ADD COLUMN "idempotency_key" text;
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "memos_user_idempotency_key" ON "memos" ("user_id","idempotency_key") WHERE idempotency_key IS NOT NULL;