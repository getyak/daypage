# ADR-0013: Privacy-safe operational diagnostics

- Status: Accepted
- Date: 2026-08-25
- Issue: [#878](https://github.com/getyak/daypage/issues/878)

## Context

DayPage is local-first and handles sensitive journal content. TestFlight builds
previously had no usable remote client diagnostics because the Sentry ingestion
DSN was treated as a privileged secret and omitted from the binary. Login and
sync failures were either written only to a device-local log or added as Sentry
breadcrumbs, which do not create a remotely searchable event on their own.

Support needs enough evidence to distinguish configuration, authentication,
network, authorization, server, and persistence failures without turning memo
content or identity into telemetry.

## Decision

1. The Supabase publishable/legacy anon key and Sentry ingestion DSN are public
   client configuration and are embedded by the release generator. Supabase
   service-role keys, Sentry management tokens, GitHub tokens, and provider API
   secrets remain forbidden in binaries.
2. `DayPageStorage` owns a narrow `OperationalEvent` contract. Its area, stage,
   code, and provider fields are allow-listed; callers cannot attach arbitrary
   strings, memo bodies, response bodies, email, tokens, screenshots, audio, or
   coordinates.
3. Authentication and sync failures receive a random per-attempt correlation ID.
   Sentry events include only the stable code, stage, provider, HTTP status,
   network state, pending count, and consecutive-failure count when applicable.
4. Sync health is persisted as metadata in UserDefaults, outside the Vault. It
   records the last attempt, success, failure, stable code, status, pending count,
   and correlation ID. Repeated identical sync failures are remotely reported at
   most once per 15-minute window; the local snapshot continues updating.
5. Settings exposes a user-visible diagnostic summary and copy action. The
   summary follows the same allow-list boundary and contains no journal content
   or account address.

## Consequences

- TestFlight failures become searchable in Sentry and correlatable with a short
  reference supplied by the user.
- Supabase server logs still require time/reference correlation; request-header
  propagation for SDK-owned Auth calls remains future work.
- Expected OTP mistakes and offline attempts can create warning events. They are
  structured and content-free; volume and sampling should be monitored after the
  first dogfood release.
- The device-local `app.log` remains available for on-device evidence but is not
  uploaded automatically.

## Rollback

Set `SENTRY_DSN` empty in a non-release local build to restore the no-op adapter,
or revert the event call sites while retaining the local diagnostic snapshot.
Release validation intentionally fails TestFlight/App Store archives without a
valid DSN so production observability cannot disappear silently again.

## Amendment (2026-10-13): epoch start floor for deferred raw-crash admission

The pinned Sentry 8.58.4 chain can convert a queued raw crash (captured under
an earlier consent epoch) inside a NEW epoch's Hub after revoke → regrant,
preserving the original crash timestamp. This is a source-proven race, not an
observed production upload. Incrementally added, without changing the existing
lifecycle/transport decisions above:

- `DiagnosticsConsent` persists an immutable `(epoch UUID, startedAt floor)`
  pair inside the existing serialized transition. Repeated grants and
  relaunches reuse the pair; revocation removes both; legacy or malformed
  pairs rotate conservatively. Cache isolation remains keyed by the UUID.
- The real `options.beforeSend` is constructed by `SentryLive.makeBeforeSend`
  (a testable production seam) and runs `DiagnosticsEventGate.admit` BEFORE the
  unchanged field scrubber: live consent, epoch match, and a non-nil finite
  event timestamp at or after the persistent floor (no pre-floor grace window,
  since the SDK truncates crash times to seconds).
- The floor is the persistent epoch creation time — never the SDK start time —
  so prior-launch crashes under continuous consent remain eligible.
- MainActor lifecycle, SDK start/close outside consent locks, fixed endpoint,
  no redirects, cache-epoch isolation, the transport gate, and the envelope
  allowlist are unchanged. No SDK cache or event data is read or deleted.
