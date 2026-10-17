-- Shared-backend bootstrap security: legacy server-owned tables must not
-- inherit unrestricted Data API access from Supabase's default table grants.
-- Existing owner policies remain intact. Tables without a policy deny client
-- access; trusted backend connections retain their existing access.
-- No business row, Vault format, policy, grant, or quota is rewritten.

ALTER TABLE public.activities ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.api_logs ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.change_log ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.chat_threads ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.embed_cache ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.inbox_items ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.ingest_sources ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.prompt_log ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.schema_cluster_log ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.sync_state ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.task_suggestions ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.tree_nodes ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.trees ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE public.user_settings ENABLE ROW LEVEL SECURITY;--> statement-breakpoint

-- This trigger is invoked by Auth inserts, never as a client RPC. Revoking
-- direct EXECUTE does not change trigger invocation or its profile insert.
REVOKE ALL ON FUNCTION public.handle_new_auth_user() FROM PUBLIC, anon, authenticated;--> statement-breakpoint
