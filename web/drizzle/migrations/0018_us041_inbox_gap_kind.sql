-- US-041: structural gap detection in the knowledge graph.
-- Community detection over the page-link graph surfaces clusters of pages the
-- user has written about for weeks but never connected. The LLM then drafts a
-- bridging question across each "should-connect" cluster pair, written to
-- inbox_items so the user can adopt or ignore it. We reuse the inbox surface by
-- adding a new inbox_item_kind value: 'gap'.
ALTER TYPE "public"."inbox_item_kind" ADD VALUE IF NOT EXISTS 'gap';
