# Windows Release Requirements

### REQ-WIN-001 — Independent x64 and arm64 artifacts

Windows x64 and arm64 are separate catalog targets with target-owned builders. PE machine type, bundled DLLs, native CLI, module profile, source revision and artifact digest are verified for each. Host-built projections and one architecture relabeled as another fail closed.

### REQ-WIN-002 — Native authorization and opaque custody

Credential and key operations use DPAPI, Windows Hello or the declared native secure-key mechanism through one user-authorized workflow and opaque handles. Secrets do not enter process arguments, generic bridges or logs. Unavailable protected persistence becomes explicit memory-only custody, and delete is real.

### REQ-WIN-003 — Atomic installer, state and launch

Install, update, rollback, export and skill operations enforce no-follow containment, owner checks, private journals and crash-consistent atomic replacement. A clean Windows target installs and launches without source-tree state and truthfully reports capability blockers.

### REQ-WIN-004 — Production signature, publication and E2EE

Each exact architecture artifact is Authenticode-signed by the production authority, published and downloaded through the declared channel, then passes install, launch, update, rollback, privacy and Secure Mesh acceptance. Missing Windows evidence blocks the broad product-line claim.

