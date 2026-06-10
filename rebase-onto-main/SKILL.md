---
name: rebase-onto-main
description: Rebase the current branch onto origin/main, resolve the usual package.json/package-lock.json conflicts, regenerate the lockfile, and force-push with lease. Use when a branch is behind main and needs updating before a PR or to clear merge conflicts.
user-invocable: true
---

# Rebase onto origin/main

Rebase the current feature branch onto `origin/main`, resolve conflicts (the common
case is `package.json` + `package-lock.json`), regenerate the lockfile cleanly, and
force-push with lease.

## Guardrails

- **Only force-push your own feature branch.** Never force-push `main` or a branch
  someone else is working on.
- **Never run auth commands without asking.** `npm install` may need CodeArtifact auth;
  if it 401/403s, STOP and ask the user to run `aws sso login --profile stx-core-tooling`
  then `AWS_PROFILE=operator-core-tooling npm run login` (they can run these via `! <cmd>`).
- Always `--force-with-lease`, never a bare `--force`.

## 1. Preflight

```bash
git fetch origin
git status                                  # note any uncommitted WIP
git log --oneline origin/main..HEAD         # your commits
git rev-list --count HEAD..origin/main      # how far behind
```

Identify which committed files overlap with upstream (those are your only real conflicts):

```bash
comm -12 <(git diff --name-only origin/main...HEAD | sort -u) \
         <(git diff --name-only $(git merge-base HEAD origin/main)..origin/main | sort -u)
```

In this repo the overlap is almost always just `package.json` and `package-lock.json`.

## 2. Rebase (autostash carries uncommitted WIP)

```bash
git rebase --autostash origin/main
```

Autostash stashes uncommitted changes before the rebase and pops them back after, so a
dirty working tree (e.g. WIP on a file upstream didn't touch) is fine and survives.

## 3. Resolve conflicts

A given file can conflict on **each** of your commits that touched it — expect to repeat
this per commit. After each resolution: `git add <files> && git rebase --continue`.

### `package.json` → union resolve

Both sides are almost always **additive** (new scripts, deps, workspace entries). Keep
**every** entry from both sides — never drop what upstream added. For a shared line that
was version-bumped on both sides (e.g. `@stxgroup/cis-* ^0.56.0` vs `^0.83.0`), take the
**higher / upstream** version. After editing, verify:

```bash
grep -n '<<<<<<<\|=======\|>>>>>>>' package.json || echo "clean"
node -e "JSON.parse(require('fs').readFileSync('package.json','utf8')); console.log('valid JSON')"
```

### `package-lock.json` → never hand-merge

Upstream lockfile churn is huge and unmergeable by hand. Take the new base's copy and
regenerate it once at the very end:

```bash
git checkout --ours package-lock.json     # during rebase, --ours = the new base (origin/main)
git add package-lock.json
```

(`--ours`/`--theirs` are inverted during a rebase: "ours" is the branch you're rebasing
**onto**, "theirs" is the commit being replayed.)

### Other files

Resolve by intent — understand both changes and combine them.

## 4. Regenerate the lockfile (once, after the rebase finishes)

The lockfile must match the unioned `package.json`. Regenerate on the repo's pinned Node
(`.nvmrc`, currently **24 / npm 11** — not an older local default; mismatched versions
churn `libc`/`sharp` entries):

```bash
nvm use                                    # reads .nvmrc → node 24 / npm 11
npm install                                # reconciles package-lock.json
```

If your added deps were already present transitively in upstream's tree, the diff may be
tiny (just the direct-dependency references) — that's correct. Confirm the lockfile is in
sync (this must be a no-op):

```bash
npm install --package-lock-only            # should leave package-lock.json unchanged
git status --short package-lock.json       # expect: empty
```

Commit the regenerated lockfile. Ideally it belongs in the commit that changed the deps;
if that's a middle commit (interactive rebase unavailable / awkward), a dedicated
`chore: regenerate lockfile after rebase onto main` commit on top is fine.

```bash
git add package-lock.json
git commit -m "chore: regenerate lockfile after rebase onto main"
```

## 5. Verify

```bash
git log --oneline origin/main..HEAD        # your commits replayed on top
git merge-base --is-ancestor origin/main HEAD && echo "origin/main is ancestor ✓"
git status --short                         # only intentional WIP remains
```

## 6. Force-push with lease

```bash
git push --force-with-lease
```

`--force-with-lease` refuses the push if the remote moved since your last fetch — safe
against clobbering someone else's work on a shared branch.
