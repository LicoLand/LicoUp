# macOS Release Requirements

Upper constraint: [`../../product-scope/Requirements.md`](../../product-scope/Requirements.md). This child owns macOS adaptation and delivery only within the canonical product scope.

### REQ-MAC-001 — Exact target and artifact lineage

Every declared macOS architecture has one catalog entry and one distribution ZIP containing the expected app and native executable architectures. Build, verification, installation, launch, and consumer-verification metadata bind the same source revision, module profile and artifact digest. A separate named platform/store channel binds its own publication, download, and update receipts without becoming a GitHub Release prerequisite.

### REQ-MAC-002 — User-authorized Keychain custody

Secret and key operations use one LocalAuthentication context and access-control policy bound to the user-initiated workflow. Interaction denial, cancellation, unavailable user presence, background access and session expiry fail closed or select an explicit memory-only strategy. No ordinary keyring fallback may report the protected store available.

### REQ-MAC-003 — Optional platform-channel status

When Developer ID or App Store distribution is requested, the exact artifact is signed, notarized, stapled where applicable, published, downloaded, and verified for that channel's update and rollback continuity. Missing identity or channel evidence makes only that named channel unready; it does not block development, ordinary builds, client functionality, or GitHub Release. Public records retain only the artifact digest and minimum signature/attestation verification material, never publisher-account or stable certificate identity.

### REQ-MAC-004 — Clean install and launch

A clean isolated account or machine installs and launches the downloaded artifact without source-tree state. Startup truthfully reports capability and blocker state, the embedded native CLI matches the artifact architecture and source lineage, and privacy-safe runtime smoke passes.
