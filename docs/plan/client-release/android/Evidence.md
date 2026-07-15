# Android Release Evidence

## Closed in current source

- The Android arm64 target is selected explicitly and the acceptance topology binds any required companion CLI to the same checkout. The shared lineage suites pass: receipt 28, target 6, schema 18, acceptance 43, artifact I/O 31, dependency 2, package 17, and closure writer 14.
- The persistent key-policy candidate set contains only device-credential and/or strong-biometric authorization. When neither is available, selection is empty and custody is explicit memory-only; there is no unauthenticated persistent fallback.
- Runtime diagnostic evidence is redacted, atomic, bounded, and pruned. It omits device identity and secret material.
- Shared cryptographic behavior is covered by Secure Mesh 302, native library 832, CLI 13, and integration 22 passing tests.
- An independent release build completed two clean Android arm64 builds from one stable source state. The unsigned APK payload, ZIP directory, Signing Block length, signer and all checked binary facts matched. Only randomized cryptographic Signing Block bytes varied. The final single signed APK digest matched both build and distribution manifests; the APK verifier and pinned release-toolchain self-test passed.

## Closed local Android Emulator receipt

An independent canonical verifier built and immutably staged the exact APK from the frozen source, bound source/toolchain/ABI/profile/native-library facts, installed and launched it on a repository-selected Android Emulator, exercised the native bridge and FFI, and recorded simulated authorization outcomes. The functional harness and exact release artifact are represented separately, and repeat-run staging rejects unsafe replacement. The receipt contains no emulator identifier.

This simulator receipt proves build, install, launch, FFI shape, lifecycle, immutable artifact identity, and simulated policy outcomes only. It is not evidence of a physical Keystore property.

## GitHub Release artifact boundary

The GitHub Release path uses an ephemeral local-integrity key, not a store or publisher identity. The publisher re-extracts the signer certificate from the final downloaded APK Signing Block, matches it to the public verification certificate, validates the exact checksum and consumer manifest, and publishes only the accepted artifact plus minimum consumer-verification metadata. The temporary private key is destroyed and never uploaded.

No Android store channel is currently requested. Production signing, protected publication, store download, update continuity and rollback therefore remain non-blocking guidance rather than missing GitHub Release inputs.

## Remaining physical blockers and channel guidance

- Real Android Keystore, StrongBox or TEE custody, non-exportability, device credential, and biometric user-presence behavior require an authorized physical phone.
- Cross-device encryption and pairing require authorized physical endpoints and the external protocol evidence selected by the parent plan.
- Production signing, protected publication, public store download, update continuity, rollback, and store authority remain unavailable channel guidance only; they do not block development or GitHub Release.
- External KT gossip/witness and independent cryptographic audit remain required for any broad product-line security claim.
