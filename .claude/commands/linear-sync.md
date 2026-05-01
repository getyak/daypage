# Linear Integration — Claude Code Command

You have access to the DayPage Linear integration via `scripts/linear/sync.sh`.  
Use these capabilities to keep Linear issues in sync with your development work.

---

## Available Commands

All commands require `LINEAR_API_KEY` in env — it's already available from `.env`.

```bash
# Get issue details
bash scripts/linear/sync.sh status DAY-XX

# Move issue between states
bash scripts/linear/sync.sh move DAY-XX in-progress
bash scripts/linear/sync.sh move DAY-XX in-review
bash scripts/linear/sync.sh move DAY-XX done

# Add a comment (progress updates, findings, decisions)
bash scripts/linear/sync.sh comment DAY-XX "Your markdown comment here"

# Create a new issue
bash scripts/linear/sync.sh create "Title" "Markdown body"

# List team issues
bash scripts/linear/sync.sh list
bash scripts/linear/sync.sh list "status:in-progress"

# Close an issue when work is done
bash scripts/linear/sync.sh close DAY-XX
```

---

## When to Use

### 1. Starting Work on an Issue
```bash
# Read the issue first
bash scripts/linear/sync.sh status DAY-42
# Move to In Progress
bash scripts/linear/sync.sh move DAY-42 in-progress
# Post start comment
bash scripts/linear/sync.sh comment DAY-42 "🚀 Starting implementation. Will follow AGENTS.md conventions."
```

### 2. During Development — Post Progress
```bash
bash scripts/linear/sync.sh comment DAY-42 "✅ Completed:
- Added `LoginView.swift`
- Implemented OAuth2 flow
- Unit tests passing"
```

### 3. When You Hit a Blocker
```bash
bash scripts/linear/sync.sh comment DAY-42 "⛔ Blocked: Waiting for design spec on the signup flow."
```

### 4. Creating Branches from Linear Issues
```bash
bash scripts/linear/branch.sh DAY-42
# or with options:
bash scripts/linear/branch.sh DAY-42 --type fix --base develop
```

### 5. After Completing Work
```bash
# Create PR linked to Linear
bash scripts/linear/sync.sh link-pr DAY-42
# Mark as done (or let PR merge handle it)
bash scripts/linear/sync.sh close DAY-42
```

---

## Workflow Conventions

| Phase | Linear State | Action |
|---|---|---|
| Pick up issue | → In Progress | `move DAY-XX in-progress` |
| PR opened | Auto (GitHub Actions) | PR→Linear workflow syncs |
| PR in review | → In Review | `move DAY-XX in-review` |
| PR merged | Auto → Done | Linear automation handles |
| PR closed (not merged) | Auto → Canceled | Linear automation handles |

---

## Design Decision Recording

When making significant architectural/design decisions, **always post them as Linear comments** so they're preserved:

```bash
bash scripts/linear/sync.sh comment DAY-42 "## Design Decision: Core Data vs File Storage

**Decision:** Use file-based storage with YAML front-matter
**Rationale:** Simpler for text-heavy journaling, no migration overhead
**Alternatives considered:** Core Data, SwiftData, SQLite
"
```

---

## Safety

- Never post sensitive information (API keys, tokens, passwords) to Linear comments
- Never post full source code — summarize changes instead
- The `comment` command auto-escapes JSON, but keep comments concise
