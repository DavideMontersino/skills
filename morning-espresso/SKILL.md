---
name: morning-espresso
description: Daily morning context builder — AWS login, PR dashboard, Jira scan, git context, goal tracking, worktree cleanup, and daily log to Obsidian vault.
user-invocable: true
---

# Morning Espresso

Start each workday with full context. This skill checks credentials, gathers status across all repos and projects, measures goal progress, cleans up stale worktrees, logs everything to an Obsidian vault, and recommends what to do first.

## Prerequisites

- AWS CLI configured with SSO profiles
- `gh` CLI authenticated
- `aws-morning-login` at `~/.local/bin/aws-morning-login`
- Obsidian vault at `~/dmon-coding/stx-vault/` (with `goals/`, `daily/`, `monthly/`, `templates/`)
- Quarterly goals defined in `~/dmon-coding/stx-vault/goals/` (current quarter file)

## Repos

The user works across multiple repos under `~/coding/`. Each repo uses a worktree layout: `~/coding/<repo>/main/` is the main worktree.

Known repos (check which actually exist on disk):
- `core-services` (Jira: DCS)
- `rng-operations-portal` (Jira: BG)
- `pre-trade-services` (Jira: PR)
- `evolve-platform`
- `evolve-hubspot-sync`
- `legacy-integration`
- `serverless-foundation`
- `core-backend-libs`

## Phase 1 — AWS Credentials

Run `~/.local/bin/aws-morning-login`.

**CRITICAL**: If it fails or prompts for browser auth, STOP and tell the user to complete SSO login manually. Never run `aws sso login` or any auth command without explicit user approval.

Report the status table to the user.

## Phase 1.5 — What Are You Working On?

Before diving into data, ask the user what they're working on today. Their current focus might not be visible in git, Jira, or PRs yet.

Ask: "What are you working on today? Anything not yet visible in git/Jira?"

Incorporate their answer into the Recommended Actions and standup draft.

## Phase 2 — PR Dashboard

For each repo that exists under `~/coding/*/main/`:

```bash
gh pr list --author @me --state open --json number,title,isDraft,createdAt,headRefName,reviewDecision,statusCheckRollup -R "$(gh repo view --json nameWithOwner -q .nameWithOwner)"
```

For each open PR, also check:
```bash
gh pr checks <number>
```

Present a summary table with columns: Repo, PR#, Title, Status (draft/ready), CI (pass/fail/pending), Reviews (approved/changes requested/pending), Age.

Flag items needing attention:
- CI failing (fix first)
- Reviews with changes requested
- Stale PRs (>3 days no activity)
- Unresolved review comments

## Phase 3 — Jira Scan

Use Atlassian MCP tools to query Jira. The Atlassian site is `stxgroup.atlassian.net`.

Query 1 — My sprint items:
```
project IN (DCS, PR, BG) AND sprint in openSprints() AND assignee = currentUser() ORDER BY status ASC, priority DESC
```

Query 2 — Recently updated (by anyone, assigned to me):
```
project IN (DCS, PR, BG) AND assignee = currentUser() AND updated >= -1d ORDER BY updated DESC
```

Present sprint items grouped by status: To Do, In Progress, In Review, Done.
Highlight any items updated by others (someone may be waiting on me).

## Phase 4 — Yesterday's Context

For each repo under `~/coding/*/main/`:

```bash
git log --author="Davide" --since="yesterday 00:00" --until="today 00:00" --oneline --all
```

Also check all worktrees for uncommitted work:
```bash
git worktree list
# For each worktree path:
git -C <worktree-path> status --porcelain
```

Summarize: what repos were touched, what was committed, what has uncommitted work.

## Phase 4.5 — Session Summaries

Session summary files are the richest source of "what happened yesterday" — they capture decisions, context, blockers, and outcomes in human-readable form, not just commit hashes.

1. Determine yesterday's date (and the last 2-3 days, to catch unprocessed weekend/missed files):
```bash
ls ~/dmon-coding/stx-vault/daily/{yesterday}-session-*.md 2>/dev/null
# Also check 2-3 days back for any unprocessed session files
ls ~/dmon-coding/stx-vault/daily/{day-before-yesterday}-session-*.md 2>/dev/null
```

2. Read each session file found. Extract:
   - What was worked on (the main narrative)
   - Decisions made and why
   - Blockers encountered
   - What was shipped vs. still in progress
   - Any follow-up items mentioned

3. Build a structured "session context" from these files. This becomes the **primary source** for the "Done" section of today's standup (Phase 6).

4. Git log and PR data from Phase 4 act as **supplementary sources** — they catch anything the user forgot to wrap up in a session summary (e.g., a quick commit after the last session ended).

**If no session summary files exist for yesterday (or recent days):** skip this phase entirely and fall back to git log + PR data from Phase 4 as the sole source for the "Done" section. No warnings needed — the user may not always wrap up sessions.

## Phase 5.5 — Untracked Work Detection

Cross-reference work artifacts from earlier phases against Jira sprint items to find work that has no ticket.

### Data sources (already collected)

- Phase 3 (Jira scan): all sprint item keys
- Phase 4 (git log): branch names, commit messages, PRs
- Phase 4.5 (sessions): ticket keys mentioned in session summaries

### Algorithm

1. Build `jira_sprint_tickets` set from Phase 3 results
2. Build `work_refs` set by extracting ticket keys (regex `(DCS|PR|BG)-\d+`) from: branch names, conventional-commit scopes, commit message bodies, PR titles/descriptions, session summaries
3. Identify gaps:
   - Branches/PRs with NO ticket key anywhere in their name or commits
   - Session narratives describing work with no Jira reference
   - Ticket refs found in git but NOT in the current sprint (softer signal — ticket exists but isn't in sprint)
4. Group by work-stream, de-duplicate

### Presentation

Show a table:

```
| # | Source | Description | Status |
|---|--------|-------------|--------|
| 1 | Branch `feat-ci-reporting` (3 commits) | CI test reporting | No ticket |
| 2 | Session "data-consistency" | CodeArtifact publish fixes | Refs DCS-279 but broader |
```

For each item, offer:
- **Create ticket** via Atlassian MCP (`createJiraIssue` with `contentFormat: "markdown"`, cloudId: `ea285670-c5fb-45dd-9f85-6292c8dc4fed`, site: `stxgroup.atlassian.net`)
- **Link to existing** (search sprint for matching keywords)
- **Skip**

Auto-populate fields: summary from branch/session name, description from commits/PRs, project from repo mapping (core-services→DCS, rng-operations-portal→BG, pre-trade-services→PR), add to current sprint.

**Wait for user approval before any creates** (same pattern as Phase 9).

After creating tickets, run the Formatting QA sub-procedure (Appendix T).

## Phase 5 — Goal Progress

Read the current quarter's goals file from `~/dmon-coding/stx-vault/goals/`. Determine the current quarter (Q1=Jan-Mar, Q2=Apr-Jun, Q3=Jul-Sep, Q4=Oct-Dec).

For each goal and its key results:
- Cross-reference with PRs merged recently, Jira tickets completed, git activity
- Assess movement: advancing / stalling / blocked
- Note which daily activities align with which goals

This doesn't need to be precise — directional signals are fine. The point is to keep goals visible and connected to daily work.

## Phase 6 — Synthesize & Log

### Conversation Output

Before writing the log, discuss with the user in conversation:
- **PR Dashboard** — present the full table from Phase 2 (repo, PR#, title, status, CI, reviews, age)
- **Jira Sprint** — present sprint items grouped by status from Phase 3
- **AWS Status** — report the credential status table from Phase 1
- **Recommended Actions** — propose a prioritized list of what to do today, weighted by:
  1. Failing CI — fix first, it blocks everything
  2. Stale PRs — unblock reviews/merges
  3. Sprint commitments — Jira items in current sprint
  4. Goal alignment — prefer work that advances quarterly goals over reactive tasks
- Incorporate the user's answer from Phase 1.5 into the priorities discussion

All of the above is **conversational only** — it is NOT written to the daily log.

### Daily Log Writing Rules

- **Crosslink everything**: Jira tickets as `[KEY](https://stxgroup.atlassian.net/browse/KEY)` (the Jira site `stxgroup.atlassian.net` is correct). PR links must be derived dynamically from `gh repo view --json nameWithOwner -q .nameWithOwner` — never hardcode the GitHub org. Format as `[repo #N](https://github.com/<nameWithOwner>/pull/N)`. The org is currently `stxcommodities` (NOT `stxgroup`), but always derive it rather than hardcoding. Every ticket and PR mentioned in the log MUST be a clickable link.
- **ELI5 each item**: write so that a teammate (or the author in a month) can understand what happened without extra context. Not just "CDK fixes" — say what was fixed and why.
- **Correct timeline**: use CET timezone. "Yesterday" is literal. Don't attribute last week's work to yesterday. Add parenthetical dates for older items (e.g., "(Tuesday)", "(last week)").
- **Goal progress should be actionable**: don't just say "no movement". Suggest a concrete next step, especially for goals like tech talks — recommend a specific topic based on recent work.
- **No data dumps**: PR dashboard tables, Jira sprint lists, and AWS status belong in the conversation, not the log. The log is a curated summary.

### Write Daily Log

Write the daily log to `~/dmon-coding/stx-vault/daily/YYYY-MM-DD.md` using the template structure from `~/dmon-coding/stx-vault/templates/daily.md`.

Use Obsidian wikilinks to link to the previous day's log. Add relevant goal tags.

If today's log already exists (re-running the skill), update it rather than overwriting — append new information.

**The daily log must be short and scannable.** It has two sections:

#### Standup (primary section)

**Building the "Done" section:** Session summaries from Phase 4.5 are the **preferred source** for "Done" items. They capture the human-readable narrative of what happened — decisions, context, and outcomes — which makes for much better standup entries than raw commit messages. Git log and PR data from Phase 4 supplement session summaries by catching stray commits or PR activity that happened outside a tracked session. If no session summaries exist, fall back entirely to git log + PR data.

```markdown
## Standup

### Done
<!-- Group by PR/Jira ticket. Each item = ticket key + title + what was done -->
<!-- Prefer session summary narratives over raw git log when both exist -->
- **DCS-123** Title — merged PR #456, closed ticket
- **BG-78** Title — pushed fixes, CI green, awaiting review

### Today
<!-- Distilled TODO list — the result of the priorities discussion above -->
- Fix failing CI on core-services PR #789
- Review and merge DCS-200
- Start DCS-300 (sprint commitment)

### Blocked
<!-- Only if something is actually blocked. Omit section if nothing blocked -->
- DCS-150 — waiting on API team for schema changes
```

The "Today" section is where recommended actions land after discussion with the user — prioritized, actionable, no separate "Recommended Actions" section in the log. Include any newly-created tickets from Phase 5.5 in the "Today" items.

#### Goal Progress (compact)

A small section tracking quarterly goal movement. Keep it to 1-2 lines per goal, directional only:

```markdown
## Goal Progress
- **Goal A** — advancing (shipped X, Y)
- **Goal B** — stalling (no activity this week)
```

#### Worktree Cleanup appendix (conditional)

If worktree cleanup was performed (Phase 7), append an "Appendix: Worktree Cleanup" section listing **only actually removed worktrees** (with branch name and PR number/state). Flagged-but-not-removed worktrees are conversational only — do not write them to the log.

**Do NOT include** in the daily log: AWS status, PR dashboard tables, Jira sprint details, or full recommended actions lists. Those belong in the conversation, not the file.

Commit the daily log:
```bash
cd ~/dmon-coding/stx-vault && git add daily/ && git commit -m "daily: YYYY-MM-DD"
```

## Phase 7 — Worktree Cleanup

For each repo under `~/coding/*/`:
1. List all worktrees: `git -C ~/coding/<repo>/main worktree list`
2. For each non-main worktree:
   - Get the branch name
   - Check if the associated PR is closed/merged: `gh pr list --head <branch> --state all --json state`
   - Check for uncommitted changes: `git -C <worktree-path> status --porcelain`
3. Also find orphan branches matching `worktree-agent-*`: `git -C ~/coding/<repo>/main branch --list 'worktree-agent-*'`

Present a cleanup proposal:
- Worktrees with **merged/closed** PRs and NO dirty changes → propose removal
- Worktrees with merged/closed PRs but dirty changes → flag but do NOT propose removal
- Orphan `worktree-agent-*` branches → investigate what they contain, present a brief summary
- **Abandoned worktrees** (no PR found) → flag for awareness but do NOT propose removal. Only remove if the user explicitly asks.

**Wait for user approval before removing anything.** Then:
```bash
git -C ~/coding/<repo>/main worktree remove <path>
git -C ~/coding/<repo>/main branch -D <branch>
```

## Phase 8 — Monthly Summary (conditional)

Check: is this the first run of a new month? Look at `~/dmon-coding/stx-vault/monthly/` for the previous month's summary.

If today is in a new month AND no summary exists for the previous month:

1. Read all daily logs from the previous month (`~/dmon-coding/stx-vault/daily/YYYY-MM-*.md`)
2. Read the quarterly goals
3. Generate `~/dmon-coding/stx-vault/monthly/YYYY-MM.md` with:
   - **Summary**: 2-3 sentence overview of the month
   - **Key Accomplishments**: major items shipped, bugs fixed, incidents resolved
   - **PRs Merged**: list with repo, number, title
   - **Tickets Closed**: list from Jira
   - **Goal Progress**: for each quarterly goal, what changed this month (delta)
   - **Reactive vs Planned**: estimate what % of work was planned (sprint items) vs reactive (incidents, bugs, urgent requests)
   - **Blockers & Challenges**: recurring themes
   - **Highlights for Review**: 3-5 bullet points ready to paste into a performance review

Use the template from `~/dmon-coding/stx-vault/templates/monthly.md`.

Commit the monthly summary:
```bash
cd ~/dmon-coding/stx-vault && git add monthly/ && git commit -m "monthly: YYYY-MM"
```

## Phase 9 — Jira Housekeeping

Cross-reference:
- PRs that were merged (from Phase 2 history or git log)
- Jira tickets still in "In Progress" or "In Review" status

If a ticket's PR is merged but the ticket isn't Done, propose transitioning it.

**Present the list and wait for approval.** Use Atlassian MCP `transitionJiraIssue` to apply approved transitions.

After each Jira write operation (transitions, comments with descriptions), run the Formatting QA sub-procedure (Appendix T).

## Output Style

- Be concise but complete
- Use tables for dashboards
- Use bullet lists for action items
- Bold the most important items
- The daily log file should be well-formatted Obsidian markdown
- Show the standup draft in a copyable code block so the user can paste it into Slack

## Important Rules

- NEVER run auth commands without user approval
- NEVER auto-apply Jira transitions — always propose and wait
- NEVER delete worktrees without approval
- If the vault or goals files don't exist, warn the user and skip dependent phases
- If a repo doesn't exist on disk, skip it silently
- Run repo checks in parallel where possible for speed
- **Vault Commits** — every time you write or modify a file in the vault (`~/dmon-coding/stx-vault/`), immediately commit it:
  ```bash
  cd ~/dmon-coding/stx-vault && git add -A && git commit -m "<type>: <description>"
  ```
  Commit types:
  - `daily: YYYY-MM-DD` — for daily logs
  - `monthly: YYYY-MM` — for monthly summaries
  - `goals: <brief description>` — for goal changes
  - `chore: <description>` — for template/config changes

  This keeps a full history of goal evolution and daily progress.

## Appendix T: Jira Formatting QA (temporary — remove after 2026-05-31)

Called from Phase 5.5 (after ticket creation) and Phase 9 (after Jira writes that include descriptions or comments).

### Steps

1. After any Jira write (`createJiraIssue`, `editJiraIssue` with description change, `addCommentToJiraIssue`), capture the issue key and what was written
2. Run `playwright-cli goto https://stxgroup.atlassian.net/browse/{KEY}` to navigate to the ticket
3. Run `playwright-cli screenshot` to capture the rendered page
4. Visually inspect the screenshot. Compare intended Markdown vs actual rendering. Look for:
   - Raw `##`/`**`/backticks showing as literal text instead of rendered formatting
   - Broken lists (dashes/numbers not rendering as list items)
   - Broken links (raw Markdown links instead of clickable hyperlinks)
   - Broken code blocks
   - ADF artifacts (JSON-like content visible)
   - Unexpected or missing line breaks
5. If formatting is correct: log success and move on
6. If formatting is broken:
   a. Identify the specific Markdown construct that failed
   b. Fix the ticket content via `editJiraIssue` with corrected content
   c. Re-screenshot to verify the fix
   d. Log the issue in `~/dmon-coding/stx-vault/jira-formatting-issues.md` (create if doesn't exist) with date, ticket key, what broke, and what fixed it
   e. Propose an update to `~/coding/core-services/main/.claude/skills/jira/SKILL.md` — add the formatting rule. Wait for user approval before editing.

### Auth handling

If playwright-cli detects a Jira login page instead of the ticket (session expired), tell the user and pause. The user logs in manually in the browser window. Then retry.
