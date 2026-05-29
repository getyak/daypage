-- US-031: wiki-grounded, configurable AI agents.
-- An agent = name + persona prompt + selected model + optional retrieval scope
-- (a domain). At chat time it grounds answers via the same rag.ts retrievePages
-- used by the MCP server (US-010). Conversations reuse chat_threads /
-- chat_messages, tagged with the new chat_threads.agent_id column.

CREATE TABLE IF NOT EXISTS "agents" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "user_id" uuid NOT NULL REFERENCES "users"("id") ON DELETE CASCADE,
  "name" text NOT NULL,
  "persona_prompt" text NOT NULL,
  "model" text NOT NULL DEFAULT 'gpt-4o-mini',
  "domain_id" uuid REFERENCES "domains"("id") ON DELETE SET NULL,
  "top_k" integer NOT NULL DEFAULT 8,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS "agents_user" ON "agents" ("user_id", "created_at");

-- Tag chat threads with the agent they belong to (NULL = default wiki chat).
ALTER TABLE "chat_threads"
  ADD COLUMN IF NOT EXISTS "agent_id" uuid REFERENCES "agents"("id") ON DELETE SET NULL;
