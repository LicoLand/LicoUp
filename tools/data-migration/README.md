# LicoUp Independent Data Migration CLI (`@licoland/data-migration`)

Independent Node.js tool and library under `tools/data-migration/` for inspecting, planning, converting, and resuming LicoUp application data roots across published format contracts without requiring an installed or running client.

## Core Capabilities

- **`inspect`**: Probes authoritative stores on disk (SQLite databases and JSON schemas), detects actual schema versions across all 12 domains, reads the migration ledger, and identifies discrepancies or pending journals.
- **`plan`**: Computes contiguous forward (upgrade) or backward (downgrade) step edges to reach any published target profile (`v0.1.0` through `v0.3.0` / `latest`). Stores the probe rejects as `unsupported_state_shape` or `state_newer_than_binary` fail the plan instead of being converted. Steps whose move belongs to the client's own owner are planned with `deferredTo: "native-admission"`; a downgrade the tool cannot express is refused before anything is written.
- **`convert`**: Executes domain-by-domain conversions under an exclusive tool lock (`client-state/migrations/data-migration.lock`, atomic create with stale-owner reclaim), journals progress durably, verifies postconditions on actual stores before advancing markers/ledger, and preserves unrepresentable data in isolated recovery extensions. A real conversion requires `--writers-stopped` (or `writersStopped: true`): the tool's lock cannot constrain a program that never heard of it, and only the operator can state that every client and older writer is stopped. `plan`, `inspect`, and `convert --dry-run` stay read-only. Refuses to run over an interrupted journal (`migration_interrupted`) — use `resume` first.
- **`resume`**: Recovers and continues interrupted conversions from the progress journal without repeating committed steps or corrupting state. Also requires `--writers-stopped`.
- **`package`**: Generates standalone distribution artifacts (`.tgz`) and release manifests with SHA256 integrity digests.

## Owner boundaries: what this tool does not perform

A data root has one writer per domain. Two domains publish formats whose moves carry typed semantics this tool does not have, and the tool routes those transitions to the native startup admission instead of fabricating their result:

- **`canonical-conversation`**: the Conversation store imports the legacy projection/group documents through the Conversation owner (provenance, stable source identities, memberships, event parts, runtime bindings) and owns its inner SQLite schema. The tool reads the real store (completion marker, schema version, published shape), reports the domain as `pendingNativeAdmissionDomains`, and leaves the legacy sources untouched for the owner's import. A database that only declares a schema version is refused as `unsupported_state_shape` on both sides.
- **typed strategy-store phases**: the published writer's routing move canonicalizes workflow documents through the workflow compiler and backfills each run's query columns from its snapshot. The tool performs the version move only on a store where all of that is already reflected in the file — the published writer's own schema present, the run table present and backfilled, no documents to canonicalize — and otherwise defers the domain to the native admission, whose open path creates the full schema and performs the typed moves. A store that does not exist is left absent: the owner creates it at the current shape on first open, and the frontier step is reconciled without a file, exactly as the admission does.

`gateway-credential-custody` remains reported as `pendingAuthorizationDomains`: it needs the platform credential bridge and is never fabricated either.

## Published store formats and the conversion graph

The strategy database (`client-state/adaptive-flywheel/strategies.sqlite3`) has
shipped more than one *shape* under a single frontier domain version. Those
shapes are recorded as data in `lib/published-strategy-format.mjs`:

| format | `strategy_meta.version` | domain version | what it is |
| --- | --- | --- | --- |
| `strategy-store-1` | `0`, `1` | 0 | bindings without `ordinal` |
| `strategy-store-2` | `2` | 1 | ordinal bindings |
| `strategy-store-3` | `3` | 2 | canonical workflow routing, run query columns |
| `strategy-store-4` | `3` | 2 | adds `workflow_notice_intents` / `workflow_notice_acceptances` |

A published format is immutable: an entry records what already shipped, a
conversion reads the old shape and writes the next one, and the reader asks the
file what it holds (`sqlite_master`, `PRAGMA table_info`, read-only) instead of
running `CREATE TABLE IF NOT EXISTS` against it. A shape that matches no entry is
refused as `unsupported_state_shape`; a version ahead of this tool as
`state_newer_than_binary`.

The conversion graph is explicit (`STRATEGY_STORE_EDGES`), one successor per
shape, and each edge names its mover:

- `strategy-store-1 → 2` and `2 → 3` are the published writer's own moves. This
  tool performs the ordinal-bindings rebuild (reproducible SQL) and the routing
  version move only where the writer's typed work is already reflected in the
  file; it refuses the rest with `migration_requires_native_admission` so the
  native admission drives the store's own migrations.
- `strategy-store-3 → 4` creates the delivery tables. They are created **empty**
  and the legacy rows are left alone, because the published format's post-commit
  intents recorded no recipient or kind — inventing one would create delivery
  work nobody addressed.

A store-format step is not a frontier step: it does not move the domain version
the ledger records, so the ledger stays exactly what the compiled admission
expects. It is planned into `plan().storeFormatSteps`, journalled under
`journal.storeFormats`, executed under the root lock, and verified by re-reading
the file.

Downgrading out of `strategy-store-4` writes the delivery rows the older shape
cannot express to
`client-state/migrations/recovery/adaptive-flywheel-notice-outbox.json` (with
`fromFormat`, `status: preserved`, and a `truncated` flag) and drops the tables.
Re-upgrading merges them back with `INSERT OR IGNORE`, so an intent or
acceptance recorded while the store was downgraded is never replaced by the
preserved copy.

## Downgrade support: what the tool will and will not do

A downgrade is only offered where the result can be shown to be readable by the
receiver the older version shipped. The tool refuses the rest with
`migration_unsupported_downgrade`, before the journal, the ledger or any store
is touched:

| edge | outcome | evidence |
| --- | --- | --- |
| `strategy-store-4 → 3` (domain 2 → 2, delivery tables) | **converted** | rows the older shape cannot express are preserved in the recovery artifact and merged back idempotently on re-upgrade |
| `strategy-store-3 → 2` (domain 2 → 1, routing) | **converted** | the version-2 writer itself stored `serde_json::to_string(&compiled.definition)` and its reader deserialized `WorkflowDefinition` (`b4777f47^:crates/licoup-native/src/domain/adaptive_flywheel/store.rs`, `register_definition` and the definition load path), and the definition IR has not changed since; the move is the version row alone, with every document and row byte-identical |
| `strategy-store-2 → 1` (domain 1 → 0) with an existing store | **refused** | the version-1 shape has no ordinal bindings and cannot hold the run, event and command tables; expressing the current rows would drop data, and there is no published downgrade or receiver to verify one against |
| any reverse edge over an **absent** store | **converted (no-op)** | absence is a valid state at every domain version |
| canonical Conversation store → legacy projection | **refused** | the tool cannot express a canonical store in the legacy shape; the Conversation owner has no downgrade path in this repository |

A store the tool downgrades by the routing edge is re-upgraded by the published
writer's own routing move (the native admission), because deciding whether a
document still needs canonicalizing is the compiler's call, not this tool's.
`tests/migration-support-matrix.test.mjs` walks every row above and checks that
refusals write nothing at all and deferred stores keep their bytes.

A downgrade is a format move, not a backup: the recovery artifact exists so a
later re-upgrade can merge what the older shape could not hold, not as a restore
point, and it is never read as a substitute for the store. Backups, restores and
the rollback of a released migration are release operations outside this tool.

## Public output

Everything `inspect`, `plan`, `convert` and `resume` print is a public report,
and it carries stable identities only: domain ids, schema versions, step ids,
symbolic codes, and artifact refs that stay inside the data root. The root
itself is reported as the `<data-root>` ref, a failure is published as its
symbolic code plus a message that keeps the domain/step context but never a
stack, a machine path, a stored document value, or credential-shaped text (a
JSON parse error quotes the bytes it choked on, so that part is replaced by
`invalid JSON document`). `package` prints artifact file names relative to the
out dir it was given.

Redaction happens at the emission boundary only. Internal execution, the
migration ledger, the journal, the recovery artifacts and the real store paths
are untouched, so a report can never be confused about which root it describes
while the tool still operates on the root it was given.
`tests/privacy-output.test.mjs` drives every one of those commands against a
synthetic root whose directory name, stored documents and one field carry
canaries, and asserts that no canary, private path, credential-shaped string or
stack frame reaches stdout or stderr.

## Published Profiles

- `v0.1.0` / `v0.1.1` / `v0.1.2`: Legacy pre-SQLite profile with JSON projections (`agent-conversation-projections.json`), unversioned documents, raw array tab orders.
- `v0.2.0`: Initial SQLite profile with `conversations.sqlite3` and schema version 1 across client state.
- `v0.2.1`: Intermediate profile with `adaptive-flywheel` SQLite schema 2.
- `v0.2.2`: Profile with `adaptive-flywheel` SQLite schema 3 (workflow routing).
- `v0.3.0` / `nightly` / `latest`: Current product release contract.

## Recovery and Preservation

When down-converting to an older profile that cannot express certain features (such as rich SQLite conversation execution states or advanced workflow definitions), the unrepresentable data is stored in `client-state/migrations/preservation/<domain>.json`. When the data root is subsequently upgraded back to a capable version, preserved extensions are reconciled and restored.

Domains whose native contract is CurrentOnly (workspace manifest, agent tool allowlist, current view, mobile home layout, skill hub preferences) have no legacy on-disk form: version 0 means the store is absent. Downgrading them removes the document and preserves its full content in the recovery extension; re-upgrading restores it.

## Protected Domains

`gateway-credential-custody` requires platform authentication and the platform owner's credential bridge. The tool never fabricates this domain's marker: planned custody edges are reported in `pendingAuthorizationDomains` (mirroring the native admission boundary's `pending_authorization_domain_ids`) and the domain's store and marker are left untouched.

## Durability and failure windows

Every JSON artifact (ledger, domain markers, journal, preservation records, recovery artifacts) is written as a flushed temporary file plus an atomic rename, with a best-effort directory flush after it; SQLite conversions run in `BEGIN IMMEDIATE` transactions. A process crash therefore leaves the old document or the new one, never a torn one, and an interrupted conversion resumes from the physical state the files actually hold — the journal states what was attempted, the files state what happened. Power-loss durability of the directory entry is best effort on platforms that refuse a directory fsync, and is not claimed beyond that.

Cross-database work is not presented as one transaction: each domain commits its own store, marker and journal step, and the only cross-store obligation the tool records is the published delivery outbox (`workflow_notice_intents`), whose rows are preserved on downgrade and merged back idempotently on re-upgrade.
