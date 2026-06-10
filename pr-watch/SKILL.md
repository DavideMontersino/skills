---
name: pr-watch
description: Poll a PR for CI results and review comments, then act on them. Use after pushing code to avoid manually checking for reviews.
user-invocable: true
---

# PR Watch Skill

After a PR is created or updated, poll for CI completion and review comments, then automatically act on them.

## Step 1: Identify the PR

```bash
BRANCH=$(git branch --show-current)
gh pr list --head "$BRANCH" --json number,title,url,state --limit 1
```

If no PR found and a PR number was provided as argument, use that. Otherwise report error and stop.

## Step 2: Detect Repository

Auto-detect the repository slug for GraphQL queries:

```bash
REPO_SLUG=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
OWNER=$(echo "$REPO_SLUG" | cut -d/ -f1)
REPO=$(echo "$REPO_SLUG" | cut -d/ -f2)
```

## Step 3: Check for Merge Conflicts

Before polling, check the PR's mergeable state immediately. If the PR has conflicts with the base branch, CI won't run.

```bash
MERGEABLE=$(gh pr view $PR_NUMBER --json mergeable -q '.mergeable')
```

If `MERGEABLE` is `CONFLICTING`, skip polling entirely and exit with a conflict report (see Step 4 `conflicts` handler).

If `MERGEABLE` is `UNKNOWN`, wait 10 seconds and retry once -- GitHub sometimes needs a moment to compute mergeability.

## Step 4: Launch Background Polling

Run the following polling script in the background using `run_in_background: true`. It polls every 60 seconds for up to 20 minutes.

The script has three phases:
- **Phase 0**: If checks are empty after 2 polls, check for merge conflicts (CI won't start if PR has conflicts)
- **Phase 1**: Wait for all CI checks to complete. `statusCheckRollup` mixes `CheckRun` nodes (result in `conclusion`) with `StatusContext` nodes (result in `state`, e.g. `copilot-review-gate`) — read both, or a `StatusContext` looks perpetually unfinished and the watcher always hits `max_timeout` on an already-green PR.
- **Phase 2**: After CI completes, wait for Copilot to finish reviewing, then act on review comments. The exit trigger is the count of **unresolved review threads** — never the raw REST comment count, which includes resolved/historical comments and would false-fire `reviews_found` at 0s.

**Copilot review detection**: A single boolean ("pending or not") conflates "Copilot finished" with "Copilot was never assigned yet" — they look identical via `requested_reviewers` alone. Use a three-state derived from BOTH endpoints, and check for **freshness against the current HEAD** so a stale review from an earlier commit isn't accepted as a green light after a fix push:

- `pending` — `copilot-pull-request-reviewer[bot]` is in `GET /pulls/{n}/requested_reviewers` (yellow dot in UI). Keep waiting.
- `reviewed` — Copilot has a review in `GET /pulls/{n}/reviews` whose `commit_id` matches the PR's current HEAD commit. Done reviewing this commit; safe to exit.
- `unknown` — Copilot has no reviews at all, OR all Copilot reviews are on prior commits (stale). After a fix push, the previous review is stale until Copilot re-runs. Wait the full `REVIEW_WAIT` before declaring no-issues.

Only treat `reviewed` as a green light to exit early. `unknown` after CI must wait out `REVIEW_WAIT` to avoid two false-positive flavors:
1. Reporting "Copilot found no issues" when Copilot never even started (no reviews at all).
2. Reporting "Copilot found no issues" when only prior-commit reviews exist and Copilot hasn't re-reviewed the latest push yet.

```bash
PR_NUMBER=<number>
BRANCH=<branch>
OWNER=<owner>
REPO=<repo>
MAX_WAIT=1200  # 20 minutes total
REVIEW_WAIT=300  # 5 minutes extra for reviews after CI completes
INTERVAL=60
ELAPSED=0
CI_DONE_AT=""
EMPTY_POLLS=0

while [ $ELAPSED -lt $MAX_WAIT ]; do
  # Check CI status via statusCheckRollup (gh pr checks can return empty even when checks exist)
  CI_JSON=$(gh pr view $PR_NUMBER --json statusCheckRollup -q '.statusCheckRollup' 2>/dev/null || echo "[]")

  ALL_CI_DONE=$(echo "$CI_JSON" | python3 -c "
import sys, json
checks = json.load(sys.stdin)
if not checks:
    print('pending')
    sys.exit(0)
# statusCheckRollup mixes two node types with DIFFERENT result fields:
#   CheckRun     -> 'conclusion' (empty/None until status == COMPLETED)
#   StatusContext-> 'state' (e.g. copilot-review-gate). It has NO 'conclusion',
#                   so reading conclusion alone leaves it forever 'pending'.
def result(c):
    return (c.get('conclusion') or c.get('state') or '').upper()
done_states = {'SUCCESS', 'FAILURE', 'NEUTRAL', 'SKIPPED', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED', 'STALE', 'ERROR'}
fail_states = {'FAILURE', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED', 'STALE', 'ERROR'}
results = [result(c) for c in checks]
all_done = all(r in done_states for r in results)
any_failed = any(r in fail_states for r in results)
if all_done and any_failed:
    print('failed')
elif all_done:
    print('passed')
else:
    print('pending')
" 2>/dev/null || echo "pending")

  # Detect empty checks -- likely merge conflicts blocking CI
  CHECKS_EMPTY=$(echo "$CI_JSON" | python3 -c "
import sys, json
checks = json.load(sys.stdin)
print('true' if not checks else 'false')
" 2>/dev/null || echo "true")

  if [ "$CHECKS_EMPTY" = "true" ]; then
    EMPTY_POLLS=$((EMPTY_POLLS + 1))
    if [ $EMPTY_POLLS -ge 2 ]; then
      MERGEABLE=$(gh pr view $PR_NUMBER --json mergeable -q '.mergeable' 2>/dev/null || echo "UNKNOWN")
      if [ "$MERGEABLE" = "CONFLICTING" ]; then
        echo "[${ELAPSED}s] No CI checks and PR has merge conflicts"
        echo "---DONE---"
        echo "REASON: conflicts"
        echo "CI_STATUS: blocked"
        echo "UNRESOLVED_REVIEWS: 0"
        exit 0
      fi
    fi
  else
    EMPTY_POLLS=0
  fi

  # Track when CI finished
  if [ -z "$CI_DONE_AT" ] && [ "$ALL_CI_DONE" != "pending" ]; then
    CI_DONE_AT=$ELAPSED
    echo "[${ELAPSED}s] CI completed with status: $ALL_CI_DONE. Checking for Copilot review..."
  fi

  # Three-state Copilot detection: pending / reviewed / unknown.
  # `requested_reviewers` alone can't tell "done" from "never assigned" — both omit Copilot.
  # Cross-reference with /pulls/{n}/reviews to find a Copilot review of any state.
  COPILOT_REQUESTED=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUMBER/requested_reviewers 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
users = data.get('users', [])
print('true' if any(u.get('login') == 'copilot-pull-request-reviewer[bot]' for u in users) else 'false')
" 2>/dev/null || echo "false")

  HEAD_SHA=$(gh pr view $PR_NUMBER --repo $OWNER/$REPO --json headRefOid -q '.headRefOid' 2>/dev/null || echo "")

  COPILOT_HAS_FRESH_REVIEW=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews 2>/dev/null | HEAD_SHA="$HEAD_SHA" python3 -c "
import os, sys, json
head = os.environ.get('HEAD_SHA', '')
reviews = json.load(sys.stdin)
fresh = any(
    (r.get('user') or {}).get('login') == 'copilot-pull-request-reviewer[bot]'
    and r.get('commit_id') == head
    for r in reviews
)
print('true' if fresh else 'false')
" 2>/dev/null || echo "false")

  if [ "$COPILOT_REQUESTED" = "true" ]; then
    COPILOT_STATE="pending"
  elif [ "$COPILOT_HAS_FRESH_REVIEW" = "true" ]; then
    COPILOT_STATE="reviewed"
  else
    # Either no reviews at all, or only stale reviews on prior commits.
    COPILOT_STATE="unknown"
  fi
  # Backwards-compat alias used below: only "pending" blocks early exit.
  COPILOT_PENDING=$([ "$COPILOT_STATE" = "pending" ] && echo "true" || echo "false")

  # Check for review comments: both inline threads AND body-level reviews
  REVIEW_JSON=$(gh api graphql -f query='
    query($owner: String!, $repo: String!, $pr: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr) {
          reviewThreads(first: 100) {
            nodes {
              isResolved
              comments(first: 10) {
                nodes {
                  body
                  path
                  line
                  startLine
                  author { login }
                  createdAt
                }
              }
            }
          }
        }
      }
    }
  ' -f owner="$OWNER" -f repo="$REPO" -F pr=$PR_NUMBER 2>/dev/null || echo "{}")

  UNRESOLVED=$(echo "$REVIEW_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
threads = data.get('data', {}).get('repository', {}).get('pullRequest', {}).get('reviewThreads', {}).get('nodes', [])
unresolved = [t for t in threads if not t.get('isResolved', True)]
print(len(unresolved))
" 2>/dev/null || echo "0")

  # Informational only -- raw count of ALL inline review comments, including
  # already-resolved ones and comments from prior commits. NEVER use this as an
  # exit trigger: a PR with old resolved Copilot threads has REVIEW_COMMENTS > 0
  # forever, which would fire `reviews_found` at 0s with nothing to act on.
  # The actionable signal is UNRESOLVED (open review threads) above.
  REVIEW_COMMENTS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments 2>/dev/null | python3 -c "
import sys, json
comments = json.load(sys.stdin)
print(len(comments))
" 2>/dev/null || echo "0")

  echo "[${ELAPSED}s] CI=$ALL_CI_DONE copilot=$COPILOT_STATE threads=$UNRESOLVED comments=$REVIEW_COMMENTS"

  # Exit conditions
  # Trigger on UNRESOLVED review threads only -- never on the raw REVIEW_COMMENTS
  # count (see note above; resolved/historical comments would false-fire instantly).
  if [ "$UNRESOLVED" -gt 0 ]; then
    # Reviews found -- but only act on them if Copilot is done (or not assigned)
    if [ "$COPILOT_PENDING" = "false" ]; then
      echo "---DONE---"
      echo "REASON: reviews_found"
      echo "CI_STATUS: $ALL_CI_DONE"
      echo "UNRESOLVED_REVIEWS: $UNRESOLVED"
      echo "REVIEW_COMMENTS: $REVIEW_COMMENTS"
      echo "CI_CHECKS: $CI_JSON"
      echo "REVIEW_THREADS: $REVIEW_JSON"
      exit 0
    fi
  fi

  # Early-exit ONLY when Copilot has actually submitted a review.
  # `unknown` (auto-request might still fire) must wait out REVIEW_WAIT.
  if [ -n "$CI_DONE_AT" ] && [ "$COPILOT_STATE" = "reviewed" ]; then
    SINCE_CI=$((ELAPSED - CI_DONE_AT))
    if [ $SINCE_CI -ge 60 ]; then
      echo "---DONE---"
      echo "REASON: copilot_done_no_issues"
      echo "CI_STATUS: $ALL_CI_DONE"
      echo "COPILOT_STATE: $COPILOT_STATE"
      echo "UNRESOLVED_REVIEWS: $UNRESOLVED"
      echo "REVIEW_COMMENTS: $REVIEW_COMMENTS"
      echo "CI_CHECKS: $CI_JSON"
      exit 0
    fi
  fi

  # Fallback: CI is done but Copilot is pending or unknown — wait up to REVIEW_WAIT.
  if [ -n "$CI_DONE_AT" ]; then
    SINCE_CI=$((ELAPSED - CI_DONE_AT))
    if [ $SINCE_CI -ge $REVIEW_WAIT ]; then
      echo "---DONE---"
      echo "REASON: timeout_after_ci"
      echo "CI_STATUS: $ALL_CI_DONE"
      echo "COPILOT_STATE: $COPILOT_STATE"
      echo "UNRESOLVED_REVIEWS: $UNRESOLVED"
      echo "REVIEW_COMMENTS: $REVIEW_COMMENTS"
      echo "CI_CHECKS: $CI_JSON"
      exit 0
    fi
  fi

  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "---DONE---"
echo "REASON: max_timeout"
echo "CI_STATUS: ${ALL_CI_DONE:-pending}"
echo "UNRESOLVED_REVIEWS: ${UNRESOLVED:-0}"
echo "CI_CHECKS: ${CI_JSON:-[]}"
```

After launching this in the background, tell the user: "Watching PR #N for CI results and review comments. I'll notify you when there's something to act on."

## Step 5: Process Results

When the background task completes, read its output and act based on the REASON:

### `conflicts`

The PR has merge conflicts with the base branch, which prevents CI from running. Rebase on origin/main and force push:

```bash
git fetch origin main && git rebase --autostash origin/main
```

If the rebase succeeds, force push and restart polling:

```bash
git push --force-with-lease
```

Then run `/pr-watch` again to monitor the new push.

If the rebase has conflicts, report them to the user and stop -- manual resolution is needed.

### `reviews_found`

Review comments were found. Use the `/review-pr` skill if available, otherwise:

1. Parse the REVIEW_THREADS JSON from the output
2. Filter to unresolved threads
3. Present a structured summary of the comments
4. Ask the user for approval before implementing
5. Implement the fixes, commit, and push
   - When replying to comments on GitHub (whether via `/review-pr` or directly), every reply body must start with `[Claudio]: `. See `review-pr` Step 8.

### `timeout_after_ci` with `CI_STATUS: failed`

CI failed but no review comments. Fetch and fix CI failures:

```bash
gh run list --branch <BRANCH> --json name,status,conclusion,databaseId --limit 5
gh run view <DATABASE_ID> --log-failed 2>&1 | head -n 200
```

Fix the failures, run `/ci-check`, commit, and push.

### `copilot_done_no_issues` with `CI_STATUS: passed`

Copilot has actually submitted a review with no actionable comments, CI passed. Report success:

"PR #N: All CI checks passed. Copilot reviewed and found no issues. PR looks good!"

### `timeout_after_ci` with `CI_STATUS: passed`

CI passed but `COPILOT_STATE` is `pending` or `unknown` after the full review wait. Distinguish in the user-facing message:

- `COPILOT_STATE: pending` — "CI passed; Copilot was still reviewing when we timed out. Check the PR before merging."
- `COPILOT_STATE: unknown` — "CI passed; Copilot never started reviewing within the wait window (auto-request may not be configured for this repo). PR looks clean otherwise."

### `max_timeout`

Timed out waiting. Report status and suggest checking manually.

## Step 6: After Implementation

After fixing review comments or CI failures:

1. Run `/ci-check` to verify fixes locally
2. Commit and push the fixes
3. Optionally restart polling: offer to run `/pr-watch` again for another round
