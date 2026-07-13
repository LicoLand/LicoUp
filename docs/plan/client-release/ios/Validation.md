# iOS Validation

1. Build from a clean pinned toolchain and verify the Apple-silicon simulator architecture, bundle id, entitlements, native libraries, profile, source revision and digest; install and launch the exact artifact on a fresh iOS Simulator.
2. Run Swift/Rust FFI tests and simulator LocalAuthentication/Keychain lifecycle cases for success, denial, cancellation, background access, capability changes, expiry, delete and memory-only fallback. Keep Secure Enclave, real Keychain custody and physical biometrics blocked.
3. Sign and publish the same digest through the authorized TestFlight/store channel; download, install, launch and verify update/rollback continuity.
4. On an authorized physical device, run pairwise, trust-change, restart and privacy-safe runtime acceptance against the shared protocol core.
5. Bind parent architecture/shared Node ids, target, source revision, artifact and evidence digests; run final privacy and Better Plan validation.

REQ-IOS-001 local app-build closure is proven by step 1; REQ-IOS-002 FFI and fail-closed behavior by step 2 while physical custody stays blocked; REQ-IOS-003 by step 3; REQ-IOS-004 by step 4.
