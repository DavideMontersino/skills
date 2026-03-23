---
name: redact-history
description: Clean up commit history on the current branch by grouping, squashing, and rewording commits before merging. Use when the user wants to tidy up messy commit history.
user-invocable: true
---

# Redact History

Analyze the commit history of the current branch, propose a clean grouping, and execute a non-interactive rebase to produce a tidy history.

## Workflow

### Step 1: Determine Base Branch

```bash
# Try to get base branch from PR
gh pr view --json baseRefName --jq '.baseRefName' 2>/dev/null

# Fall back to main/master
git rev-parse --verify main 2>/dev/null && echo main || echo master
```

### Step 2: Create Backup Branch

Before any modifications, create a backup of the current branch state:

```bash
BRANCH=$(git branch --show-current)
BACKUP="backup/${BRANCH}"
git branch "$BACKUP" HEAD
```

If `backup/<branch>` already exists, abort and inform the user — a previous redaction may be in progress.

### Step 3: Gather Commits

```bash
# Get all commits on this branch since diverging from base
git log <base>..HEAD --reverse --format='%h %s' --no-merges
```

Also gather diff stats to understand scope:

```bash
git diff --stat <base>..HEAD
```

### Step 4: Analyze and Propose Groupings

Analyze the commit list and propose a clean history. Look for:

- **Fixup patterns**: commits like "fix typo", "oops", "wip", "fixup!", "squash!", "address review", "lint fix" → squash into the commit they fix
- **Related work**: consecutive commits touching the same files/feature → squash into one
- **Reword candidates**: commits with vague messages ("update", "changes", "stuff") → reword with descriptive messages
- **Already clean**: commits that are self-contained and well-described → keep as-is (pick)

**Propose the result as a table:**

```
Proposed clean history (from oldest to newest):

| # | Action | Original commits | Proposed message |
|---|--------|------------------|------------------|
| 1 | squash | abc1234, def5678, ghi9012 | feat(BG-xxx): add user profile page |
| 2 | pick   | jkl3456 | fix(BG-xxx): handle null avatar URL |
| 3 | squash | mno7890, pqr1234 | refactor(BG-xxx): extract validation logic |
```

**Rules for proposed messages:**
- Follow the project's conventional commit format: `<type>(BG-<ticket>): <description>`
- Extract ticket number from branch name if possible
- Use imperative mood
- Keep under 72 characters

Ask the user for confirmation. They may:
- Approve as-is
- Modify groupings or messages
- Cancel

### Step 5: Execute the Rebase

Use `GIT_SEQUENCE_EDITOR` to automate the interactive rebase. Build a sed script that transforms the todo list:

```bash
# Build the rebase instruction script
# For each commit, determine: pick, squash, or fixup
# First commit in each group = pick (or reword), rest = fixup

GIT_SEQUENCE_EDITOR="sed -i '' '<sed commands>'" git rebase -i <base>
```

**Sed command construction:**

For each group of commits:
1. First commit → `pick` (keep as-is) or `reword` (if message changes)
2. Subsequent commits → `fixup` (discard their messages)

If rewording is needed, also set `GIT_EDITOR` to inject the new message:

```bash
# For a single reword, use GIT_EDITOR with printf
GIT_EDITOR="printf '<new message>' >" git rebase -i <base>
```

**For multiple rewords**, do the rebase in two passes:
1. First pass: squash/fixup only (no rewords), using `GIT_SEQUENCE_EDITOR`
2. Second pass: amend each commit that needs rewording using `git rebase -i` with targeted rewords, or use `git commit --amend -m` between `git rebase --edit-todo` steps

**Simpler alternative for multiple rewords**: after the squash rebase, iterate over commits that need new messages:

```bash
# After squash rebase, amend specific commits
git rebase -i <base> # with only 'reword' actions
# Use GIT_SEQUENCE_EDITOR to mark specific commits as 'reword'
# Use a script as GIT_EDITOR that outputs the right message per commit
```

### Step 6: Handle Conflicts

If the rebase encounters conflicts:

1. Show the conflicting files: `git diff --name-only --diff-filter=U`
2. Attempt to resolve automatically if the conflict is trivial
3. If not resolvable, explain the situation and let the user decide:
   - Resolve manually and `git rebase --continue`
   - `git rebase --abort` to cancel

### Step 7: Verify Result (Deterministic Check)

After successful rebase, verify the rebase was **lossless** by diffing against the backup:

```bash
BRANCH=$(git branch --show-current)
BACKUP="backup/${BRANCH}"

# This MUST produce empty output — any diff means data was lost or altered
git diff "$BACKUP"..HEAD
```

**If the diff is NOT empty**: the rebase changed code. Abort immediately:

```bash
# Restore from backup
git reset --hard "$BACKUP"
```

Report the failure to the user and do NOT delete the backup branch.

**If the diff IS empty**: the rebase is verified lossless. Show the clean history:

```bash
git log <base>..HEAD --oneline --no-merges
```

Inform the user:
- The backup branch `backup/<branch>` is preserved
- They can delete it after verifying: `git branch -D backup/<branch>`
- They can restore the original history anytime: `git reset --hard backup/<branch>`

## Rules

- ALWAYS show proposed groupings and get confirmation before rebasing
- NEVER force-push — that's the user's decision after reviewing the result
- NEVER rebase commits that are already on the base branch
- If the branch has no PR and no clear base, ask the user for the base branch
- Preserve the chronological order of groups (first group = oldest work)
- When in doubt about grouping, keep commits separate rather than over-squashing
- If rebase fails or produces unexpected results, abort and report
