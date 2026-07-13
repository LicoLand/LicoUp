# Android Release Requirements

### REQ-AND-001 — Authorized opaque Keystore custody

Provider credentials and Secure Mesh keys remain opaque to Dart and use Android Keystore with BiometricPrompt or device credential according to an explicit policy. When authentication is available, policy selection cannot silently fall back to an unauthenticated persistent key. When acceptable protected persistence is unavailable, custody is memory-only and restart requires reauthorization or rekey.

### REQ-AND-002 — Deterministic APK and simulator-build evidence

The Android arm64 target is selected explicitly in CI. A clean pinned toolchain builds the exact APK, verifies ABI, manifest, native libraries, module profile and signing policy, and binds a same-source companion CLI only when the acceptance topology requires it. The current local app-build verdict installs and launches that exact artifact on a fresh repository-selected Android Emulator and exercises the native bridge plus simulated device-credential/biometric paths. Physical hardware custody and real-device encryption evidence remain blocked and are produced only by an authorized connected device.

### REQ-AND-003 — Privacy-safe production runtime

Production startup does not append account, relay, pairing, credential-presence, path or device diagnostics by default. User-approved diagnostics have an allowlisted schema, protected location, bounded size and retention, explicit deletion, and a final privacy scan.

### REQ-AND-004 — Signing, publication and update continuity

The exact release APK or approved store bundle is signed by the production authority, published through the declared channel, downloaded, installed, launched and verified for update and rollback continuity. Debug, locally signed and validation artifacts cannot satisfy publication.
