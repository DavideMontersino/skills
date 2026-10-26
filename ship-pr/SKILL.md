---
name: ship-pr
description: Full PR lifecycle — self-review, branch, CI, push, PR, monitor reviews + CI, fix loop until clean.
user-invocable: true
---

# Ship PR

Automates the end-to-end PR workflow: optional self-review, branch creation, local CI, push, PR creation, and iterative monitoring/fixing of CI failures and review comments. PRs open ready-for-review — never as a GitHub draft (Copilot doesn't review drafts).

## Prerequisites

- Changes are ready to ship (code complete)
- On the correct working branch, or on `main` (a branch will be created)

## Phase 0 — Self-Review

### Step 0.1: Check if self-review was already done

If the caller indicates self-review was already completed (e.g., when invoked from `/deliver`), skip to Phase 1.

Otherwise, ask: "Run /self-review before shipping? (recommended)"

### Step 0.2: Run self-review

If proceeding: run `/self-review` to analyze the branch diff against `main`.

After the report: fix approved findings, commit fixes, and re-verify locally before continuing to Phase 1.

## Phase 1 — Prepare

### Step 1.1: Assess State

```bash
git branch --show-current
git status --short
git log --oneline -5
git log --oneline @{upstream}..HEAD 2>/dev/null || echo "No upstream set"
```

Determine: current branch, uncommitted changes, unpushed commits.

### Step 1.2: Branch (if needed)

If on `main`:
1. Ask the user for the Jira ticket number and a short description
2. Propose a branch name: `<type>/<TICKET-KEY>-kebab-case-description`
   Where `<type>` is `feat | fix | refactor | chore | docs | test`
3. **STOP — ask user to confirm the branch name**
4. Create: `git checkout -b <branch-name>`

If already on a feature branch, extract the ticket key from the branch name.

Extract the ticket key from the branch name. Common patterns:
- `feat/DCS-279-description` -> ticket: `DCS-279`
- `fix/DCS-300-description` -> ticket: `DCS-300`
- `chore/PROJ-42-description` -> ticket: `PROJ-42`

Regex: branch name matches `(?:feat|fix|refactor|chore|docs|test|ci)/([A-Z]+-\d+)` -> capture group 1 is the ticket key.

If no ticket found in branch name, ask the user for the ticket key.

### Step 1.3: Commit (if needed)

If there are uncommitted changes (staged, unstaged, or untracked):
1. Stage relevant files
2. Ask the user for the commit type: `feat | fix | refactor | doc | test | chore | ...`
3. Compose message: `<type>(<TICKET-KEY>): <description>`
4. **STOP — ask user to confirm the commit message**
5. Commit

If no uncommitted changes AND no unpushed commits: stop and tell the user there is nothing to ship.

### Step 1.4: Run Local CI

Run `/ci-check`. This runs typecheck, lint, tests, and CDK synthesis.

If CI fails: diagnose, fix the issues, commit the fixes, and re-run `/ci-check`. Do NOT proceed to Phase 2 until CI passes.

## Phase 2 — Ship

### Step 2.1: Push

```bash
bash ~/.claude/skills/ship-pr/push.sh -u origin <branch-name>
```

If push fails (e.g., divergent history), diagnose and ask the user how to proceed.

### Step 2.2: Create PR (or detect existing)

Check for an existing PR:
```bash
gh pr list --head <branch-name> --json number,title,url --limit 1
```

**If PR exists**: report its number and URL, skip to Phase 3.

**If no PR**: compose the title and body.

Title format: `<type>(<TICKET-KEY>): <description>`
- `<type>`: infer from the most impactful commit type on the branch, or ask
- `<TICKET-KEY>`: extracted from the branch name (see Step 1.2)
- `<description>`: derived from commit messages, imperative mood
- **The repo's own title rule wins.** Check `.claude/rules/writing.md` / `CONTRIBUTING.md` and any title-check script (e.g. core-services `npm-scripts/check-pr-title.mjs`) first: core-services wants `type(area): summary` (area, not ticket key), lower case, ≤72 chars. Never add a `[DRAFT]`/`WIP` prefix; the title check fails it.

Open the PR ready-for-review — never `gh pr create --draft` (Copilot doesn't review drafts).

Body format:
```markdown
## Summary
- <bullet points summarizing the changes>

Jira: <TICKET-KEY>
```

**STOP — ask user to confirm the PR title.**

Create:
```bash
bash ~/.claude/skills/ship-pr/create-pr.sh --title "<title>" --body "<body>"
```

### Step 2.3: Report

```
PR #N created: <url>
Title: <type>(<TICKET-KEY>): <description>
Monitoring for CI results and review comments...
```

## Phase 3 — Monitor & Fix Loop

### Step 3.1: Watch

Run `/pr-watch` to poll for CI completion and review comments (~20 min).

### Step 3.2: Handle Results

Based on `/pr-watch` output:

**`reviews_found`**: Review comments detected.
1. Run `/review-pr` to fetch, plan, and implement fixes
   - All GitHub replies posted by `/review-pr` must be prefixed with `[Claudio]: ` — enforced inside `/review-pr` Step 8.
2. `/review-pr` will ask for user approval before implementing (**approval gate**)
3. After implementation, commit the fixes
4. Go to Step 3.3

**`timeout_after_ci` + `CI_STATUS: failed`**: CI failed.
1. Fetch failed logs:
   ```bash
   gh run list --branch <branch> --json name,status,conclusion,databaseId --limit 5
   gh run view <run-id> --log-failed 2>&1 | head -200
   ```
2. Diagnose and fix
3. Commit fixes
4. Go to Step 3.3

**`timeout_after_ci` + `CI_STATUS: passed`**: All clean. Go to Phase 4.

**`max_timeout`**: Timed out. Ask user: continue waiting (restart pr-watch) or stop?

### Step 3.3: Re-validate and Push

1. Run `/ci-check`
2. If CI fails, fix + commit + re-run until green
3. Push: `bash ~/.claude/skills/ship-pr/push.sh origin <branch-name>`
4. Return to Step 3.1 (restart monitor loop)

## Phase 4 — Finalize

Once CI is green and all reviews are resolved, **review the CDK template diff before declaring the PR ready** — a green run does not mean the infra diff was looked at. Follow `pr-watch` Step 6 ("Review the CDK template diff"): classify every changed resource in the bot's `<!-- cdk-diff -->` comment (asset-hash-only vs API-body vs structural), watch for dormant spec drift riding along on generated-package pin bumps, reply with the classification on the bot's thread and resolve it.

Then report:
```
PR #N ready for human review
URL: <url>
Title: <type>(<TICKET-KEY>): <description>
CI: passing
Reviews: all resolved
CDK diff: reviewed — <one-line classification>
```

## Important Notes

- **Merging is a human step in `stxcommodities` repos**: an org ruleset makes `gh pr merge` fail with "base branch policy prohibits the merge", and the `--admin`/REST fallbacks are permission-blocked for agents. When the PR is green and reviews are addressed, do NOT retry merge variants — hand the user the exact command (`gh pr merge <N> --squash --admin --repo <owner>/<repo>`, runnable via `!` in-session) or ask them to merge in the web UI.
- **5 approval gates**: self-review, branch name, commit message, PR title, review fixes (via /review-pr)
- Never force-push without explicit user confirmation
- Never skip `/ci-check` — always run before every push
- The wrapper scripts bypass the pre-push hook intentionally; the skill ensures CI passes before invoking them
