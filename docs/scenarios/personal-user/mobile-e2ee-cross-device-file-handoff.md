# Mobile E2EE Cross-Device File Handoff

Status: required plan, not production-complete

This scenario records the mobile-to-mobile file handoff requirement: a user may ask an Android phone to have a desktop agent find a file, receive that file on the Android phone, and forward it to an iPhone. The same substrate must also support iPhone-to-Android and desktop-to-mobile variants. Platform UI and OS storage APIs may differ, but the encryption algorithm, payload schema, state transitions, failure behavior, and relay-visible wire contract must be identical.

## Non-Negotiable Contract

| Area | Requirement |
| --- | --- |
| Shared algorithm | Android, iOS, macOS, Windows, and Linux clients must call the shared Rust Secure Mesh core for E2EE payloads. Kotlin, Swift, and desktop UI code may only bridge platform APIs and must not reimplement protocol algorithms. |
| Relay-visible wire | The relay sees only the six pinned outer envelope fields and transport state. File name, MIME, relative path, destination directory, file bytes, command body, result body, raw keys, and decrypted conversation content never enter the relay-visible wire. |
| Inner encryption | File manifest, file chunks, command payloads, and result payloads remain encrypted end-to-end between sender and receiver endpoints. The relay routes opaque envelopes without opening `encryptedHeader` or `ciphertext`. |
| Key locality | Private keys and content keys stay local to each endpoint. They must not be logged, uploaded, exposed through UI, or passed through Flutter MethodChannel as raw key material. |
| Local command gates | After decrypting a command, the receiving client must enforce its own allowlist, target binding, replay ledger, idempotency, minimum risk class by command kind, and user-confirmation policy. It must not trust server metadata or sender-supplied `riskClass` when that risk is lower than the local minimum for the command kind. |
| Platform secret store | Android uses AndroidKeyStore; iOS uses Keychain plus LocalAuthentication; macOS uses Keychain/LocalAuthentication; Windows uses DPAPI/Windows Hello or PIN-compatible platform APIs; Linux uses the best available local secret-store backend and otherwise reports unavailable. |
| Local unlock | When a protected private key is used, the platform backend requests one OS-owned device-owner authentication flow for the associated top-level workflow: Face ID/Touch ID/PIN on iOS, biometrics/PIN on Android, Touch ID with system-password fallback on macOS, and Windows Hello/PIN on Windows. The app never collects biometric or password data. Associated secret operations and cleanup reuse the bounded authorization context; background polling and automated tests never open a prompt. Missing, cancelled, timed-out, invalidated, or unavailable authorization fails closed and is reported without an automatic interactive retry. |
| Trust and replay | Wrong recipient, changed key, unverified peer, revoked endpoint, replayed command id, duplicate chunk with conflicting hash, expired envelope, and destination-boundary failure must fail closed. |
| Logs and retention | Mobile clients must not persist plaintext logs. Persistent diagnostics must be bounded, redact tokens/keys/payloads, and be automatically pruned by age and count. |

## Required User Flow

1. The user asks a phone client to retrieve a file through a selected desktop agent.
2. The phone sends an encrypted command to the desktop endpoint through Secure Mesh.
3. The desktop endpoint decrypts locally, asks the selected agent to locate or produce the file under local policy, and seals an encrypted file manifest plus encrypted chunks to the phone endpoint.
4. The phone decrypts locally, stores only user-approved local plaintext, and may forward the same file to a second phone by re-sealing a new encrypted manifest/chunk stream for the second phone endpoint.
5. The second phone decrypts locally after local trust/auth policy permits key use.
6. Sender and receiver exchange encrypted receipts. The sender retries ACK idempotently; acknowledged or expired opaque entries leave the active mailbox.

## Current Repository State

| Component | Current state |
| --- | --- |
| Shared payload crypto | `crates/lico-client-native/src/core/secure_mesh_crypto.rs`, `src/core/secure_mesh_pqxdh.rs`, `src/core/secure_mesh_mlkem_braid.rs`, `src/core/secure_mesh_sparse_pq_ratchet.rs`, `src/core/secure_mesh_pairwise.rs`, `src/core/secure_mesh_file.rs`, `src/core/secure_mesh_response.rs`, and `src/domain/mobile_relay.rs` provide the client-owned X25519/Ed25519/ML-KEM-1024 PQXDH and Triple Ratchet, shared Rust payload sealing/opening, encrypted file manifest/chunk codec, command/result envelopes, and pairwise ratchet-derived AEAD content keys. File manifest/chunk relay-visible delivery JSON exposes only opaque hashes, sizes, content type, and sealed ciphertext; tests assert file id, file name, MIME, relative path, and chunk plaintext canaries are absent. |
| Local command gate | `crates/lico-client-native/src/core/secure_mesh_command.rs` enforces command schema, sender identity, trust state, target binding, workspace/agent binding, expiry, replay/idempotency, command allowlist/deny-prefixes, and local minimum risk class. `local_effect` and `high_risk` commands require local user confirmation before execution, and local executor failures are returned with stable redacted error details instead of raw process/path/runtime errors. |
| Local receive destination gate | `crates/lico-client-native/src/core/secure_mesh_file.rs` evaluates the decrypted file manifest against a user-approved absolute receive root before any local write. The decision output exposes only hashes and policy flags, rejects traversal and relative roots fail-closed, and the `secure-mesh file receive-destination` CLI path is covered by redaction tests. |
| Android bridge | Android Kotlin bridges to shared Rust through JNI and MethodChannel for Mobile Relay native JSON. File route, receive-destination, receive-confirmation, transfer lifecycle, and endpoint-specific reseal logic are Rust-owned. The superseded Kotlin Secure Mesh payload codec and its old package path have been removed; Kotlin retains only platform authorization, native invocation, and secure-store custody. |
| iOS bridge | iOS Swift bridges to the same Rust core through C ABI and MethodChannel for status/config/pairing/secure command create/result and shared file route/receive-destination policy evaluation. Swift stores Mobile Relay token/private-key/pairing-secret material in iOS Keychain with `userPresence` and the shared Rust callback secret-store handle account contract, strips caller-supplied `secretOverrides`, passes only opaque `mobileRelayE2eeSecretStore` metadata for E2EE material, and keeps `config.json` redacted before and after operations. Physical iPhone lifecycle proof remains required. |
| File handoff product flow | The shared client implementation now provides a bounded transfer queue, duplicate-safe resume receipts, mandatory receive confirmation before ACK, ACK-gated purge, and independent endpoint-specific reseal for every recipient. Physical phone-to-desktop-to-phone execution remains a release-evidence gate rather than a local implementation gap. |
| Secret-store parity | A shared Rust secret-store abstraction now exists for native desktop backends, AndroidKeyStore/iOS Keychain shared handle accounts, pairwise durable session snapshots, and MLS/recovery provider snapshots, including migration away from inline SQLite secret material and durable plaintext OpenMLS provider files. The broad security claim still requires Android/iOS physical lifecycle proof, Windows DPAPI/Hello-compatible storage, macOS user-presence evidence, and the complete security proof. `mobile.relay.e2ee.status` reports `productionReady=false` when endpoint private key material is only present in portable config and reports readiness only for platform-bound paths without exposing raw key material. Publisher identity and platform/store channel evidence are separate guidance and do not affect this status or GitHub Release readiness. |
| Log retention | iOS and Android runtime/proof diagnostics are bounded and pruned by age/count, but the full mobile diagnostic model still needs no-plaintext verification across every report writer. |

## Implementation Plan

| Step | Deliverable | Acceptance |
| --- | --- | --- |
| 1 | Freeze the reviewed Secure Mesh E2EE protocol contract. | The contract covers SecureEnvelope, pairwise messages, command/result payloads, file manifest/chunks, trust, rekey, revoke, diagnostics redaction, and Telegram Secret Chat lifecycle parity. Stable vectors validate on Rust, Android, iOS, and desktop hosts. |
| 2 | Converge Mobile Relay command/result/file transport on the durable pairwise session runtime. | Production Mobile Relay uses `secure_mesh_pairwise` session envelopes, ratchet lifecycle, replay handling, and durable state. Static endpoint X25519/HKDF envelope derivation is not reachable from production routes. |
| 3 | Ship cross-platform trust verification and key-change UX. | Fingerprint, SAS, QR, recovery, rotation, revoke, and key-change flows exist on desktop and mobile. Unverified, key-changed, or revoked peers fail closed for commands, results, files, prekeys, and group payloads. |
| 4 | Move endpoint and session secrets into the shared Rust secret-store abstraction. | AndroidKeyStore, iOS Keychain plus LocalAuthentication, macOS Keychain, Windows DPAPI/Hello-compatible storage, and Linux supported-or-unavailable behavior are wired through the same Rust contract. Portable config and durable snapshots contain only opaque ids, fingerprints, policy, and non-secret routing state. |
| 5 | Complete the physical cross-platform interoperability matrix. | Physical Android, physical iPhone, macOS, Windows, and Linux verifiers cover the pinned relay protocol and optional LAN/WebRTC transports where supported; handshake, replay, out-of-order recovery, rekey, key-change, revoke, wrong recipient, expired envelope, process restart, and ACK purge all have evidence. |
| 6 | Finish the encrypted phone-to-desktop-to-phone file handoff product flow. | Android-to-desktop-to-iPhone and iPhone-to-desktop-to-Android flows pass with endpoint-specific resealed ciphertext, transfer queues, encrypted receipts, destination confirmation, resume, ACK, and purge. |
| 7 | Close diagnostics, release, and obsolete-path gates. | Every report writer is bounded and no-plaintext; `client:verify:architecture`, `client:verify:secure-client-relay-mock-e2e`, native Secure Mesh tests, platform custody verifiers, signed update, Windows ACL, dependency/advisory, and local-info hygiene gates pass before `productionReady` can become true. Obsolete compatibility code, docs, tests, and gates do not survive the migration. |

## Better Plan Tracking

This scenario is tracked by `docs/plan/client-release/Requirements.md`, `docs/plan/client-release/Validation.md`, and `docs/plan/client-release/Checkpoints.json`. The product security-claim reducer must not claim completion before its cryptographic, platform-security, relay Mock, physical-device, and independent-audit checkpoints close. Platform publisher and store-channel status is not an input to that reducer or to GitHub Release readiness.

## Production Gate

This scenario is not production-complete until all acceptance checks above pass on physical Android and physical iPhone devices. Any platform-specific bridge may differ in OS API calls, but it must expose the same Rust protocol behavior and the same failure semantics.
