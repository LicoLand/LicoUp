# iOS Release Evidence

## Closed shared-source evidence

- The iOS client uses the shared Rust protocol core and opaque Swift callback boundary; shared cryptographic behavior is covered by Secure Mesh 302, native library 832, CLI 13, and integration 22 passing tests.
- The current product contract separates simulator build/FFI proof from physical Keychain, Secure Enclave, and biometric custody claims.
- Architecture, Better Plan, and client-boundary gates pass; Flutter analysis reports 0 issues.

## Closed local iOS Simulator receipt

An independent canonical verifier built and immutably staged the exact Apple-silicon simulator app from frozen source, bound source/toolchain/bundle/profile/native-library facts and artifact identity, installed and launched it on a repository-selected iOS Simulator, and exercised the Swift/Rust FFI lifecycle.

The receipt separates its functional harness from the exact release artifact, derives callback support from measured capability facts, and covers simulated authorization success, denial, cancellation, background access, capability change, expiry, deletion, and memory-only fallback. Immutable staging and controlled ancestors fail closed against link or escape attempts. The receipt contains no simulator identifier.

## Remaining physical blockers and channel guidance

- Real Keychain and Secure Enclave custody, non-exportability, accessibility class behavior, and Face ID or Touch ID user presence require an authorized physical device.
- Cross-device encryption and pairing require authorized physical endpoints and the external protocol evidence selected by the parent plan.
- Distribution identity, production signing, TestFlight/App Store publication, public store download, update continuity, and rollback remain unavailable channel guidance only; they do not block development or GitHub Release. Entitlements required by client security or functionality remain part of the artifact checks independently of store identity.
- External KT gossip/witness and independent cryptographic audit remain required for any broad product-line security claim.
