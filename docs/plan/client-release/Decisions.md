# LicoArc Release Decisions

These owner decisions are normative. They replace conflicting wording from the retired plan tree and are inputs to both release reducers.

## Product and claim boundary

- **D1 — Claim target.** The broad Secure Mesh target is Telegram Secret Chat-level endpoint confidentiality and metadata resistance, expressed only through the product-line claim reducer.
- **D2 — No soft pass.** Missing, stale, projected, partial, preview, or skipped mandatory evidence is a blocking result; aggregate scoring cannot override a failed invariant.
- **D3 — Independent audit.** A cryptographic audit begins only after feature completeness and remains mandatory before the broad product-line claim.
- **D4 — Two verdicts.** A selected-target client release and the five-platform product-line security claim are independent verdicts. A narrower release never promotes the broader claim.
- **D5 — Verify before send.** A peer must have a current, locally authorized trust record before protected work can be sent.
- **D6 — Metadata is in scope.** Stable business identifiers, payload class, operation identity, and protected routing context belong inside authenticated encryption; only documented transport residuals may remain observable.
- **D7 — Classical claim only.** Post-quantum setup or ratchet claims require a separate future contract and cannot be inferred from this plan.
- **D8 — MLS and real Key Transparency.** Production group messaging and a pinned external transparency authority are mandatory for the broad claim.

## Platform and capability boundary

- **D9 — Optional external services.** Optional providers and services are disclosed through the support matrix and do not become release blockers unless selected as required capabilities.
- **D10 — Client-owned acceptance.** LicoArc owns exact-artifact client acceptance and may use a local adversarial opaque relay for deterministic tests; server policy authority remains outside this repository.
- **D11 — Capability closure.** Local security is an acyclic dependency closure over measured facts, not a fixed ordinal security level.
- **D12 — No cryptographic downgrade.** Required E2EE never falls back to plaintext. Without an acceptable persistent store, secrets are memory-only and restart requires re-pair or rekey.
- **D13 — Deferred voice.** Voice input remains an honestly disclosed deferred feature and is not part of the current E2EE or selected-target release blocker set.
- **D14 — Initial topology.** The first selected-target Secure Mesh topology contains three isolated Linux nodes, one macOS node, and one authorized physical Android node. It proves interoperability only; production signing, publication, and update receipts are separate.

## Release authority

- **D15 — Exact artifact.** Build, architecture, signing, install, launch, publication, download, update, rollback, privacy, and support receipts must name the same immutable artifact digest and source lineage.
- **D16 — Physical and external work.** Device authorization, signing, notarization, store publication, independent audit, and trusted external Key Transparency evidence remain pending until performed through their real authorities. Mocks and local identities do not substitute.
- **D17 — Complete migration.** Once a replacement authority is established, the superseded schema, bridge, path, compatibility branch, test fixture, wording, and gate are removed in the same delivery.
- **D20 — Mobile simulator build closure.** The current local Android and iOS app-build verdict is closed on repository-owned Android Emulator and iOS Simulator runs that bind one source snapshot to build, install, launch, native FFI and simulated authorization results. This verdict is deliberately narrower than physical-device custody or production release. Hardware-backed Android Keystore, iOS Keychain/Secure Enclave, real biometrics, physical cross-device encryption, signing and store distribution remain explicit blocked inputs and cannot be promoted by simulator evidence.
- **D21 — Adapter-subset release.** Client release readiness does not require every packaged agent adapter to be ready. Only adapters declared supported may enable send or appear as supported conversation targets; every other adapter remains disabled with its exact blocked, failed, history-only or unverified reason. Zero ready adapters means the release makes no agent-send claim and disables send entry points, but it does not by itself block packaging of the rest of the client.

## Agent conversation attach

- **D18 — OpenClaw Gateway-native.** OpenClaw conversation continue attaches to a Gateway WebSocket endpoint. Prefer reuse of a healthy vendor default on loopback port 18789 (status/install). Never bind or steal 18789 for Arc-owned starts; Arc fallback uses an uncommon reserved port with conflict detection. ACP stdio is the attach bridge, not a Gateway-less cold-start authority.
- **D19 — Copilot native-first continue.** Prefer Copilot CLI/SDK session-state for identity and cleanup. Never use `--continue` for Arc exact continue (newest-only). Treat argv `--resume=<id>` + `-p` as non-preferred (session id and prompt on argv). Keep ACP as a thin turn/stream bridge only when the SDK turn lane is unavailable; do not expand ACP-specific protocol investment. `sendEnabled` stays false until native-first stream + exact-id follow-up evidence lands.
