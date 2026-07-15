# iOS Release Requirements

### REQ-IOS-001 — Real iOS builder and simulator artifact

A pinned Xcode/Flutter toolchain builds a declared Apple-silicon iOS Simulator artifact whose bundle id, entitlements, architectures, native libraries, module profile, source revision and digest are verified. The current local app-build verdict installs and launches this exact artifact on a fresh repository-selected iOS Simulator. A device catalog entry without a physical builder remains unsupported and fail-closed.

### REQ-IOS-002 — Keychain, LocalAuthentication and FFI truth

Swift and Rust share one typed capability and authorization contract. Keychain operations use a LocalAuthentication context for the user workflow, return opaque handles, and expose measured capability facts. Unsupported callbacks, denial, cancellation and unavailable presence fail closed or use explicit memory-only custody; a projected `supported` value is not proof.

Simulator validation proves FFI shape, lifecycle and simulated authorization outcomes only. Real Keychain/Secure Enclave custody and physical Face ID or Touch ID remain blocked inputs.

### REQ-IOS-003 — Optional platform-channel status

When TestFlight or App Store distribution is requested, the exact artifact is signed by that channel's Apple distribution authority, published, downloaded, installed, launched, and verified for its update and rollback continuity. Missing identity or channel evidence makes only that channel unready; it does not block development, ordinary builds, client functionality, or GitHub Release. Public records retain only the artifact digest and minimum signature/attestation verification material, never publisher-account, team, or stable certificate identity.

### REQ-IOS-004 — Physical Secure Mesh acceptance

An authorized physical device proves install, launch, native custody, pairwise messaging, trust changes and privacy-safe runtime against the same shared protocol source and artifact digest. Missing physical or external evidence remains pending.
