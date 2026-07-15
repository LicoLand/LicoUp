# LicoArc Release Decisions

These owner decisions are normative. They replace conflicting wording from the retired plan tree and are inputs to the independent release and claim reducers.

## Product and claim boundary

- **D1 — Claim target.** The broad Secure Mesh target is Telegram Secret Chat-level endpoint confidentiality and metadata resistance, expressed only through the product-line claim reducer.
- **D2 — No soft pass.** Missing, stale, projected, partial, preview, or skipped mandatory evidence is a blocking result; aggregate scoring cannot override a failed invariant.
- **D3 — Independent audit.** A cryptographic audit begins only after feature completeness and remains mandatory before the broad product-line claim.
- **D4 — Three verdict classes.** GitHub Release readiness, each named platform/store publication status, and the five-platform product-line security claim are independent. A store-channel failure cannot block GitHub Release, and a narrower release never promotes the broader claim.
- **D5 — Verify before send.** A peer must have a current, locally authorized trust record before protected work can be sent.
- **D6 — Metadata is in scope.** Stable business identifiers, payload class, operation identity, and protected routing context belong inside authenticated encryption; only documented transport residuals may remain observable.
- **D7 — Classical claim only.** Post-quantum setup or ratchet claims require a separate future contract and cannot be inferred from this plan.
- **D8 — MLS and real Key Transparency.** Production group messaging and a pinned external transparency authority are mandatory for the broad claim.

## Platform and capability boundary

- **D9 — Optional external services.** Optional providers and services are disclosed through the support matrix and do not become release blockers unless selected as required capabilities.
- **D10 — Client-owned acceptance and encryption authority.** LicoArc owns exact-artifact client acceptance and the custom end-to-end encryption protocol (Secure Client Mesh). Encrypted communication is a native Lico Arc capability and does not depend on a relay or gateway server implementation; verification may use a local adversarial opaque relay. Server policy and gateway fabric authority remain outside this repository.
- **D11 — Capability closure.** Local security is an acyclic dependency closure over measured facts, not a fixed ordinal security level.
- **D12 — No cryptographic downgrade.** Required E2EE never falls back to plaintext. Without an acceptable persistent store, secrets are memory-only and restart requires re-pair or rekey.
- **D13 — Deferred voice.** Voice input remains an honestly disclosed deferred feature and is not part of the current E2EE or GitHub Release blocker set.
- **D14 — Initial topology.** The first selected-target Secure Mesh topology contains three isolated Linux nodes, one macOS node, and one authorized physical Android node. It proves interoperability only; platform/store production signing, publication, and update receipts are separate channel guidance and are not GitHub Release inputs.

## Release authority

- **D15 — Exact artifact.** Build, architecture, integrity/authentication metadata, required runtime/security, privacy, and support receipts for a GitHub Release name the same immutable artifact digest and source lineage. Any separately requested platform/store receipt must bind that same digest, but is not a GitHub Release prerequisite.
- **D16 — Physical, protocol, and channel work.** Device authorization, independent audit, and trusted external Key Transparency evidence remain pending security inputs until performed through their real authorities. Signing, notarization, store publication/download, and store update/rollback remain pending only for the named platform/store channel. Mocks and local identities do not substitute for claims in either category.
- **D17 — Complete migration.** Once a replacement authority is established, the superseded schema, bridge, path, compatibility branch, test fixture, wording, and gate are removed in the same delivery.
- **D20 — Mobile simulator build closure.** The current local Android and iOS app-build verdict is closed on repository-owned Android Emulator and iOS Simulator runs that bind one source snapshot to build, install, launch, native FFI and simulated authorization results. This verdict is deliberately narrower than physical-device custody. Hardware-backed Android Keystore, iOS Keychain/Secure Enclave, real biometrics, and physical cross-device encryption remain blocked security inputs and cannot be promoted by simulator evidence. Signing and store distribution remain independently unready channel statuses only.
- **D21 — Adapter-subset release.** Client release readiness does not require every packaged agent adapter to be ready. Only adapters declared supported may enable send or appear as supported conversation targets; every other adapter remains disabled with its exact blocked, failed, history-only or unverified reason. Zero ready adapters means the release makes no agent-send claim and disables send entry points, but it does not by itself block packaging of the rest of the client.
- **D22 — Retired-name state reset.** Persistent user state associated with a retired product name is not migrated. The current client does not discover, import, rename, copy, or translate a retired-name data root or preference namespace; it initializes fresh current-name state. This destructive compatibility boundary is intentional and requires no migration prompt or compatibility gate.

## Agent conversation attach

- **D18 — OpenClaw Gateway-native.** OpenClaw conversation continue attaches to a Gateway WebSocket endpoint. Prefer reuse of a healthy vendor default on loopback port 18789 (status/install). Never bind or steal 18789 for Arc-owned starts; Arc fallback uses an uncommon reserved port with conflict detection. ACP stdio is the attach bridge, not a Gateway-less cold-start authority.
- **D19 — Copilot native-first continue.** Prefer Copilot CLI/SDK session-state for identity and cleanup. Never use `--continue` for Arc exact continue (newest-only). Treat argv `--resume=<id>` + `-p` as non-preferred (session id and prompt on argv). Keep ACP as a thin turn/stream bridge only when the SDK turn lane is unavailable; do not expand ACP-specific protocol investment. `sendEnabled` stays false until native-first stream + exact-id follow-up evidence lands.
