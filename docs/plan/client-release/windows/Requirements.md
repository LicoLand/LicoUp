# Windows Release Requirements

Upper constraint: [`../../product-scope/Requirements.md`](../../product-scope/Requirements.md). This child owns Windows adaptation and delivery only within the canonical product scope.

### REQ-WIN-001 — Independent x64 and arm64 artifacts

Windows x64 and arm64 are separate catalog targets with target-owned builders. PE machine type, bundled DLLs, native CLI, module profile, source revision and artifact digest are verified for each. Host-built projections and one architecture relabeled as another fail closed.

### REQ-WIN-002 — Native authorization and opaque custody

Credential and key operations use DPAPI, Windows Hello or the declared native secure-key mechanism through one user-authorized workflow and opaque handles. Secrets do not enter process arguments, generic bridges or logs. Unavailable protected persistence becomes explicit memory-only custody, and delete is real.

### REQ-WIN-003 — Atomic installer, state and launch

Install, update, rollback, export and skill operations enforce no-follow containment, owner checks, private journals and crash-consistent atomic replacement. A clean Windows target installs and launches without source-tree state and truthfully reports capability blockers.

### REQ-WIN-004 — Secure Mesh acceptance and optional channel status

Each exact architecture artifact independently passes its required install, launch, privacy, and Secure Mesh acceptance. Missing Windows protocol/security evidence blocks the broad product-line claim. When a Microsoft Store or other Windows production channel is requested, Authenticode signing, publication, download, update, and rollback evidence determines only that channel's status; its absence does not block development, ordinary builds, client functionality, or GitHub Release. Public records retain only the artifact digest and minimum signature/attestation verification material, never publisher-account or stable certificate identity.
