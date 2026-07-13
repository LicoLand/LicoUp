# Android Validation

1. Build twice from clean source with the pinned toolchain and explicit `android-arm64` selection; verify ABI, manifest, native libraries, profile and digest lineage.
2. Run Keystore/BiometricPrompt policy and bridge cases for authentication success, denial, cancellation, lockscreen absence, capability change, background access, delete and restart. On the emulator these are simulated authorization checks; prove no authenticated-capable environment silently selects unauthenticated persistence. Keep hardware-backed custody and real biometric proof blocked for an authorized physical device.
3. Start production mode with diagnostic canaries and prove no file is created by default; test consent, bounds, retention and deletion for the opt-in path.
4. An independent verifier creates or resets the repository-selected Android Emulator, installs the freshly built artifact, launches it, exercises the native bridge and records a redacted simulator-build receipt. A separate physical-device verifier owns hardware-backed custody and cross-device encryption; missing or unauthorized hardware remains a blocked external criterion.
5. Production-sign and publish the same digest through the authorized channel, download it, verify signature, install, update and rollback continuity, then run the final privacy scan.
6. The child reducer binds the parent architecture/shared Nodes, exact target, source revision, artifact and evidence digests.

REQ-AND-001 policy and fail-closed behavior are proven by step 2 while its hardware facts remain blocked; REQ-AND-002 local build closure by steps 1 and 4; REQ-AND-003 by step 3; REQ-AND-004 by step 5.
