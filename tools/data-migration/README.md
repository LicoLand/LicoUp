# LicoUp Independent Data Migration CLI (`@licoland/data-migration`)

Independent Node.js tool and library under `tools/data-migration/` for inspecting, planning, converting, and resuming LicoUp application data roots across published format contracts without requiring an installed or running client.

## Core Capabilities

- **`inspect`**: Probes authoritative stores on disk (SQLite databases and JSON schemas), detects actual schema versions across all 12 domains, reads the migration ledger, and identifies discrepancies or pending journals.
- **`plan`**: Computes contiguous forward (upgrade) or backward (downgrade) step edges to reach any published target profile (`v0.1.0` through `v0.3.0` / `latest`). Stores the probe rejects as `unsupported_state_shape` or `state_newer_than_binary` fail the plan instead of being converted.
- **`convert`**: Executes domain-by-domain conversions under an exclusive tool lock (`client-state/migrations/data-migration.lock`, atomic create with stale-owner reclaim), journals progress durably, verifies postconditions on actual stores before advancing markers/ledger, and preserves unrepresentable data in isolated recovery extensions. The native-owned `admission.lock` is never touched; cross-process lock ordering with a running client belongs to the T08.3 root-access protocol. Refuses to run over an interrupted journal (`migration_interrupted`) — use `resume` first.
- **`resume`**: Recovers and continues interrupted conversions from the progress journal without repeating committed steps or corrupting state.
- **`package`**: Generates standalone distribution artifacts (`.tgz`) and release manifests with SHA256 integrity digests.

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
