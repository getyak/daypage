# Sentry → GitHub Issue Auto-Creation

How DayPage turns Sentry errors into GitHub issues without paying for
Sentry's Team plan. Everything below runs on the free Developer tier.

> Supersedes `tasks/runbook-sentry-linear.md` (Linear target, now disabled).

## How it works

```
iOS App crashes
   ↓  Sentry SDK
Sentry SaaS receives + groups
   ↓  Alert Rule fires
Sentry Custom Integration (daypage-github-bridge)
   ↓  POST + Bearer PAT
https://api.github.com/repos/getyak/daypage/dispatches
   ↓  repository_dispatch
.github/workflows/sentry-to-github.yml
   ↓  gh issue create  (dedup via fingerprint marker)
[Sentry] <title>  →  appears in Issues tab
```

Three SaaS hops, zero servers to maintain.

## One-time setup

You need to do this once per Sentry org. The workflow is already in the
repo; only the GitHub PAT and the Sentry-side wiring need configuring.

### 1. Create a fine-grained GitHub PAT

GitHub → **Settings → Developer settings → Personal access tokens →
Fine-grained tokens → Generate new token**

| Field | Value |
|---|---|
| Token name | `sentry-daypage-bridge` |
| Expiration | 1 year (set a calendar reminder to rotate) |
| Repository access | Only select repositories → `getyak/daypage` |
| Repository permissions | **Contents: Read**, **Metadata: Read**, **Actions: Read and write** |

`Actions: write` is required for `repository_dispatch`. No other permission
is needed — the workflow itself uses the built-in `GITHUB_TOKEN` to create
issues, so the PAT only fires the dispatch.

**Copy the token now**; GitHub won't show it again.

### 2. Create the Sentry Custom Integration

Sentry → **Settings → Developer Settings → Custom Integrations → New
Internal Integration**

| Field | Value |
|---|---|
| Name | `daypage-github-bridge` |
| Webhook URL | `https://api.github.com/repos/getyak/daypage/dispatches` |
| Alerts | ✅ enabled |
| Permissions | All `No Access` (this integration only sends outbound webhooks) |

Save. Then under the new integration's settings, add custom headers:

| Header | Value |
|---|---|
| `Authorization` | `Bearer <PAT from step 1>` |
| `Accept` | `application/vnd.github+json` |
| `Content-Type` | `application/json` |

### 3. Create the Alert Rule

Sentry → **Alerts → Create Alert → Issue Alert**

- **When**: `A new issue is created`
- **If**: `The event's level is equal to or higher than error`
- **Then**: `Send a notification via daypage-github-bridge`

Save the rule.

### 4. Verify end-to-end

From your laptop, manually fire a dispatch — this skips Sentry and tests
just the workflow:

```bash
gh api repos/getyak/daypage/dispatches \
  -f event_type=sentry_issue \
  -f client_payload[fingerprint]=local-test-001 \
  -f client_payload[title]="Test from local verification" \
  -f client_payload[culprit]="DayPage/App/DayPageApp.swift" \
  -f client_payload[url]=https://sentry.io/example \
  -f client_payload[count]=1 \
  -f client_payload[userCount]=1 \
  -f client_payload[environment]=debug \
  -f client_payload[issue_id]=TEST-0
```

Within ~30s an issue titled `[Sentry] Test from local verification` should
appear in `getyak/daypage` issues. Re-run the same command — the second
invocation should log `Open issue already exists ... skipping` and not
create a duplicate.

Then trigger a real crash from the iOS app (Debug build, force a
`fatalError("sentry test")` somewhere) and confirm an issue appears via
the full Sentry → Custom Integration → workflow path.

## Webhook payload contract

The Sentry Custom Integration must POST a JSON body shaped like:

```json
{
  "event_type": "sentry_issue",
  "client_payload": {
    "fingerprint": "<sentry issue shortId — used for dedup>",
    "title":       "<human-readable error message>",
    "culprit":     "<file:line or function name>",
    "url":         "<sentry deep link>",
    "count":       "<occurrence count>",
    "userCount":   "<unique users affected — drives severity label>",
    "environment": "<debug | release | testflight>",
    "issue_id":    "<sentry numeric issue id>"
  }
}
```

Sentry exposes these via template variables (`{{ issue.shortId }}` etc.)
in the Alert Rule's request-body editor. Missing fields fall back to
`"unknown"` in the workflow rather than aborting.

## Dedup behaviour

Each created issue body contains:

```html
<!-- sentry-fingerprint: <id> -->
```

Step 2 of the workflow searches `in:body "sentry-fingerprint: <id>"`
against **open** issues only. Two consequences:

- **Recurring crash, ticket still open** → no duplicate created
- **Same crash regresses after close** → fresh ticket; this is intentional
  (a regression is itself signal worth surfacing)

## Severity labels

`userCount`-based, mirroring the previous Linear pipeline:

| userCount | Label |
|---|---|
| ≥ 10 | `severity:urgent` |
| ≥ 3  | `severity:high` |
| else | `severity:medium` |

The workflow assumes these labels exist on the repo. Create them once via:

```bash
gh label create severity:urgent --color B60205 --description "10+ users affected"
gh label create severity:high   --color D93F0B --description "3-9 users affected"
gh label create severity:medium --color FBCA04 --description "1-2 users affected"
gh label create sentry          --color 6E5494
gh label create auto            --color CCCCCC --description "Created by automation"
```

## Disabled: Linear pipeline

`.github/workflows/sentry-to-linear.yml.disabled` is the previous Linear
target, kept for reference. Re-enable by removing the `.disabled` suffix
and configuring `LINEAR_API_KEY` + `LINEAR_TEAM_ID` repo secrets.
