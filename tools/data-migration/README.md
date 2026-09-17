# LicoUp Independent Data Migration CLI (`@licoland/data-migration`)

Independent Node.js tool and library under `tools/data-migration/` for inspecting, planning, converting, and resuming LicoUp application data roots across published format contracts without requiring an installed or running client.

## Core Capabilities

- **`inspect`**: Probes authoritative stores on disk (SQLite databases and JSON schemas), detects actual schema versions across all 12 domains, reads the migration ledger, and identifies discrepancies or pending journals.
- **`plan`**: Computes contiguous forward (upgrade) or backward (downgrade) step edges to reach any published target profile (`v0.1.0` through `v0.3.0` / `latest`).
- **`convert`**: Executes domain-by-domain conversions under an exclusive root lock, journals progress durably, verifies postconditions on actual stores before advancing markers/ledger, and preserves unrepresentable data in isolated recovery extensions.
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
