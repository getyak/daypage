# Runbook: Sentry → Linear Error Pipeline

This runbook documents how to configure and verify the end-to-end pipeline that automatically creates Linear issues from Sentry error events.

---

## Section 1: Prerequisites

### Required Accounts

| Account | Purpose |
|---|---|
| [Sentry](https://sentry.io) | Error monitoring — DayPage iOS project must exist |
| [Linear](https://linear.app) | Issue tracker — DayPage workspace and team must exist |
| [GitHub](https://github.com) | Hosts the relay workflow (`.github/workflows/sentry-to-linear.yml`) |

### Required Secrets

| Secret | Description | Where to Obtain |
|---|---|---|
| `SENTRY_DSN` | Sentry project DSN for iOS SDK initialization | Sentry → Project Settings → SDK Setup → DSN |
| `LINEAR_API_KEY` | Linear personal API key for GraphQL mutations | Linear → Settings → API → Personal API Keys → Create key |
| `LINEAR_TEAM_ID` | Linear team identifier (UUID) for issue creation | Linear → Settings → Team → copy the ID from the URL or API |
| `SENTRY_WEBHOOK_SECRET` | Secret token to verify incoming Sentry webhook requests | Generate a random string, e.g. `openssl rand -hex 32`; save it here and enter it in Sentry Webhook config |

> **Note:** `LINEAR_TEAM_ID` is a UUID such as `a1b2c3d4-e5f6-7890-abcd-ef1234567890`. You can retrieve it via the Linear GraphQL API:
> ```bash
> curl -s -X POST \
>   -H "Authorization: <LINEAR_API_KEY>" \
>   -H "Content-Type: application/json" \
>   -d '{"query":"{ teams { nodes { id name } } }"}' \
>   https://api.linear.app/graphql | python3 -m json.tool
> ```

---

## Section 2: Sentry Webhook Setup

Sentry does not natively support GitHub `repository_dispatch`. The integration uses Sentry's generic Webhook integration to POST to the GitHub API.

### Steps

1. **Navigate** to your Sentry project → **Settings** → **Integrations** → **Webhooks** → **Add to Project**.

2. **Set the Webhook URL** to the GitHub repository dispatch endpoint:
   ```
   https://api.github.com/repos/{owner}/{repo}/dispatches
   ```
   Replace `{owner}` and `{repo}` with your GitHub org/user and repository name (e.g. `getyak/daypage`).

3. **Add a request header** for authentication:
   - Header name: `Authorization`
   - Header value: `token <GITHUB_PAT>`
   
   The GitHub PAT must have **`repo`** scope (or `public_repo` for public repos) so it can trigger `repository_dispatch` events.

4. **Configure the payload** — Sentry sends a JSON body. The GitHub dispatch endpoint requires:
   ```json
   {
     "event_type": "sentry_issue",
     "client_payload": {
       "issue_id": "{{ issue.id }}",
       "title": "{{ issue.title }}",
       "culprit": "{{ issue.culprit }}",
       "url": "{{ issue.url }}",
       "count": "{{ issue.count }}",
       "userCount": "{{ issue.userCount }}",
       "environment": "{{ issue.environment }}",
       "fingerprint": "{{ issue.fingerprint }}"
     }
   }
   ```
   Enter this as the **Custom Payload** in the Sentry Webhook configuration.

5. **Configure triggers** — enable **New Issue** only (to avoid duplicate events for regressions or re-opened issues).

6. **Save** the webhook configuration.

---

## Section 3: GitHub Secrets Setup

All secrets must be set as **Repository Secrets** (not environment secrets) so the workflow can access them.

**Path:** GitHub repository → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**

| Secret Name | Value |
|---|---|
| `LINEAR_API_KEY` | Linear personal API key (see Section 1) |
| `LINEAR_TEAM_ID` | Linear team UUID (see Section 1) |
| `SENTRY_WEBHOOK_SECRET` | Random secret token (see Section 1) |

> The `SENTRY_DSN` is stored in the app's `.env` file (local) and in CI secrets for TestFlight builds — it does not need to be a GitHub Actions secret for the Linear relay workflow.

---

## Section 4: Testing the Pipeline

Use `curl` to manually trigger a `repository_dispatch` event without waiting for a real Sentry error:

```bash
curl -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: token <GITHUB_PAT>" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/{owner}/{repo}/dispatches \
  -d '{
    "event_type": "sentry_issue",
    "client_payload": {
      "issue_id": "TEST-001",
      "title": "TestError: pipeline smoke test",
      "culprit": "DayPage/App/DayPageApp.swift in application(_:didFinishLaunchingWithOptions:)",
      "url": "https://sentry.io/organizations/example/issues/TEST-001/",
      "count": "5",
      "userCount": "3",
      "environment": "production",
      "fingerprint": "test-fingerprint-abc123"
    }
  }'
```

After running the command:
1. Go to GitHub → **Actions** → **Sentry → Linear Issue Sync** to see the workflow run.
2. Inspect each step's logs to confirm dedup check, priority calculation, and issue creation.
3. Check Linear to verify the issue was created with title `[Sentry] TestError: pipeline smoke test`.

To test dedup prevention, run the same `curl` command a second time and confirm the workflow exits at Step 1 without creating a duplicate.

---

## Section 5: Verification Checklist

Operator: complete this checklist after initial setup or after restoring the pipeline.

- [ ] `LINEAR_API_KEY` secret is set in GitHub repository secrets
- [ ] `LINEAR_TEAM_ID` secret is set in GitHub repository secrets
- [ ] `SENTRY_WEBHOOK_SECRET` secret is set in GitHub repository secrets
- [ ] Sentry Webhook is configured with correct GitHub dispatch URL
- [ ] Sentry Webhook `Authorization` header contains a valid GitHub PAT with `repo` scope
- [ ] Sentry Webhook is set to trigger on **New Issue** events only
- [ ] Manual `curl` test triggered the workflow successfully (Section 4)
- [ ] Workflow run completed with all steps green
- [ ] Linear issue was created with correct title, priority, and description
- [ ] Second `curl` test confirmed dedup prevention (no duplicate issue created)
- [ ] iOS app builds successfully with `SENTRY_DSN` configured in `.env`
