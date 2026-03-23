---
name: git-cleanup
description: Clean up git worktrees and local branches from merged/closed PRs. Use when the user wants to tidy up stale branches and worktrees.
user-invocable: true
---

# Git Cleanup

Remove stale worktrees and local branches whose PRs are merged or closed.

## Workflow

### 1. Discover stale branches

Use `gh` to find local branches with closed/merged PRs:

```bash
# Get all local branches (excluding current)
git branch --list --format='%(refname:short)' | grep -v "^$(git branch --show-current)$"

# For each branch, check PR status
gh pr list --head <branch> --state all --json number,state,headRefName --limit 1
```

A branch is **stale** if:
- Its PR is `MERGED` or `CLOSED`
- OR it has no PR and no commits ahead of main (fully merged)

### 2. Check worktrees

```bash
git worktree list
```

A worktree is stale if its branch is stale (per above).

### 3. Present findings

Show the user a table:

| Branch | PR | Status | Worktree | Action |
|--------|----|--------|----------|--------|

Ask for confirmation before proceeding.

### 4. Clean up (after confirmation)

**Worktrees first** (must remove before deleting branch):

```bash
git worktree remove <path>
# If dirty, inform user and skip unless they confirm --force
```

**Then branches:**

```bash
git branch -d <branch>
# Use -d (safe delete) first. If fails, inform user — only use -D with explicit approval.
```

**Then prune remote tracking refs:**

```bash
git fetch --prune
```

## Rules

- ALWAYS show what will be deleted and ask for confirmation
- NEVER force-delete without explicit user approval
- Skip branches with uncommitted worktree changes (warn user)
- Skip the current branch
- Skip `main`/`master`
- If a worktree has changes, list them and ask what to do
