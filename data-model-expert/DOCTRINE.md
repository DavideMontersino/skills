# STX Data-Modeling Doctrine

Distilled from the COS (Counterparty Ontology Service) and TLS (Trade Management) models in
`core-services`. **The live repo wins:** `.claude/rules/{dynamodb,typespec}.md` and the
relevant EDDs/RFCs override this file on any specific. Use these principles as the default
checklist and cite them by number in reviews.

The throughline: **keep the model generic so it absorbs new requirements additively, and
push variability out of the schema into data and the application layer.**

---

## 1. Generic over polymorphic
One flexible entity with a **coded discriminator**, not per-variant entities or a
discriminated union.
- **Example:** a single `BankAccount` with `accountIdentificationScheme: Iban | Other` +
  optional per-scheme fields — replacing five corridor-specific account entities.
- **Example:** `Approval` rows distinguished by an orthogonal `gate` (Compliance / Trade /
  Invoice / KYC), not separate approval types.
- Which fields are **required per variant** is enforced in the **application layer**, not in
  the JSON/TypeSpec schema. The schema stays broad; onboarding a new variant adds no new
  entity and no emitter workaround.
- **No duck typing.** The discriminator is an **explicit field** carrying the kind (e.g.
  `accountIdentificationScheme`, `gate`). Never infer an entity's kind from the
  presence/absence of optional fields — consumers branch on the discriminator value, not on
  field shape. Two rows with the same populated fields but different intent must be told
  apart by the discriminator, not by inspection.
- **Anti-pattern to flag:** new entity per kind; discriminated-union APIs that force client
  narrowing; inferring kind from which fields are populated (duck typing).

## 2. Junctions on ElectroDB collections (M:N)
Model many-to-many with a **minimal junction entity** on a shared **collection**, so one
query hydrates the parent + all attachments in a single round-trip.
- Master entity (`Tag`, `Group`, `Location`) is independent with its own primary + name GSI.
- Junction (`CounterpartyTag(counterpartyId, tagId)`, `CounterpartyGroup`) carries only the
  composite IDs + timestamps + minimal relationship metadata.
- Put one index on the parent side (collection: `"counterparty"`) and a **reverse index** on
  the other side (collection: `"tag"`/`"group"`) for bidirectional lookup.
- The generic trio — **`group` / `tag` / `relation`** — covers most categorization and
  association needs without bespoke entities. `relation` (e.g. `Parent`,
  `FinancialGuarantor`) is a first-class entity with `type` + validity, not a junction.

## 3. Open-ended attributes via property collections (EAV)
For the long tail of optional attributes, use a **property collection with a typed-value
union**, not a sprawl of nullable scalars.
- **Example:** `ContactProperty(contactId, propertyId)` with `value` ∈
  {String200, String800, Boolean, Int64, UtcDateTime}; `name` is the attribute key
  (title, fax, website…). TLS `Product` → `Property` is the same pattern.
- New attributes need no migration; valid keys per context are app-validated.
- **Anti-pattern to flag:** adding yet another nullable scalar column for a rare attribute.

## 4. Deterministic IDs for external sync
When an entity maps to an external system's identifier, derive the local ID
**deterministically** so reverse lookup is idempotent and needs no global-uniqueness
constraint.
- `referenceId = UUIDv5(name + value)` for `Reference` / `ContactReference` /
  `BankAccountReference` (e.g. `name = "datahive:counterpartyId"`).
- Normalized hashes (`BankAccount.accountNumberHash = UUIDv5(normalized number)`) back a
  **candidate-set** GSI — values aren't globally unique, so it's a lookup aid, not a constraint.
- Lets DataHive/Dynamics re-sync idempotently with no server-side dedupe.

## 5. Validity windows, never delete
Temporal/financial data uses `validFrom` / `validTo`; deactivate by setting `validTo`,
never delete the row. Current state is **derived at read time** (`validFrom ≤ now <
validTo`), **not stored as a precomputed flag**.
- Applies to accounts, approvals, relations, locations, contact roles. Both `Approval` and
  `Relation` use the window — **cross-check a new temporal entity against these live siblings**,
  not just this doctrine.
- A `status` enum, if present, is a **denormalized convenience over the window, never the
  source of truth.** "Expired" = `validTo` in the past, derived at read. Use the far-future
  sentinel `9999-12-31T23:59:59Z` for an open-ended (no-expiry) window.
- **Anti-pattern to flag:** a `status: Active|Expired`-style flag used *as* the validity
  carrier (no window). It makes lapsing depend on someone pushing an update, can't answer
  "valid as of date X", and tends to drop the signed/effective dates the requirement named.
- **Rationale is current-state hygiene, not local audit.** A read-projection or TLM-mediated
  domain service (e.g. COS) holds *current state only*; its change history is owned by the
  source-of-record / TLM (ADR-022), not duplicated here. "Never delete" keeps the derived current
  state clean and consistent with siblings — don't justify it as projection-side audit. Once the
  window exists, "delete on expiry" disappears (just bound `validTo`); reserve `DELETE` for
  correcting an erroneous write. **This TLM-ownership is not a blanket** — a service that is
  itself the source-of-record for its data, with a first-class version/history access pattern,
  keeps its own history (§15).

## 6. Additive & backward-compatible evolution
Evolve by **adding**, never by repartitioning or removing.
- No entity removed, no key/partition change, no breaking field change.
- New requirements → new entities/fields written alongside the old (e.g. scoped contacts
  added beside un-scoped ones).
- **In review, a breaking change is a Must-fix** unless an explicit migration + dual-write
  plan is presented.

## 7. Bounded aggregates; indexes are earned
Collections are sized for **O(hundreds)** rows per parent (e.g. ≲20 accounts, ≲10 approvals
each). **Client-side filtering on the loaded aggregate** is the deliberate default.
- Add a new GSI **only** when a bound is genuinely exceeded — and say so explicitly with the
  expected cardinality. Premature GSIs are a cost/complexity smell to flag.

## 8. App-layer validation, not schema constraints
Referential integrity and uniqueness are **not** enforced by the data model.
- Upstream systems + application logic enforce cross-entity constraints.
- Where uniqueness matters, achieve it via a **deterministic ID** (§4), not a unique-key
  constraint.

## 9. Labeled preferences over boolean columns
When "preferred/primary" depends on context, use a **`labels: String64[]`** with a
conventional label (e.g. `"primary"`) on the **context-scoped row**, not a per-context
boolean column.
- **Example:** `BankAccountApproval.labels = ["primary"]` means "preferred account for this
  (payee, currency-set)" — context is already in the row's key.
- Open-ended, data-driven; avoids N booleans as contexts multiply.

## 10. Namespaced conventions over hard schemas
Free-form string fields carry a **namespace convention** instead of a closed enum when
external taxonomies vary.
- **Example:** `role` is `String64`; platform-scoped roles are prefixed `system:` (e.g.
  `"datahive:routing:sendInvoice"`); a `:` means platform-scoped, otherwise it's a business
  role ("AP", "Treasury"). Enables idempotent platform sync without a global role schema.

## 11. TypeSpec is the single source of truth
Model in `.tsp`; **never hand-edit generated `build/*`.** One change fans out via emitters
to ElectroDB/DynamoDB, OpenAPI (+ TS client), Zod, OpenSearch, and GraphQL.
- Decorators: `@entity("<name>","<service>")`, `@index("<name>", { pk, sk, collection?,
  index? })`, `@key`, `@visibility(Lifecycle.Read|Create|Update)`, `@createdAt`/`@updatedAt`
  on `int64`, and search decorators `@searchable`/`@keyword`/`@sortable`/`@searchInfer`/`@searchAs`.
- **Spread (`...Fields`), not `extends`** — `@index` must reference **own** properties;
  inheritance doesn't yield own properties and breaks the emitter.
- Reuse shared scalars/models from `typespec/lib/common.tsp` (`UUID`, `String64/200/400/800`,
  `CountryCode`, `CurrencyCode`, `Address`, `PersonRecord`, …) and shared enums from
  `typespec/lib/enum/`.
- Regenerate via `make typespec` or the specific `make build/<svc>-*` targets; consume the
  published `@stxgroup/*` packages, not `build/`.

## 12. Name for the right abstraction
**Obsess about naming.** A name is part of the contract: TypeSpec fans out to
OpenAPI/Zod/GraphQL, so a rename is a **breaking change** (ties to §6). Bad names calcify.
- **Discover before coining.** Run a discovery session (the `discovery` skill) to surface
  established **industry / domain terminology**, regulatory taxonomy (ISCC, EU ETS, GO,
  biofuels terms), and analogous internal models *before* inventing a term. Prefer the
  standard name over local jargon.
- **Name the abstraction, not the first instance.** Name the generic concept (`relation`,
  `property`, `gate`, `tag`) that will absorb future variants — not the one variant that
  prompted the model. A name scoped to today's instance forces a rename tomorrow.
- **Reuse existing vocabulary** from `lib/common.tsp` and `lib/enum/` before introducing a
  new term; align with the names already used by sibling entities.
- **In review, a name that misleads about the abstraction, diverges from the domain
  standard, or leaks an instance into a generic concept is a finding** (cross-ref §1, §6).

## 13. Separate the fact from the capability (documents & blobs)
Don't fold a **cross-cutting capability** into the business entity that first needs it.
A signed document, an attachment, a blob is a *capability* (storage + access), orthogonal to
the fact it hangs off.
- **Model the fact; reference the document.** The business entity (e.g. a `GeneralAgreement`)
  carries the fact + validity (§5); the document is a **generic, referenced entity** reusable
  across parents (contacts, bank accounts, agreements) — not per-consumer `documentName` /
  `documentRef` scalars re-invented on each entity.
- **Pointer shape:** deterministic id (§4); an `s3://bucket/key` uri (reuse the repo's URI
  parser, don't hand-split into bucket/key fields); a **separate `versionId`** for
  signed/immutable blobs (the uri can't carry it); filename + content-type.
- **Embed vs first-class.** Embed a pointer *only* when it is immutable, atomically-read, and
  bounded to one (`dynamodb.md`). The moment it can grow (amendments, annexes) or a second
  entity needs documents → promote to a **first-class generic entity** keyed in the parent
  collection (`Document(parentId, documentId)` + a `byDocumentId` reverse GSI). Embedding is a
  stated YAGNI, named so promotion stays additive (§6).
- **Access is its own concern.** Presigned-URL minting / cross-account S3 grants are a generic,
  **separately-security-reviewed** capability — isolate them in their own phase, and prefer the
  document's **owner** (source system) to serve bytes; a read-projection should not acquire
  blob-access IAM just because one entity needs it. Reuse existing helpers (presign util, the S3
  store abstraction) rather than reinventing (§ guardrail: don't reinvent).
- **Anti-pattern to flag:** document/blob storage+access fields baked onto a business entity;
  a presign endpoint scoped to one entity type; bucket/key/version packed into one string.

---

## 14. Idempotent upsert (sync ergonomics)
For entities external systems re-sync frequently, prefer **`PUT`/upsert** semantics on an
identity-only key (no version field) so retries refresh validity windows instead of
conflicting (e.g. `CounterpartyContactScoped` keyed by
`(counterpartyId, forCounterpartyId, contactId, role)`). Strict create-only (`POST`) is the
exception, not the default, for platform-synced data.
- **Idempotent ≠ order-safe.** A blind `put` safely absorbs *re-delivery of the same* event,
  but lets a *stale/replayed earlier* event overwrite newer state. If the entity carries an
  `originOccurredAt`/source timestamp, **guard the write** (apply only when
  `originOccurredAt ≥ stored`) so out-of-order pushes can't regress state.

## 15. History & audit: ownership and access pattern decide who keeps it
Whether change history / audit belongs to the data model or to TLM is **not a blanket rule** —
decide it per entity on two axes: **ownership** and **access pattern**.
- **Default (ADR-022):** a service holding **TLM-mediated domain state** (COS counterparty, CIS
  certificate, TLS trade fields) keeps **current state only**. Decision/actor audit ("who
  changed what, when, why") and as-of / temporal queries are **TLM's** — because TLM is the
  single write actor (ADR-021): the core service is SigV4-only, never sees the human, and a
  client-supplied actor is spoofable; two audit trails for one decision drift.
- **Exception — the source-of-record keeps its own history.** When the service *originates and
  owns* the data (not a projection) **and** retrieving a prior state is a **first-class domain
  access pattern** — version fetch, rollback, immutable legal/audit evidence — rather than a
  who-did-what reconstruction, history/versioning lives in the model. **Example:** the TAS
  (Trade Artifact Store) RFC owns full **immutable per-artifact version history**, retains
  superseded bytes for rollback/evidence, and an **append-only processing-error trail** — the
  versions *are* the evidence and "fetch prior version" is a core requirement, so ADR-022 does
  not push this to TLM.
- **Two different "histories" — don't conflate them.** (a) **content/version history + processing
  outcomes** → owned by the source-of-record; (b) **human-actor decision audit + as-of temporal
  queries** → TLM's. ADR-022 governs only (b).
- **Decision test** — two questions: **Ownership** — source-of-record, or read-projection /
  current-state cache of TLM-mediated state? **Access pattern** — is reading a prior state a
  first-class domain read (version fetch, rollback, immutable evidence), or an as-of /
  who-changed reconstruction? *Source-of-record + first-class history read* → **model keeps it**.
  *Projection + actor/as-of audit* → **TLM**.
- **In review, don't reflexively flag local history/versioning as an ADR-022 violation** — apply
  the test first. It's a must-fix only when a TLM-mediated projection reproduces decision/actor
  audit or an as-of history endpoint it doesn't own (cross-ref §5, §13).
