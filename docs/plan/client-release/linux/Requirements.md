# Linux Release Requirements

Upper constraint: [`../../product-scope/Requirements.md`](../../product-scope/Requirements.md). This child owns Ubuntu/Linux adaptation and delivery only within the canonical product scope.

### REQ-LIN-001 — Exact Linux tuple lineage

Every declared glibc or musl architecture has one explicit target tuple, builder, archive kind, manifest, native executable set and receipt chain. Direct and VM producers cannot name different archives or manifests for one target. Host, libc, architecture and digest mismatches fail closed.

### REQ-LIN-002 — Secret Service or memory-only custody

Secret Service capability is measured on the target session and used only through opaque handles with the required user interaction. No plaintext file or portable fallback exists. If a suitable service is unavailable, custody is explicit memory-only and restart requires re-pair or rekey.

### REQ-LIN-003 — Bounded install, launch and topology proof

Clean target images install and launch the exact archive with bounded, event-driven smoke tests. The initial Secure Mesh receipt uses three isolated Linux nodes with independent state roots and no shared secret volume, and teardown is deterministic.

### REQ-LIN-004 — Optional platform-channel status

When a package registry or other production Linux channel is requested, the exact artifact is signed or attested as required by that channel, published, downloaded, and verified for its install, launch, update, and rollback continuity. Missing publisher identity or channel evidence makes only that channel unready; it does not block development, ordinary builds, client functionality, or GitHub Release. GitHub Release exposes only the digest and minimum public verification material needed to authenticate the official artifact, not publisher-account or private-channel metadata.
