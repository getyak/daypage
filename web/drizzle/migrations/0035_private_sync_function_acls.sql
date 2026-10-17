-- Fresh Supabase projects explicitly grant function EXECUTE to client roles.
-- REVOKE FROM PUBLIC alone does not remove those independent grants.
-- Preserve the existing API contract and service-role GC; change no bodies.

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM anon, authenticated;--> statement-breakpoint

REVOKE ALL ON FUNCTION public.daypage_length_prefix(text)
  FROM PUBLIC, anon, authenticated;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_attachment_extension(text)
  FROM PUBLIC, anon, authenticated;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_attachment_manifest_hash(jsonb)
  FROM PUBLIC, anon, authenticated;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_bump_memo_change_sequence()
  FROM PUBLIC, anon, authenticated;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_queue_memo_attachment_gc()
  FROM PUBLIC, anon, authenticated;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_enqueue_memo_revision()
  FROM PUBLIC, anon, authenticated;--> statement-breakpoint

REVOKE ALL ON FUNCTION public.daypage_inventory_attachment_orphans()
  FROM PUBLIC, anon, authenticated;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_claim_attachment_gc(integer)
  FROM PUBLIC, anon, authenticated;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_finish_attachment_gc(uuid, text, uuid, boolean, text)
  FROM PUBLIC, anon, authenticated;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_inventory_attachment_orphans()
  TO service_role;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_claim_attachment_gc(integer)
  TO service_role;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_finish_attachment_gc(uuid, text, uuid, boolean, text)
  TO service_role;--> statement-breakpoint

REVOKE ALL ON FUNCTION public.daypage_apply_sync_operations(jsonb)
  FROM PUBLIC, anon;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_apply_sync_operations_v2(jsonb)
  FROM PUBLIC, anon;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_prepare_attachment_upload(uuid, text, bigint, text, text)
  FROM PUBLIC, anon;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_pull_memo_changes(timestamptz, integer)
  FROM PUBLIC, anon;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_pull_sync_changes(bigint, integer)
  FROM PUBLIC, anon;--> statement-breakpoint
REVOKE ALL ON FUNCTION public.daypage_pull_sync_changes_v2(bigint, integer)
  FROM PUBLIC, anon;--> statement-breakpoint

GRANT EXECUTE ON FUNCTION public.daypage_apply_sync_operations(jsonb)
  TO authenticated;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_apply_sync_operations_v2(jsonb)
  TO authenticated;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_prepare_attachment_upload(uuid, text, bigint, text, text)
  TO authenticated;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_pull_memo_changes(timestamptz, integer)
  TO authenticated;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_pull_sync_changes(bigint, integer)
  TO authenticated;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION public.daypage_pull_sync_changes_v2(bigint, integer)
  TO authenticated;--> statement-breakpoint

-- The two PAT-hash-gated MCP entry points intentionally retain anon EXECUTE
-- (ADR-0008). Their bodies enforce their own key and owner authorization.
