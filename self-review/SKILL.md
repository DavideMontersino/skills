---
name: self-review
description: Proactive pre-PR review of the current branch. Analyzes data flow consistency, pattern conformance, API contract integrity, query efficiency, and documentation accuracy. Produces a structured markdown report.
---

# Self-Review Skill

Proactive code review of the current branch before PR submission. Catches project-specific issues that linters, type checkers, and generic AI reviewers miss.

Independent of `/review-pr` (which handles post-submission reviewer feedback).

## Workflow

### Step 1: Identify Scope

```bash
git log main..HEAD --oneline
git diff main --stat
```

Build a list of:
- Commits on the branch (with messages)
- Files changed (with change type: added, modified, deleted)
- Packages affected
- Entities touched (ElectroDB models, TypeSpec models, handlers, migrations)

### Step 2: Data Flow Consistency

DynamoDB has no referential integrity — consistency is the application's job. This is the highest-value check.

For each entity **added or modified** on this branch:

1. **Map all write paths** — find every place that creates, updates, upserts, or deletes the entity:
   - Model methods (the canonical path)
   - Handlers that call those methods
   - Migrations that may bypass the model (raw ElectroDB entity operations)
   - Scripts, seed data, test fixtures

2. **Flag model bypasses** — any code that uses raw entity operations (`.create()`, `.patch()`, `.delete()` on the ElectroDB entity directly) instead of the model class methods. These skip transactional logic, normalization, and denormalization maintenance.

3. **Verify denormalization sync** — if the entity participates in a denormalization, projection, or lookup pattern (e.g., ContactEmail as a lookup for Contact.email):
   - Are ALL write paths to the source field maintaining the derived entity?
   - Are writes transactional (DynamoDB TransactWriteItems)?
   - On delete: are dependent/derived entities cleaned up?
   - On update: are old derived records deleted and new ones created?

4. **Check collection membership** — if the entity belongs to an ElectroDB collection:
   - Do delete paths query the collection first and clean up all members?
   - Or do they delete the entity in isolation, orphaning collection peers?

5. **Verify key normalization** — if the entity uses normalized keys (e.g., lowercased email):
   - Is normalization applied in ALL write paths?
   - Is normalization applied in ALL query paths?
   - Is normalization enforced in the model layer (not just hoped for in callers)?

6. **Check `.upsert()` vs `.patch()`** — `.patch()` does not update GSI attributes, which can leave indexes inconsistent. Flag any `.patch()` usage and verify it's intentional.

### Step 3: API Contract Integrity

1. **TypeSpec ↔ handler alignment** — for each handler modified on this branch:
   - Does the handler read query params / body fields that are declared in TypeSpec?
   - Does the TypeSpec declare params / fields that the handler ignores?
   - Do response types match?

2. **Accidental regressions** — diff TypeSpec files on the branch:
   - Flag any removal of existing operations, query parameters, or model fields
   - Verify each removal is intentional (mentioned in commit message or EDD)

3. **Generated package impact** — if TypeSpec changed:
   - Are changes additive (new optional fields, new operations) or breaking (removed/renamed fields, changed required fields)?
   - List all in-repo consumers of affected generated packages (`@stxgroup/*-types`, `@stxgroup/*-typescript-client`, `@stxgroup/*-enums`)
   - Verify no consumer would break

### Step 4: Pattern Conformance

1. **File placement** — do new files follow the naming/organization convention of sibling files in the same directory? Compare with existing files. Flag novel directory structures when established conventions exist.

2. **Method signatures** — do new model methods (especially CRUD) match the return types and error handling patterns of equivalent methods on sibling entities? (e.g., if all other `delete()` methods return void, a new one returning data is a deviation)

3. **Model vs handler responsibility** — is business logic (validation, orchestration, multi-entity writes) in the model layer or leaking into handlers? Flag handlers that orchestrate across multiple models when other handlers delegate entirely to a single model method.

4. **Lookup completeness** — do switch/map lookups over entity types handle ALL entity types present in the underlying data structures? Flag any entity type that exists in the data model but is missing from lookup functions.

5. **Convention compliance**:
   - Workspace deps use `"*"` for `@stxgroup/*` packages
   - No hand-written types that duplicate generated packages
   - Enum values in PascalCase
   - UUID generation via `@stxgroup/uuid-service`, not local helpers
   - Semver range correctness — when adding or modifying external dependency version ranges, verify the resolved set matches the intent. Caret on sub-1.0 versions is the common footgun: `^0.0.x` resolves to exact-match (not "any 0.0.*"); `^0.x.y` only allows patches within `0.x`. Use explicit ranges (`>=0.0.x <0.1.0`) when forward-compat is intended.

6. **Routing predicate vs downstream tolerance** — when a routing predicate (e.g., `isXAdjustment`) gates a code path, verify the predicate's acceptance criteria are no wider than the downstream function's preconditions. A predicate that accepts `value: 0` routing to a function that rejects `value <= 0` is a latent 500.

7. **Input constraint alignment** — when HTML inputs use `min`, `max`, `step`, or `pattern` attributes, verify they're consistent with the computed validation logic. Mismatches create confusing UX where the browser allows values that the app rejects (or vice versa).

### Step 5: Query Efficiency

DynamoDB scans are expensive and don't scale. Flag:

1. **Table/GSI scans** — any `.scan()` operation or query without a partition key
2. **Sequential queries replaceable by collections** — multiple queries to entities sharing the same ElectroDB collection that could be a single `collections.<name>().go()` call
3. **N+1 patterns** — loops that issue a query per iteration instead of batch operations
4. **Missing GSI usage** — queries that filter in-memory when a GSI could do the filtering server-side
5. **`contains` on List of Maps** — DynamoDB `contains` matches full list elements, not nested field values. This is a correctness bug, not just a performance issue.
6. **Read-consistency mode on guard reads** — trace every read whose result **gates a subsequent write** (invariant/uniqueness/overlap checks, read-modify-write merges, existence pre-checks). DynamoDB primary-key `get` and every GSI query are **eventually consistent by default** ("never read back what you just wrote" — see `.claude/rules/dynamodb.md`), so a write immediately followed by such a check can miss the just-written row and admit a duplicate/overlap or return a stale value. Flag any guard read that omits `consistent: true`. Base-table `get`/`query` can be made strongly consistent (`.go({ consistent: true })`); GSI reads **cannot** — a guard that must be correct on a GSI needs a redesign (denormalize onto the base table, transactional write, or an immutable key), and this residual must be called out explicitly, not left silent. For `batchGet`, also flag missing **fail-closed handling of `unprocessed` keys** — an omitted key silently drops a row from the check (throttling → false-negative); throw rather than proceed. This is the class `/self-review` has historically missed and Copilot catches.

### Step 6: Regressions & Hygiene

1. **Diff audit** — for each commit, check if any hunk removes or modifies code not described by the commit message. Flag accidental deletions.

2. **Temporary workarounds & unresolved questions** — search for TODO, HACK, WORKAROUND, unresolved questions (`// why?`, `// should we`, `// what if`), or temporary CI steps in changed files. Verify each has a follow-up Jira ticket or is resolved before PR.

3. **Documentation accuracy** — if EDDs or design docs were added/modified:
   - Do problem statements match actual scale? (don't claim scalability problems for 36 records)
   - Do technical claims hold up? (e.g., "DynamoDB can't do X" — verify)
   - Are alternatives honestly assessed?
   - Do new documentation sections contradict or duplicate guidance in other project docs (`CLAUDE.md`, `docs/guides/`, `.claude/rules/`)? Flag inconsistencies.
   - Does documentation terminology match the actual code/config it describes? E.g., if a doc says "pin a version", verify the code uses an exact version — not a range constraint. Check that imperative guidance sections (playbooks, break-glass) are consistent with the patterns used in implementation sections of the same document.

4. **Test coverage** — are new model methods and handlers covered by tests? Are edge cases tested (empty inputs, concurrent writes, missing entities)? For CDK changes: do modified stacks have template assertions covering the key behavior introduced (execution roles, env vars, IAM policies, resource references)? New infrastructure wiring without assertions is a regression risk.

5. **Boundary parsing safety** — are `JSON.parse()` calls on external data (localStorage, URL params, user input) guarded with try/catch? Flag unguarded parsing at system boundaries.

6. **Test cleanup correctness** — verify that test cleanup/teardown hooks (afterEach, cleanup arrays) reference the entities actually created in each test — not copy-pasted references to unrelated variables. Flag any cleanup that deletes the same ID multiple times or ignores a created entity.

### Step 7: Produce Report

Output a structured markdown report. Save it to `self-review-report.md` in the repo root (gitignored).

```markdown
# Self-Review Report

**Branch:** `<branch-name>`
**Date:** <date>
**Commits:** <count> commits, <files> files changed

## Findings

### Critical (must fix before PR)
- [ ] <finding with file:line reference>

### Warning (should fix or justify)
- [ ] <finding with file:line reference>

### Info (consider for future)
- [ ] <finding with file:line reference>

## Data Flow Analysis

### <Entity Name>
| Write Path | Method | Transactional | Denorm Synced | Notes |
|---|---|---|---|---|
| handler create | `model.create()` | Yes | Yes | |
| migration X | raw `.create()` | No | No | Bypasses model |

### <Entity Name>
...

## API Contract Changes
| Change | Type | Breaking | Consumers |
|---|---|---|---|
| Added `email` query param to GET /contacts | Additive | No | cos-admin-client, cos-backend-test |

## Pattern Deviations
| File | Deviation | Siblings Pattern |
|---|---|---|
| `contact.ts:delete()` | Returns `{ data }` | All others return void |

## Query Efficiency
| Location | Issue | Suggestion |
|---|---|---|
| `handler.ts:93-98` | 2 sequential queries | Use `collections.counterparty()` |

## Documentation
| Doc | Issue |
|---|---|
| EDD-015 | Claims O(n) scalability concern for 36 records |
```

### Step 8: Present and Discuss

Present the report to the user. Ask:
- Which critical/warning items to fix now?
- Which to defer or accept as-is?
- Any findings that are false positives?

Do NOT start fixing anything without user approval.

## Important Notes

- **Read-only until approved** — this skill analyzes and reports. It does not modify code until the user approves specific findings.
- **Scope to the branch diff** — only review code changed on this branch vs main. Don't review the entire codebase.
- **Be specific** — every finding must include a file:line reference and a concrete description. No vague "consider improving X".
- **No false urgency** — classify findings honestly. Not everything is critical.
- **Trust the model layer** — if a write goes through the model class, trust its transactional logic. Focus on paths that bypass it.
