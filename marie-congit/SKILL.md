---
name: marie-congit
description: Deep git cleanup — categorize all worktrees and branches by PR status, dirty state, and divergence, then interactively clean up tier by tier. More thorough than git-cleanup.
user-invocable: true
---

# Marie Congit

Spark joy in your git repo. Systematically audit every worktree and local branch, categorize them by staleness, and interactively clean up — from obvious trash to "do you still need this?"

## Workflow

### 1. Survey

Gather the full picture in parallel:

```bash
# All worktrees
git worktree list

# All local branches
git branch --list

# Fetch + prune stale remote refs
git fetch origin --prune
```

### 2. Enrich each branch

For every local branch (excluding `main`/`master` and current):

```bash
# PR status
gh pr list --state all --head <branch> --json number,state --limit 1

# Divergence from main
git rev-list --count "<branch>..main"   # behind
git rev-list --count "main..<branch>"   # ahead

# If branch has a worktree, check dirty state
git -C <worktree-path> status --porcelain
```

### 3. Categorize into tiers

Assign every branch to exactly one tier:

**Tier 1 — Safe delete (no user input needed):**
- PR is MERGED, no worktree dirty files
- PR is CLOSED, no worktree dirty files
- No PR, +0 commits ahead of main (fully merged), no dirty files

**Tier 2 — Probably safe (show and batch-confirm):**
- PR merged/closed, only trivial dirty files (package-lock.json, .DS_Store, *.csv)
- Backup branches (`backup/*`, `backups/*`, `*-backup`)
- Branches whose remote tracking ref was pruned (remote deleted)

**Tier 3 — Needs review (walk through case by case):**
- PR merged/closed but has non-trivial dirty files in worktree
- No PR but has commits ahead of main (unpushed work)
- No PR and has dirty files in worktree

**Tier 4 — Keep (inform only, no action):**
- Open PRs
- Current branch
- `main`/`master`

### 4. Present findings

Show a summary table per tier. For Tier 3, include dirty file counts and commit counts.

Example:

```
=== Tier 1: Safe delete (12 items) ===
| Branch                  | PR      | Worktree |
|-------------------------|---------|----------|
| fix/BG-123-whatever     | #99 MRG | yes      |
| ...                     |         |          |

=== Tier 2: Probably safe (5 items) ===
| Branch                  | Reason          |
|-------------------------|-----------------|
| backup/old-experiment   | backup branch   |
| ...                     |                 |

=== Tier 3: Needs review (4 items) ===
| Branch                  | Dirty | Ahead | PR         |
|-------------------------|-------|-------|------------|
| feat/BG-456-wip         | 17    | +7    | none       |
| ...                     |       |       |            |

=== Tier 4: Keeping (2 items) ===
| Branch                  | Reason   |
|-------------------------|----------|
| main                    | main     |
| feat/BG-789-open        | PR open  |
```

### 5. Execute tier by tier

**Tier 1:** Ask once "Delete all 12 safe items?" — single confirmation.

**Tier 2:** Ask once "Delete all 5 probably-safe items?" — single confirmation.

**Tier 3:** Walk through each item individually using AskUserQuestion. For each, show:
- Branch name and worktree path (if any)
- Commit log (`git log --oneline main..<branch>`)
- Dirty files (if any)
- Options: Nuke / Commit WIP + remove worktree / Keep

**Tier 4:** No action, just report.

### 6. Execute deletions

For approved items, in this order:

```bash
# 1. Remove worktrees first
git worktree remove --force <path>

# 2. Delete branches
git branch -D <branch>

# 3. Prune worktree metadata
git worktree prune
```

### 7. Check for orphan worktree directories

After cleanup, verify no empty directories remain in the parent of the main worktree:

```bash
ls -1 <parent-dir>/
```

Remove empty leftover directories if found.

### 8. Housekeeping

If the main worktree is on a stale branch (merged PR), switch to main:

```bash
git checkout main
git pull --ff-only
```

### 9. Report

```
Marie Congit Report:
  Worktrees: 28 → 11 (-17)
  Branches:  52 → 13 (-39)
  Disk freed: ~X directories removed

  Kept (intentional):
    - main
    - feat/BG-789 (open PR)
    - ...
```

## Rules

- ALWAYS present the full picture before deleting anything
- NEVER force-delete Tier 3 items without individual user confirmation
- Tier 1+2 items need one batch confirmation each, not per-item
- If a worktree has merge conflicts (UU in status), flag it prominently
- Skip `main`/`master` always
- Commits are recoverable via reflog for 90 days — mention this to reassure user
- Check that the main worktree itself is on `main` branch at the end
