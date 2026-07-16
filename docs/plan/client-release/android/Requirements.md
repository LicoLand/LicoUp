# Android Release Requirements

Upper constraint: [`../../product-scope/Requirements.md`](../../product-scope/Requirements.md). This child owns Android adaptation and delivery only within the canonical product scope.

### REQ-AND-001 — Authorized opaque Keystore custody

Secure Mesh keys remain opaque to Dart and use Android Keystore with BiometricPrompt or device credential according to an explicit policy. When authentication is available, policy selection cannot silently fall back to an unauthenticated persistent key. When acceptable protected persistence is unavailable, custody is memory-only and restart requires reauthorization or rekey.

### REQ-AND-002 — Deterministic APK and simulator-build evidence

The Android arm64 target is selected explicitly in CI. Two clean pinned builds must produce the same unsigned APK payload, ZIP directory, signing-block size, signer and observable binary facts. A cryptographic signature may legitimately randomize bytes inside the APK Signing Block; that variation is isolated and cannot weaken payload reproducibility. The final single signed APK is then bound by its exact digest, ABI, manifest, native libraries, module profile and signing policy. A same-source companion CLI is required only when the acceptance topology names it. The current local app-build verdict installs and launches that exact final artifact on a fresh repository-selected Android Emulator and exercises the native bridge plus simulated device-credential/biometric paths. Physical hardware custody and real-device encryption evidence remain blocked and are produced only by an authorized connected device.

### REQ-AND-003 — Privacy-safe production runtime

Production startup does not append account, relay, pairing, credential-presence, path or device diagnostics by default. User-approved diagnostics have an allowlisted schema, protected location, bounded size and retention, explicit deletion, and a final privacy scan.

### REQ-AND-004 — Optional platform-channel status

When Google Play or another production Android channel is requested, the exact APK or approved bundle is signed by that channel's authority, published, downloaded, installed, launched, and verified for its update and rollback continuity. Missing production signing or channel evidence makes only that channel unready; it does not block development, ordinary builds, client functionality, or GitHub Release. Public records retain only the artifact digest and minimum signature/attestation verification material, never publisher-account, keystore, or stable certificate identity.
