---
name: review-pr
description: Fetch unresolved PR review comments, plan fixes, get approval, implement, commit, then reply to all comments on GitHub.
---

# Review PR Skill

Fetch unresolved review comments from the GitHub PR associated with the current branch. Plan changes, get user approval, implement, commit, then reply to every comment on GitHub.

## Workflow

### Step 1: Find the PR for the Current Branch

```bash
git branch --show-current
gh pr list --head <BRANCH_NAME> --json number,title,url,state --limit 1
```

If no PR is found, check if a PR number was provided as an argument. If neither works, stop.

### Step 2: Fetch Review Threads

Run the helper script bundled with this skill:

```bash
~/.claude/skills/review-pr/fetch-threads.sh <PR_NUMBER>
```

### Step 3: Filter to Unresolved Comments

From the GraphQL response, keep threads where `isResolved` is `false`.

Focus on the first comment in each thread (the top-level review comment) that is:
- Not from the PR author
- Actionable (suggestions, requests, corrections)

Skip:
- Approvals / "LGTM" comments
- Pure questions that were answered

### Step 4: Present Comment Summary and Plan

Present a structured summary of what was found:

```
Found X review comments on PR #N: "PR Title"

1. [file.ts:42] @reviewer - "Comment text summary..."
   Plan: <what you intend to change>

2. [other-file.vue:15-20] @reviewer - "Comment text summary..."
   Plan: <what you intend to change>
```

**CRITICAL: Stop here and wait for user approval before making any changes.**

### Step 5: Implement Comments (after approval)

For each actionable comment:
1. Read the affected file at the commented line range
2. Understand context and surrounding code
3. Implement the requested change following project standards

Delegate complex changes to specialized agents:
- Frontend (Vue) changes -> `vue3-composition-expert` agent
- Backend (Lambda) changes -> `lambda-handler-expert` agent

### Step 6: Verify Changes

```bash
npm run fix

# Frontend changes
npm run type-check -w rng-portal-client
npm run lint -w rng-portal-client

# Backend changes
npm test -w rng-portal-backend

# DDB service changes
npm test -w packages/rng-ddb-service
```

### Step 7: Commit

Create a single commit with all changes. Use conventional commit format from the branch name.

**Ask the user to push.** Do not push yourself.

### Step 8: Reply to All Comments on GitHub

After the commit, reply to EVERY unresolved comment thread on the PR. Do NOT mark any thread as resolved — let the reviewer do that.

Use the REST API to reply to each review comment thread. Detect the repo dynamically:

```bash
REPO_SLUG=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
gh api repos/$REPO_SLUG/pulls/<PR_NUMBER>/comments/<COMMENT_ID>/replies \
  -X POST -f body='<reply text>'
```

Reply content guidelines:
- Briefly describe what was done to address the comment
- Reference the commit if helpful
- If a comment was intentionally skipped, explain why
- **If the comment author is `copilot` (GitHub Copilot)**: include a funny, sharp remark in your reply. Be witty. Roast the robot.

### Step 9: Summary Report

Provide a final summary:
- Comments implemented (with file:line references)
- Comments skipped (with reason)
- Verification results
- Remind user to push if not done yet

### Step 10: Improve Self-Review Skill

After processing all comments, abstract the feedback and check whether the `/self-review` skill (`~/.claude/skills/self-review/SKILL.md`) would have caught these issues.

For each comment that was implemented (not skipped):
1. **Abstract the issue** — strip project-specific details and identify the underlying review pattern (e.g., "delete method returns data when siblings return void" → "method signature inconsistency across sibling entities")
2. **Check coverage** — is this pattern already covered by a step in the self-review skill?
3. **Classify**:
   - **Already covered** — the self-review skill has a check that would have caught this. No action needed.
   - **Gap** — the self-review skill has no check for this pattern. Propose an addition.
   - **Refinement** — the self-review skill covers the general area but the specific check could be sharper. Propose an amendment.

If there are gaps or refinements, present them to the user:

```
Self-review skill improvements from this PR review:

1. [Gap] <pattern description>
   Proposed addition to step N: "<check description>"

2. [Refinement] <pattern description>
   Current check: "<existing text>"
   Proposed: "<improved text>"
```

**Wait for user approval**, then update `~/.claude/skills/self-review/SKILL.md` with the approved changes.

## Project Standards Integration

Before implementing changes, read the appropriate standards:
- Frontend: `.claude/rules/vue3-standards.md`
- Backend: `.claude/rules/lambda-standards.md`
- General: `.claude/rules/typescript.md`
- ElectroDB: `.claude/rules/electrodb-standards.md`
