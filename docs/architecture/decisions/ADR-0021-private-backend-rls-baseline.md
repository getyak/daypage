# ADR-0021: Private tables in a fresh shared backend

- Status: Accepted after independent review and staging verification
- Date: 2026-10-16
- Extends: ADR-0008 and ADR-0016; implementation tracked with #884.

## Context

A clean deployment through Drizzle 0032 leaves sixteen legacy tables in the
public schema without row level security. Existing staging had an independent
RLS setup, so testing only that database concealed the fresh-project gap.
Supabase's default table grants can make such tables accessible through its
Data API. Chat data, preferences, runtime logs and derived data require the
same confidentiality as raw memos.

## Decision

Append Drizzle 0034 to enable RLS on the sixteen affected tables. Do not add
generic owner policies: each product capability must define its own access
contract before being exposed. Existing policies and trusted backend queries
remain intact. A table with no policy denies ordinary client access, including
the owner; server endpoints remain responsible for their authenticated owner
predicate. Direct execution of the Auth profile trigger is revoked from client
roles while Auth's trigger-driven profile creation remains available.

Production bootstrap temporarily denies application-schema usage until the
complete migration chain, RLS coverage and RPC privileges are verified. This
deployment hold is an environment operation, recorded separately from Drizzle
history; it is not part of the persisted application format.

A second fresh-project difference is Supabase's explicit default function
grants to `anon` and `authenticated`. Historical `REVOKE FROM PUBLIC` statements
leave these independent grants in place. Append Drizzle 0035 to remove those
defaults for future `postgres`-owned application functions, revoke clients'
access to internal media helpers/triggers and service-only GC, and preserve
authenticated sync RPCs. The two PAT-hash-gated MCP entry points keep their
intentional anonymous execution permission. Function bodies and service-role
GC permissions stay intact.

## Compatibility and verification

No row, raw memo, attachment, settings JSON, quota or existing owner policy is
rewritten. Existing server connections keep their access. A future direct
client settings/catalog API needs a separate owner-scoped contract rather than
disabling RLS. Fixes roll forward; disabling RLS is not a safe rollback.

Run `web/scripts/verify-private-backend-rls.sql` in an isolated staging
transaction, then read back all public tables and Supabase security advisors.
Synthetic owner and anonymous probes must not expose server-owned settings.
Auth signup/profile creation and same-account sync remain separate acceptance
checks; this decision does not claim their completion.
Run `web/scripts/verify-private-sync-function-acls.sql` to check intended RPC,
private-helper, GC and future-function grants independently of schema holds.
