# macOS Release Requirements

### REQ-MAC-001 — Exact target and artifact lineage

Every declared macOS architecture has one catalog entry and one distribution ZIP containing the expected app and native executable architectures. Build, verification, installation, launch, publication, download and update receipts bind the same source revision, module profile and artifact digest. A local app bundle or validation archive cannot satisfy a production ZIP receipt.

### REQ-MAC-002 — User-authorized Keychain custody

Secret and key operations use one LocalAuthentication context and access-control policy bound to the user-initiated workflow. Interaction denial, cancellation, unavailable user presence, background access and session expiry fail closed or select an explicit memory-only strategy. No ordinary keyring fallback may report the protected store available.

### REQ-MAC-003 — Production identity and channel continuity

The exact distribution artifact is signed with the declared Developer ID identity, notarized, stapled where applicable, published through an approved channel, downloaded, and verified for update and rollback continuity. Local identity and ad-hoc signing are development evidence only.

### REQ-MAC-004 — Clean install and launch

A clean isolated account or machine installs and launches the downloaded artifact without source-tree state. Startup truthfully reports capability and blocker state, the embedded native CLI matches the artifact architecture and source lineage, and privacy-safe runtime smoke passes.

