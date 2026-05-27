# DayPage Claude Code Hook

The `scripts/claude-code-hook.sh` script lets Claude Code interact with your DayPage instance — adding memos, searching your knowledge base, and reading today's summary — directly from AI-assisted workflows.

## Installation

### 1. Make the script executable

```bash
chmod +x /path/to/daypage/scripts/claude-code-hook.sh
```

### 2. Add to PATH (choose one)

**Option A — symlink to a directory already in PATH:**
```bash
ln -s /path/to/daypage/scripts/claude-code-hook.sh /usr/local/bin/daypage-hook
```

**Option B — add the scripts directory to PATH in your shell profile:**
```bash
# ~/.zshrc or ~/.bashrc
export PATH="$PATH:/path/to/daypage/scripts"
```

### 3. Set the API key

Create an API key in DayPage Settings → API Keys, then export it:

```bash
# ~/.zshrc or ~/.bashrc
export DAYPAGE_API_KEY="dp_live_xxxxxxxxxxxxxxxx"
```

Optionally set a custom server URL (defaults to `http://localhost:3000`):

```bash
export DAYPAGE_URL="https://your-daypage-instance.com"
```

## Usage

```
claude-code-hook.sh <action> [args]
```

### `add-memo <content>`

Creates a new memo in DayPage via `/api/ingest`.

```bash
claude-code-hook.sh add-memo "Realized the auth bug is caused by stale JWT cache"
# Output:
# Memo created: 3f7a1c2d-...
# Content: Realized the auth bug is caused by stale JWT cache
```

### `search <query>`

Searches memos and pages matching the query. Returns up to 5 results from each.

```bash
claude-code-hook.sh search "authentication JWT"
# Output:
# === Search results for: authentication JWT ===
#
# --- Pages ---
#   [concept] JWT Authentication (slug: jwt-authentication)
#
# --- Memos ---
#   [2026-05-27] Found that JWT tokens are cached for 10 minutes...
```

### `get-today`

Returns today's compiled daily page (if available) plus a summary of today's memos.

```bash
claude-code-hook.sh get-today
# Output:
# === DayPage: 2026-05-27 ===
#
# --- Compiled Daily Page ---
# Title: Daily — 2026-05-27
# Status: live
# Sources: 12 memos
# Last compiled: 2026-05-27T02:03:11.000Z
#
# --- Recent memos (today) ---
#   Total memos today: 12
#   [2026-05-27 09:15:00] Fixed the auth middleware bug...
```

## Claude Code Configuration

To allow Claude Code to use this script as a tool, add it to your `.claude/settings.json`:

```json
{
  "allowedTools": [
    {
      "type": "bash",
      "pattern": "claude-code-hook.sh *"
    }
  ]
}
```

Or if you use the project-level settings at `<project>/.claude/settings.json`:

```json
{
  "allowedTools": [
    "Bash(claude-code-hook.sh add-memo *)",
    "Bash(claude-code-hook.sh search *)",
    "Bash(claude-code-hook.sh get-today)"
  ]
}
```

You can also add a CLAUDE.md entry to tell Claude when to use the hook:

```markdown
## DayPage Hook
When I ask you to save a note, insight, or finding to DayPage, run:
`claude-code-hook.sh add-memo "<content>"`

To search my knowledge base: `claude-code-hook.sh search "<query>"`
To check today's activity: `claude-code-hook.sh get-today`
```

## Troubleshooting

### `DAYPAGE_API_KEY environment variable is not set`

Export `DAYPAGE_API_KEY` in your shell profile and reload it:
```bash
source ~/.zshrc
```

### `Error: HTTP 401`

Your API key is invalid or expired. Generate a new one in DayPage Settings → API Keys.

### `Error: HTTP 404` or connection refused

Check that `DAYPAGE_URL` points to a running DayPage instance:
```bash
curl -s "$DAYPAGE_URL/api/memos" -H "Authorization: Bearer $DAYPAGE_API_KEY"
```

### `python3: command not found`

The script uses `python3` for JSON formatting. Install Python 3:
- macOS: `brew install python3`
- Ubuntu/Debian: `sudo apt install python3`

If Python is unavailable, the script falls back to raw JSON output for most operations.

### Permissions error

Make sure the script is executable:
```bash
ls -la scripts/claude-code-hook.sh
# Should show: -rwxr-xr-x
```
