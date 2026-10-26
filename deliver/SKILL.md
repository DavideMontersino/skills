---
name: deliver
description: End-to-end delivery — from Jira ticket (or description) to merged PR. Orchestrates discovery, EDD, implementation, self-review, and PR shipping with full Jira lifecycle management.
user-invocable: true
---

# Deliver

Orchestrates an entire piece of work from inception to shipped PR. Takes a description or Jira ticket, manages the full lifecycle: ticket creation/management, discovery (when needed), EDD authoring, worktree setup, implementation, self-review, PR shipping, and post-delivery insights.

**Coordination-only rule**: This skill runs in the main context as a coordinator. ALL actual work (file reading, code search, implementation, commands) MUST be delegated to subagents. The main context only launches agents and communicates with the user.

**Detect the project toolchain FIRST** (before any verify/ship command). The phases below show TypeScript/npm commands as the default, but many repos (e.g. `core-msk-integration` and other Python services in `core-services`) are **Python**. Check for `package.json` vs `pyproject.toml`/`makefile`/`.python-version` and substitute the equivalents everywhere:

| Step | TypeScript (default) | Python |
|------|----------------------|--------|
| Format/fix | `npx biome check --apply .` | `make format` or `venv/bin/black . && venv/bin/isort .` |
| Lint/typecheck | `npm run check` (tsc + biome) | `venv/bin/black --check . && venv/bin/isort --check-only . && venv/bin/pylint` |
| Tests | `npm test` | `venv/bin/pytest tests/unit/` |
| Install deps | `npm ci` | `make local-dev-init` (creates venv + installs) |
| Internal-pkg freshness | `npm outdated @stxgroup/*` | N/A (pinned in `requirements.txt`; refreshed via `make requirements.txt`) |

Notes for Python repos: run tools via `venv/bin/<tool>` (a bare `make lint` may call `black` off PATH and fail); commit-conventions and `<type>(<TICKET-KEY>)` messages still apply. Skip the `@stxgroup/*` freshness step (Step 1.5) entirely.

## Input

Accepts ONE of:
- A **Jira ticket key** (e.g., `DCS-300`)
- A **description** of the work to do
- A **Jira ticket key + additional context** (e.g., `DCS-300 — also handle the edge case where...`)

---

## Phase 0 — Ticket & Context

### Step 0.1: Parse Input

Determine whether the input contains:
1. A Jira ticket key (matches `[A-Z]+-\d+`, typically `DCS-\d+`)
2. A plain description
3. Both

### Step 0.2: Ensure Jira Ticket Exists

**If Jira ticket provided**: Use `/jira` to fetch the ticket. Read: summary, description, issue type, status, acceptance criteria, linked issues.

**If description only**: Ask the user:
> No Jira ticket provided. Should I create one, or proceed without?

If creating: use `/jira` to create with:
- Project: infer from context (default: `DCS`)
- Type: `Bug` for fix-related, `Story` for features, `Task` for general
- Summary: derived from description
- Description: user's input as Jira wiki markup
- **GATE -- ask user to confirm ticket details before creating**

Store the ticket key for the rest of the workflow.

### Step 0.3: Transition Ticket

Use `/jira` to transition the ticket to "In Progress" (if not already).

### Step 0.4: Understand the Work

Launch an **Explore agent** to:
- Read the Jira ticket details
- Scan the codebase for affected packages and existing patterns
- Identify the scope of change

Present a summary:
> **Understanding of the work:**
> - [what needs to happen]
> - Affected packages: [list]
> - Estimated scope: small / medium / large
>
> Does this match your expectations?

If ambiguous or underspecified: **STOP -- ask clarifying questions**.

### Step 0.5: Discovery Decision

Evaluate whether `/discovery` is needed. Recommend if **2 or more** of these signals are present:

| Signal | Example |
|--------|---------|
| Issue type is Story or Epic | New feature work |
| Description mentions new domain concepts | "audit trail", "reconciliation", "sites" |
| Touches packages that don't exist yet | New service or model |
| Involves external integrations | Third-party API, new AWS service |
| Description says "research" or "investigate" | Explicit request |

**If recommended**: Ask the user:
> This looks like non-trivial new work. I recommend running /discovery first. Proceed with discovery, or skip?

If running: invoke `/discovery` with ticket context. After completion, present the brief and confirm direction.

**GATE -- user confirms understanding of the work before proceeding.**

---

## Phase 1 — Worktree & Branch

### Step 1.1: Fetch Fresh Base

```bash
git fetch origin main
```

### Step 1.2: Branch Name

Compose from the ticket:
- Format: `<type>/<TICKET-KEY>-short-description`
- Type: `feat` (Story/Epic), `fix` (Bug), `chore` (Task)
- Description: kebab-case, max ~50 chars total

Example: `feat/DCS-300-contact-email-lookup`

**GATE -- ask user to confirm the branch name.**

### Step 1.3: Create Worktree

**Respect the user's worktree directory convention.** If the user's global config specifies a layout (e.g. `~/coding/<repo>/<branch>`) or forbids `.claude/worktrees`, do NOT use `EnterWorktree` (which places worktrees under `.claude/worktrees`). Instead create the worktree at the convention path with raw git, off fresh origin/main:

```bash
git fetch origin main
git worktree add ~/coding/<repo>/<branch-name> -b <branch-name> origin/main
```

Otherwise, fall back to:
```
EnterWorktree(name: "<branch-name>")
git reset --hard origin/main
```

### Step 1.4: Verify Branch

Confirm we are NOT on `main`:
```bash
git branch --show-current
```

If on main, STOP -- something went wrong with the worktree.

### Step 1.5: Check @stxgroup/* Package Freshness

```bash
npm outdated @stxgroup/* 2>/dev/null || true
```

If outdated packages are found:
> Some @stxgroup/* packages are outdated. Run `npm run upgrade:internal` to pull latest?

If user approves: run `npm run upgrade:internal` then `npm ci`.
If user declines or packages are current: run `npm ci`.

If `npm ci` or `npm run upgrade:internal` fails with an auth error, ask the user to run:
> Please run `! npm run login` to refresh CodeArtifact credentials, then I'll retry.

---

## Phase 1.5 — EDD (Spec-Driven Development)

### Step 1.5.1: EDD Decision

Evaluate whether an EDD is warranted:

- If `/discovery` was run -> **strongly recommend EDD**
- New feature touching multiple packages -> recommend EDD
- Bug fix or single-package change -> skip EDD
- User explicitly requests or declines -> honor that

Ask the user:
> This work would benefit from an Engineering Design Document. Create an EDD?

### Step 1.5.2: Create EDD (if approved)

Launch a **Developer agent** to:

1. Read the EDD template: `doc/EDD/000-EDD_Template.md`
2. Scan existing EDDs to auto-assign the next number: `ls doc/EDD/*.md | sort | tail -1`
3. Create `doc/EDD/<NNN>_<Title>.md` populated from:
   - Discovery brief (if available)
   - Jira ticket context
   - Codebase exploration findings
4. Fill all template sections: Context, Problem, Requirements (FR/NFR), Design (data model, API, validation), Implementation Constraints, Reference Implementations, Implementation Plan (phased with file tables and exit criteria), Testing scenarios, Pre-Implementation Checklist

**GATE -- user reviews and approves the EDD.**

5. Commit the EDD: `docs(<TICKET-KEY>): add EDD-<NNN> <title>`

### Step 1.5.3: Skip Path

If EDD is skipped, proceed directly to Phase 2.

---

## Phase 2 — Implement

### Step 2.0: Work Already Implemented?

`/deliver` is sometimes invoked **after** the change has already been written (e.g. uncommitted edits sitting on `main` from an earlier planning session). Before planning/implementing, check `git status` in the launch repo:

- If there are uncommitted changes that already implement the work, do NOT re-implement. Move them into the worktree instead of discarding:
  ```bash
  git -C <launch-repo> stash push -m "<TICKET-KEY> wip"
  git worktree add <worktree-path> -b <branch-name> origin/main
  git -C <worktree-path> stash pop   # stashes are shared across worktrees
  ```
  Then continue from Step 2.3 (verify). Skip Step 2.1/2.2.
- If changes are unrelated/dirty, fall back to the Error Handling "Dirty working state" row (stash / commit / abort).
- Otherwise proceed with Step 2.1.

### Step 2.1: Plan

**If EDD exists**: Launch an **Architect agent** to read the EDD and break it into implementation tasks. The architect will delegate to Developer agents.

**If no EDD**: Present an implementation plan directly:
1. Files to create or modify
2. Packages affected
3. Order of changes (dependencies first)
4. Verification steps

**GATE -- user confirms the implementation plan.**

### Step 2.2: Execute

Launch **Developer agent(s)** with full context:
- Ticket key and description
- EDD or implementation plan
- Discovery brief (if any)
- Affected packages and relevant file paths

Developer instructions:
- Follow project coding conventions
- **Before EVERY commit**: run `npx biome check --apply .`
- Commit format: `<type>(<TICKET-KEY>): <description>`
- Keep commits atomic -- one logical change per commit

### Step 2.3: Verify Locally

**Local-env preflight (Python repos especially).** Before building/installing, confirm the env can actually run the suite — otherwise `make local-dev-init` fails deep into a long install:
- **Interpreter**: `python3 --version` must match `.python-version` (e.g. 3.12). If not, find a matching interpreter (`brew install python@3.12` / pyenv) and prefix it on PATH for the venv build — do NOT silently build the venv with the wrong version. Confirm an install with the user first.
- **CodeArtifact / AWS**: internal packages need an AWS profile that can reach the CodeArtifact account (check `makefile` `login` target for the domain-owner). If `aws sts get-caller-identity` fails or no default profile is set, ask the user which `AWS_PROFILE` to use (or to `aws sso login`) — do NOT probe/guess profiles.

Then run `/ci-check` (or the Python equivalents from the toolchain table — `make local-dev-init` once, then `venv/bin/pytest tests/unit/` + `venv/bin/black/isort/pylint`):
```
npm run fix          # biome auto-fix
npm run check        # tsc + biome strict
npm test             # full test suite
```

If CI fails:
1. Diagnose the failure
2. Fix it
3. `npx biome check --apply .`
4. Commit: `fix(<TICKET-KEY>): <what was fixed>`
5. Re-run `/ci-check`
6. **Max 3 fix loops** -- after 3 failures on the same issue, escalate to user

### Step 2.4: Update Jira

Use `/jira` to add a comment:
> Implementation complete in branch `<branch-name>`.
>
> Changes:
> - [bullet summary]
> - Packages: [list]
>
> Moving to review phase.

---

## Phase 3 — Review & Ship

### Step 3.1: Self-Review

Run `/self-review` on a **fresh subagent** (clean context, only sees the diff).

This produces `self-review-report.md` covering:
- Data flow consistency
- API contract integrity
- Pattern conformance
- Query efficiency
- Regressions & hygiene

After the report: fix approved findings in a Developer agent, re-verify with `/ci-check`.

### Step 3.2: Ship PR

Run `/ship-pr` with the note **"self-review already done"** (so ship-pr skips its own self-review step).

`/ship-pr` handles:
1. Push to remote
2. Create a ready-for-review PR (never a GitHub draft: Copilot only reviews non-draft PRs). The title is the final conventional-commit subject from the start — never prefix it with `[DRAFT]`/`WIP`: repos that squash-merge (e.g. core-services `check-pr-title.mjs`) fail CI on any title that is not `type(scope)!: summary`
3. Monitor CI via `/pr-watch` (includes >=5 min Copilot wait)
4. Fix issues via `/review-pr` loop
5. Finalize: report the PR ready for human review when clean

### Step 3.3: Update Jira

After PR is created, use `/jira` to:
1. Add comment with the PR URL
2. Transition ticket to "Review" (if that transition is available)

---

## Phase 4 — Post-Delivery

### Step 4.1: Exit Worktree

```
ExitWorktree(action: "keep")
```

Keep the worktree -- may be needed for follow-up fixes after human review.

### Step 4.2: Delivery Summary

Present a final report:

```
## Delivery Complete

**Ticket**: <TICKET-KEY> -- <summary>
**Branch**: <branch-name>
**PR**: #N -- <title> (<url>)
**Status**: Ready for human review

### What was delivered
- [bullet summary of changes]

### Files changed
<stat summary from git diff --stat>

### Process
- Discovery: yes/no
- EDD: yes/no (EDD-NNN)
- Self-review findings: X fixed
- Copilot comments: N addressed
- Fix loops: N
- CI: passing
```

### Step 4.3: Insights (Self-Improvement)

Reflect on the delivery process:

1. **Fix-loop count**: If 3+ fix-commit-verify cycles occurred, identify the pattern. Propose a concrete checklist item for Phase 2 to catch it earlier next time.

2. **Self-review vs Copilot**: Did Copilot catch things self-review missed? (Defer detailed analysis to `/review-pr`'s Step 10 meta-improvement, which already handles this.)

3. **Discovery accuracy** (if run): Did the recommended direction hold up during implementation? Note significant deviations.

4. **Friction log**: Tool failures, permission issues, unexpected blockers encountered during this delivery.

5. **Skill improvement proposals**: Based on the above, propose concrete changes to any skill invoked:
   - This `/deliver` skill (new checklist items, phase adjustments)
   - `/ship-pr` (new gates, timing)
   - `/self-review` (new check patterns)
   - `/ci-check` (new steps)

Present:
```
## Delivery Insights

### Process Metrics
- Fix loops: N
- Self-review findings: N fixed
- Copilot comments: N addressed
- Discovery deviation: none / minor / significant

### Improvement Proposals
1. [Skill]: [What to change]
   Why: [rationale from this delivery]

Apply these improvements? (list which ones)
```

**GATE -- user approves which improvements to apply.**

If approved: edit the relevant SKILL.md files with the improvements.

### Step 4.4: Session Log

Run `/wrap-up` to write a session summary to the Obsidian vault.

---

## Error Handling

| Scenario | Action |
|----------|--------|
| Jira MCP unavailable | Continue without Jira management; remind user at end |
| Worktree name conflict | Ask user: resume existing worktree, or create fresh (append `-v2`)? |
| CI failures after 3 fix attempts | Escalate to user with error details and what was tried |
| CodeArtifact auth expired | Ask user to run `! npm run login` |
| Ship-pr timeout | Report status, offer: continue waiting or finalize manually |
| Dirty working state on start | Warn user, ask: stash, commit, or abort? |
| Merge blocked by org ruleset (`stxcommodities`: "base branch policy prohibits the merge") | Merging is human-only — `--admin`/REST fallbacks are permission-blocked for agents. Don't retry merge variants; hand the user the exact command (`gh pr merge <N> --squash --admin --repo <owner>/<repo>`, runnable via `!`) or ask them to merge in the web UI, then resume post-merge steps |

## Approval Gates (7 total)

1. **Ticket details** -- before creating a new Jira ticket
2. **Branch name** -- before creating the worktree
3. **EDD** -- before committing the EDD (if created)
4. **Implementation plan** -- before starting development
5. **Self-review findings** -- before fixing flagged issues
6. **PR title** -- before creating the PR (via /ship-pr)
7. **Ready for human review** -- before declaring the PR done (via /ship-pr)
