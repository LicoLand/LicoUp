import path from "node:path";

export async function checkSecureMeshAuthorityAndCustody(context) {
  const {
    assert,
    collectDartSourceFiles,
    collectEnumValues,
    collectRustPubMods,
    collectRustUnsafeFiles,
    collectSourceFiles,
    exists,
    fail,
    lineNumberForToken,
    moduleSupportsPlatform,
    readDartSourceByBasename,
    readImmediateDirectoryNames,
    readJoinedDartSourcesByBasename,
    readJoinedText,
    readJson,
    readText,
    runJson,
    sameSet,
  } = context;
  const cargoToml = await readText("crates/licoup-native/Cargo.toml");
  const mobileRelayRustSource = await readJoinedText([
    "crates/licoup-native/src/domain/mobile_relay.rs",
    ...await collectSourceFiles("crates/licoup-native/src/domain/mobile_relay", ".rs")
  ]);
  const mobileRelayCommandSyncRustSource = await readText(
    "crates/licoup-native/src/domain/mobile_relay/command_sync.rs"
  );
  const keyTransparencyFacadeSource = await readText(
    "crates/licoup-native/src/domain/mobile_relay/key_transparency.rs"
  );
  const keyTransparencyConfigSource = await readText(
    "crates/licoup-native/src/domain/mobile_relay/key_transparency/config.rs"
  );
  const keyTransparencyPersistenceSource = await readText(
    "crates/licoup-native/src/domain/mobile_relay/key_transparency/persistence.rs"
  );
  const keyTransparencyProjectionSource = await readText(
    "crates/licoup-native/src/domain/mobile_relay/key_transparency/projection.rs"
  );
  const keyTransparencyAuthoritySource = await readJoinedText([
    "crates/licoup-native/src/domain/mobile_relay/key_transparency/authority.rs",
    ...await collectSourceFiles(
      "crates/licoup-native/src/domain/mobile_relay/key_transparency/authority",
      ".rs"
    )
  ]);
  assert(
    keyTransparencyFacadeSource.includes("mod authority;") &&
    keyTransparencyFacadeSource.includes("mod publication;") &&
    keyTransparencyFacadeSource.includes("mod revocation;") &&
    keyTransparencyFacadeSource.includes("mod provision;") &&
    keyTransparencyFacadeSource.includes("mod self_monitor;") &&
    keyTransparencyFacadeSource.includes("mod gossip;") &&
    keyTransparencyFacadeSource.includes("mod status;") &&
    keyTransparencyConfigSource.includes("secret_custody") &&
    keyTransparencyPersistenceSource.includes("ClientStateStore") &&
    keyTransparencyPersistenceSource.includes("file_security") &&
    !keyTransparencyProjectionSource.includes("secret_custody") &&
    !keyTransparencyProjectionSource.includes("ClientStateStore") &&
    !keyTransparencyProjectionSource.includes("save_config") &&
    keyTransparencyAuthoritySource.includes("RESET_KEY_TRANSPARENCY_AUTHORITY") &&
    keyTransparencyAuthoritySource.includes("requires_security_reset ==") &&
    keyTransparencyAuthoritySource.includes("complete_kt_authority_challenge"),
    "key transparency must keep split workflows and one-way fail-closed authority persistence"
  );
  const localMaterialFacadeSource = await readText(
    "crates/licoup-native/src/domain/mobile_relay/endpoint_trust/local_material.rs"
  );
  const localMaterialRustSource = await readJoinedText([
    "crates/licoup-native/src/domain/mobile_relay/endpoint_trust/local_material.rs",
    ...await collectSourceFiles(
      "crates/licoup-native/src/domain/mobile_relay/endpoint_trust/local_material",
      ".rs"
    )
  ]);
  const localMaterialGenerationSource = await readJoinedText([
    "crates/licoup-native/src/domain/mobile_relay/endpoint_trust/local_material/identity_generation.rs",
    "crates/licoup-native/src/domain/mobile_relay/endpoint_trust/local_material/prekey_generation.rs"
  ]);
  const localMaterialMutationSource = await readJoinedText([
    "crates/licoup-native/src/domain/mobile_relay/endpoint_trust/local_material/material_mutation.rs",
    "crates/licoup-native/src/domain/mobile_relay/endpoint_trust/local_material/prekey_inventory.rs",
    "crates/licoup-native/src/domain/mobile_relay/endpoint_trust/local_material/protocol_reset.rs",
    "crates/licoup-native/src/domain/mobile_relay/endpoint_trust/local_material/rotation.rs"
  ]);
  assert(
    localMaterialFacadeSource.includes("mod identity_generation;") &&
    localMaterialFacadeSource.includes("mod material_mutation;") &&
    localMaterialFacadeSource.includes("mod prekey_generation;") &&
    localMaterialFacadeSource.includes("mod prekey_inventory;") &&
    localMaterialFacadeSource.includes("mod protocol_reset;") &&
    localMaterialFacadeSource.includes("mod rotation;") &&
    localMaterialFacadeSource.includes("mod state_codec;") &&
    !localMaterialFacadeSource.includes("fn local_endpoint_state") &&
    !localMaterialRustSource.includes("use super::*") &&
    !localMaterialRustSource.includes("::*;") &&
    !localMaterialRustSource.includes("#[path") &&
    !localMaterialRustSource.includes("include!(") &&
    !localMaterialGenerationSource.includes("&mut Value") &&
    !localMaterialGenerationSource.includes(".insert(") &&
    localMaterialGenerationSource.includes("generate_identity_material") &&
    localMaterialGenerationSource.includes("mlkem_prekey_material") &&
    localMaterialMutationSource.includes("&mut Value") &&
    localMaterialMutationSource.includes("MOBILE_RELAY_E2EE_PROTOCOL_VERSION") &&
    localMaterialMutationSource.includes("prekeyPublicationVersion") &&
    localMaterialRustSource.includes("key transparency response is missing"),
    "local endpoint material must keep generation, mutation, inventory, reset, codec, and projection in separate fail-closed leaves"
  );
  const directoryTransparencyFacadeSource = await readText(
    "crates/licoup-native/src/domain/mobile_relay/endpoint_trust/directory_transparency.rs"
  );
  const directoryTransparencyProductLeaves = [
    "authority.rs",
    "authorization.rs",
    "authorization/exact.rs",
    "authorization/local.rs",
    "authorization/peer.rs",
    "claim.rs",
    "clock.rs",
    "config.rs",
    "ensure.rs",
    "freshness.rs",
    "verifier.rs"
  ];
  const directoryTransparencySources = Object.fromEntries(await Promise.all(
    directoryTransparencyProductLeaves.map(async (leaf) => [
      leaf,
      await readText(
        `crates/licoup-native/src/domain/mobile_relay/endpoint_trust/directory_transparency/${leaf}`
      )
    ])
  ));
  const directoryTransparencyJoinedSource =
    Object.values(directoryTransparencySources).join("\n");
  const directoryTransparencyTestSupportSource = await readText(
    "crates/licoup-native/src/domain/mobile_relay/endpoint_trust/directory_transparency/test_support.rs"
  );
  assert(
    directoryTransparencyFacadeSource.includes("mod authorization;") &&
    directoryTransparencyFacadeSource.includes("mod authority;") &&
    directoryTransparencyFacadeSource.includes("mod claim;") &&
    directoryTransparencyFacadeSource.includes("mod clock;") &&
    directoryTransparencyFacadeSource.includes("mod config;") &&
    directoryTransparencyFacadeSource.includes("mod ensure;") &&
    directoryTransparencyFacadeSource.includes("mod freshness;") &&
    directoryTransparencyFacadeSource.includes("mod verifier;") &&
    !directoryTransparencyFacadeSource.includes("fn ensure_mobile_relay_key_transparency") &&
    !directoryTransparencyJoinedSource.includes("use super::*") &&
    !directoryTransparencyJoinedSource.includes("::*;") &&
    directoryTransparencySources["authority.rs"].includes(
      "SecureMeshDirectoryAuthority::open") &&
    directoryTransparencySources["config.rs"].includes(
      "ensure_no_kt_authority_reset_in_progress") &&
    directoryTransparencySources["config.rs"].includes(
      "canonical lowercase SHA-256 hex") &&
    directoryTransparencySources["clock.rs"].includes(
      "current_secure_mesh_kt_gate_epoch_seconds") &&
    directoryTransparencySources["freshness.rs"].includes(
      "ensure_pairwise_authorization_receipt_current") &&
    directoryTransparencySources["verifier.rs"].includes(
      "DirectoryAuthorizationRequest::for_pairwise") &&
    directoryTransparencySources["verifier.rs"].includes(
      "DirectoryAuthorizationRequest::for_exact_claim") &&
    directoryTransparencySources["verifier.rs"].includes(
      "DirectoryAuthorizationRequest::for_mls") &&
    directoryTransparencySources["authorization/peer.rs"].includes(
      "peer key transparency response is missing") &&
    directoryTransparencySources["authorization/local.rs"].includes(
      "key transparency response is missing") &&
    !directoryTransparencyJoinedSource.includes("ClientStateStore") &&
    !directoryTransparencyJoinedSource.includes("SecureMeshKtLog") &&
    directoryTransparencyTestSupportSource.includes("ClientStateStore::portable") &&
    directoryTransparencyTestSupportSource.includes("local-acceptance-mock"),
    "directory transparency must isolate claims, pin configuration, clocks, verifier, authority, peer/local/exact authorization, and test-only authority state"
  );
  const pairwiseSessionFacadeSource = await readText(
    "crates/licoup-native/src/domain/mobile_relay/pairwise_session.rs"
  );
  const pairwiseSessionLeaves = [
    "crypto_operation.rs",
    "handshake.rs",
    "payload.rs",
    "response.rs",
    "status_projection.rs",
    "store.rs",
    "transaction.rs"
  ];
  const pairwiseSessionSources = Object.fromEntries(await Promise.all(
    pairwiseSessionLeaves.map(async (leaf) => [
      leaf,
      await readText(
        `crates/licoup-native/src/domain/mobile_relay/pairwise_session/${leaf}`
      )
    ])
  ));
  const pairwiseSessionJoinedSource = Object.values(pairwiseSessionSources).join("\n");
  assert(
    pairwiseSessionFacadeSource.includes("mod crypto_operation;") &&
    pairwiseSessionFacadeSource.includes("mod handshake;") &&
    pairwiseSessionFacadeSource.includes("mod payload;") &&
    pairwiseSessionFacadeSource.includes("mod response;") &&
    pairwiseSessionFacadeSource.includes("mod status_projection;") &&
    pairwiseSessionFacadeSource.includes("mod store;") &&
    pairwiseSessionFacadeSource.includes("mod transaction;") &&
    !pairwiseSessionFacadeSource.includes("fn initialize_mobile_relay_pairwise_session") &&
    !pairwiseSessionJoinedSource.includes("use super::*") &&
    !pairwiseSessionJoinedSource.includes("::*;") &&
    pairwiseSessionSources["status_projection.rs"].includes(
      "pairwise_capability_negotiation_missing") &&
    pairwiseSessionSources["response.rs"].includes('"bodyRedacted": true') &&
    pairwiseSessionSources["response.rs"].includes('"replayErrorRedacted": true') &&
    pairwiseSessionSources["crypto_operation.rs"].includes("seal_payload_envelope") &&
    pairwiseSessionSources["crypto_operation.rs"].includes("open_payload_envelope") &&
    pairwiseSessionSources["crypto_operation.rs"].includes("pairwise_operation.commit()?") &&
    !pairwiseSessionSources["crypto_operation.rs"].includes(
      "commit_session_with_authorized_session(") &&
    pairwiseSessionSources["transaction.rs"].includes("fn commit(&mut self)") &&
    pairwiseSessionSources["transaction.rs"].includes(
      "self.record = self.store.commit_session_with_authorized_session(") &&
    pairwiseSessionSources["handshake.rs"].includes("SecureMeshPairwiseSession::accept") &&
    pairwiseSessionSources["handshake.rs"].includes("SecureMeshPairwiseSession::initiate") &&
    pairwiseSessionSources["handshake.rs"].includes(
      "rotate_mobile_relay_one_time_prekeys") &&
    pairwiseSessionSources["store.rs"].includes("ClientStateStore::portable") &&
    pairwiseSessionSources["store.rs"].includes("purge_unrecoverable_memory_only_sessions") &&
    pairwiseSessionLeaves.filter((leaf) =>
      pairwiseSessionSources[leaf].includes("ClientStateStore")).join(",") === "store.rs",
    "pairwise session must isolate status, replay redaction, ciphertext operations, atomic commit, handshake bootstrap, and durable store ownership"
  );
  const relayOperationsFacadeSource = await readText(
    "crates/licoup-native/src/domain/mobile_relay/relay_operations.rs"
  );
  const relayOperationLeaves = [
    "allow_list.rs",
    "command_handlers.rs",
    "command_handlers/check_in.rs",
    "command_handlers/create.rs",
    "command_handlers/poll.rs",
    "command_handlers/result.rs",
    "delivery.rs",
    "envelope.rs",
    "mailbox.rs",
    "station.rs",
    "status.rs"
  ];
  const relayOperationSources = Object.fromEntries(await Promise.all(
    relayOperationLeaves.map(async (leaf) => [
      leaf,
      await readText(
        `crates/licoup-native/src/domain/mobile_relay/relay_operations/${leaf}`
      )
    ])
  ));
  const relayOperationJoinedSource = Object.values(relayOperationSources).join("\n");
  assert(
    relayOperationsFacadeSource.includes("mod allow_list;") &&
    relayOperationsFacadeSource.includes("mod command_handlers;") &&
    relayOperationsFacadeSource.includes("mod delivery;") &&
    relayOperationsFacadeSource.includes("mod envelope;") &&
    relayOperationsFacadeSource.includes("mod mailbox;") &&
    relayOperationsFacadeSource.includes("mod station;") &&
    relayOperationsFacadeSource.includes("mod status;") &&
    !relayOperationsFacadeSource.includes("fn station_context") &&
    !relayOperationJoinedSource.includes("use super::*") &&
    !relayOperationJoinedSource.includes("::*;") &&
    relayOperationSources["station.rs"].includes("BadTowerStationTransport::new") &&
    relayOperationSources["station.rs"].includes("mobile relay is disabled") &&
    relayOperationSources["mailbox.rs"].includes("SecureMeshMailboxSchedule") &&
    relayOperationSources["mailbox.rs"].includes("checked_mul") &&
    relayOperationSources["envelope.rs"].includes("LicoArcRelayEnvelope::from_json") &&
    pairwiseSessionSources["payload.rs"].includes("MOBILE_RELAY_COMMAND_TTL_SECONDS") &&
    pairwiseSessionSources["crypto_operation.rs"].includes("MOBILE_RELAY_COMMAND_TTL_SECONDS") &&
    relayOperationSources["delivery.rs"].includes("SECURE_MESH_ENVELOPE_COMMAND") &&
    relayOperationSources["command_handlers/create.rs"].includes("secure_envelope_param(params)") &&
    relayOperationSources["command_handlers/create.rs"].includes(
      "seal_mobile_relay_payload_deferred") &&
    relayOperationSources["command_handlers/result.rs"].includes(
      "open_mobile_relay_payload_deferred") &&
    relayOperationSources["command_handlers/result.rs"].includes('"bodyRedacted": true') &&
    relayOperationSources["status.rs"].includes("should_authorize_secret_read") &&
    relayOperationSources["status.rs"].includes("redacted_pairing_invite") &&
    relayOperationSources["allow_list.rs"].includes("PACKAGED_RUNTIME_ADAPTER_IDS") &&
    relayOperationSources["allow_list.rs"].includes("runtime.message.send") &&
    !relayOperationJoinedSource.includes("fn execute_command(") &&
    !relayOperationJoinedSource.includes("ureq::") &&
    !relayOperationJoinedSource.includes("reqwest::"),
    "relay operations must isolate ciphertext-only handlers, station context, mailbox, envelope, delivery, status, and allow-list boundaries"
  );
  const secureMeshSecretStoreRustSource = await readJoinedText([
    "crates/licoup-native/src/platform/secure_mesh_secret_store.rs",
    ...await collectSourceFiles(
      "crates/licoup-native/src/platform/secure_mesh_secret_store",
      ".rs"
    )
  ]);
  const secureMeshSecretStoreContractRustSource = await readJoinedText([
    "crates/licoup-native/src/core/secure_mesh_secret_store.rs",
    "crates/licoup-native/src/core/secure_mesh_secret_store/authorization.rs",
    "crates/licoup-native/src/core/secure_mesh_secret_store/handle.rs",
    "crates/licoup-native/src/core/secure_mesh_secret_store/port.rs"
  ]);
  const secureMeshSecretStoreAuthorizationRustSource = await readText(
    "crates/licoup-native/src/core/secure_mesh_secret_store/authorization.rs"
  );
  const macosUserPresenceRustSource = await readText(
    "crates/licoup-native/src/platform/secure_mesh_secret_store/macos_user_presence.rs"
  );
  const platformUserPresenceRustSource = await readText(
    "crates/licoup-native/src/platform/user_presence.rs"
  );
  const secureMeshCapabilityFacadeRustSource =
    await readText("crates/licoup-native/src/core/secure_mesh_capability.rs");
  const secureMeshCapabilityProductionPaths = [
    "crates/licoup-native/src/core/secure_mesh_capability/catalog.rs",
    "crates/licoup-native/src/core/secure_mesh_capability/custody.rs",
    "crates/licoup-native/src/core/secure_mesh_capability/evaluation.rs",
    "crates/licoup-native/src/core/secure_mesh_capability/facts.rs",
    "crates/licoup-native/src/core/secure_mesh_capability/report.rs",
    "crates/licoup-native/src/core/secure_mesh_capability/taxonomy.rs",
  ];
  const secureMeshCapabilityDiscoveredProductionPaths = (
    await collectSourceFiles(
      "crates/licoup-native/src/core/secure_mesh_capability",
      ".rs",
    )
  ).filter((relativePath) => !relativePath.includes("/tests/"));
  const secureMeshCapabilityProductionSources = Object.fromEntries(
    await Promise.all(secureMeshCapabilityProductionPaths.map(async (relativePath) => [
      path.basename(relativePath),
      await readText(relativePath),
    ])),
  );
  const secureMeshCapabilityRustSource = [
    secureMeshCapabilityFacadeRustSource,
    ...Object.values(secureMeshCapabilityProductionSources),
  ].join("\n");
  const secureMeshPrekeyFacadeRustSource =
    await readText("crates/licoup-native/src/core/secure_mesh_prekey.rs");
  const secureMeshPrekeyProductionPaths = [
    "crates/licoup-native/src/core/secure_mesh_prekey/inventory.rs",
    "crates/licoup-native/src/core/secure_mesh_prekey/key_package.rs",
    "crates/licoup-native/src/core/secure_mesh_prekey/pairwise.rs",
    "crates/licoup-native/src/core/secure_mesh_prekey/validation.rs",
  ];
  const secureMeshPrekeyDiscoveredProductionPaths = (
    await collectSourceFiles(
      "crates/licoup-native/src/core/secure_mesh_prekey",
      ".rs",
    )
  ).filter((relativePath) => !relativePath.includes("/tests/"));
  const secureMeshPrekeyProductionSources = Object.fromEntries(
    await Promise.all(secureMeshPrekeyProductionPaths.map(async (relativePath) => [
      path.basename(relativePath),
      await readText(relativePath),
    ])),
  );
  const secureMeshCapabilityProofRustSource =
    await readText("crates/licoup-native/src/core/secure_mesh_capability_proof.rs");
  const secureMeshSessionNegotiationRustSource =
    await readText("crates/licoup-native/src/core/secure_mesh_session_negotiation.rs");
  const coreStateMachinePhysicalTestLayouts = await Promise.all([
    "secure_mesh_session_negotiation",
    "secure_mesh_capability_proof",
    "secure_mesh_sparse_pq_ratchet",
    "secure_mesh_acp",
  ].map(async (moduleName) => ({
    moduleName,
    production: await readText(`crates/licoup-native/src/core/${moduleName}.rs`),
    tests: await readText(
      `crates/licoup-native/src/core/${moduleName}/tests/mod.rs`,
    ),
  })));
  const secureMeshMlsSecurityLedgerRustSource = await readText(
    "crates/licoup-native/src/core/secure_mesh_mls_product/security_ledger.rs",
  );
  const secureMeshMlsSecurityLedgerTestSupportRustSource = await readText(
    "crates/licoup-native/src/core/secure_mesh_mls_product/security_ledger/test_support.rs",
  );
  const secureMeshProtocolStatusRustSource =
    await readText("crates/licoup-native/src/core/secure_mesh.rs");
  const secureMeshCapabilityProbeRustSource =
    await readText("crates/licoup-native/src/platform/secure_mesh_capability_probe.rs");
  const secureMeshCapabilityReportSource =
    await readText("tools/scripts/lib/secure-mesh-capability-report.mjs");
  const macosUserPresenceProofSource = await readJoinedText([
    "tools/scripts/client-secure-mesh-macos-keychain-user-presence-proof.mjs",
    ...await collectSourceFiles(
      "tools/scripts/client-secure-mesh-macos-keychain-user-presence-proof",
      ".mjs"
    ),
  ]);
  const platformSecretStoreMatrixSource = await readJoinedText([
    "tools/scripts/client-secure-mesh-platform-secret-store-matrix.mjs",
    ...await collectSourceFiles(
      "tools/scripts/client-secure-mesh-platform-secret-store-matrix",
      ".mjs"
    ),
  ]);
  const clientCliVmSource = await readText("tools/scripts/client-cli-vm/verify/command.mjs");
  const runtimeAdaptersRustSource = await readJoinedText([
    "crates/licoup-native/src/platform/runtime_adapters.rs",
    ...await collectSourceFiles(
      "crates/licoup-native/src/platform/runtime_adapters",
      ".rs"
    )
  ]);
  const codexAppServerFacadeSource = await readText(
    "crates/licoup-native/src/platform/codex_app_server.rs"
  );
  const codexAppServerRustSource = await readJoinedText([
    "crates/licoup-native/src/platform/codex_app_server.rs",
    ...await collectSourceFiles(
      "crates/licoup-native/src/platform/codex_app_server",
      ".rs"
    )
  ]);
  assert(runtimeAdaptersRustSource.includes("enum RuntimeAdapter") &&
    runtimeAdaptersRustSource.includes('"runtime-adapter"') &&
    runtimeAdaptersRustSource.includes("PACKAGED_RUNTIME_ADAPTER_IDS") &&
    runtimeAdaptersRustSource.includes("parse_runtime_driver_registry") &&
    runtimeAdaptersRustSource.includes("DRIVER_INVENTORY_JSON") &&
    runtimeAdaptersRustSource.includes("READINESS_JSON") &&
    runtimeAdaptersRustSource.includes("codex_app_server::execute") &&
    runtimeAdaptersRustSource.includes("nativeSessionId") &&
    runtimeAdaptersRustSource.includes("approvalOwner") &&
    codexAppServerRustSource.includes('"codex-app-server-stdio-jsonrpc"') &&
    codexAppServerRustSource.includes('"thread/start"') &&
    codexAppServerRustSource.includes('"thread/resume"') &&
    codexAppServerRustSource.includes('"turn/start"') &&
    codexAppServerRustSource.includes('"turn/completed"') &&
    codexAppServerRustSource.includes("codex_user_interaction_required") &&
    codexAppServerRustSource.includes("finish_protocol_transport") &&
    codexAppServerRustSource.includes("StdoutLimitExceeded") &&
    !codexAppServerRustSource.includes("struct AcpProtocol"),
    "runtime adapters must expose canonical per-agent transports and explicit approval ownership"
  );
  assert(mobileRelayRustSource.includes("BadTowerStationTransport") &&
    mobileRelayRustSource.includes("StationContext") &&
    mobileRelayRustSource.includes("BadTowerStationTransport::new") &&
    mobileRelayRustSource.includes("lease_mailbox") &&
    mobileRelayRustSource.includes("send_envelope") &&
    mobileRelayRustSource.includes("receive_envelopes") &&
    mobileRelayRustSource.includes("delete_envelope") &&
    mobileRelayRustSource.includes("SECURE_MESH_ENVELOPE_COMMAND") &&
    mobileRelayRustSource.includes("reject_plaintext_relay_command") &&
    mobileRelayRustSource.includes("mobile_relay_plaintext_command_rejected") &&
    mobileRelayRustSource.includes("secure_mesh_envelope_command_is_transport_only") &&
    mobileRelayRustSource.includes("mobile_relay_public_config_redacts_secret_material"),
    "mobile_relay.rs must use only the canonical four-operation BadTower station transport"
  );
  assert(!mobileRelayRustSource.includes("fn execute_command("),
    "mobile_relay.rs must not keep a plaintext command execution path for relayed server commands"
  );
  const secureMeshAcpRustSource = await readText("crates/licoup-native/src/core/secure_mesh_acp.rs");
  const secureMeshStatusRustSource = await readText("crates/licoup-native/src/core/secure_mesh.rs");
  const licoClientBinSource = await readJoinedText([
    "crates/licoup-native/src/bin/licoup.rs",
    ...await collectSourceFiles("crates/licoup-native/src/bin/licoup", ".rs")
  ]);
  assert(secureMeshAcpRustSource.includes("encode_acp_envelope_aad") &&
    secureMeshAcpRustSource.includes("LCOSM-ACP-AAD-v1") &&
    secureMeshAcpRustSource.includes("reject_plaintext_acp_protected_payload_relay") &&
    secureMeshAcpRustSource.includes("plaintext_protected_payload_relay_blocked") &&
    secureMeshAcpRustSource.includes("independent_review_pending") &&
    secureMeshAcpRustSource.includes("pqxdh_mlkem1024_triple_ratchet") &&
    secureMeshStatusRustSource.includes("acpEnvelopeStatus") &&
    secureMeshStatusRustSource.includes("SECURE_MESH_ACP_STATUS"),
    "secure mesh must expose ACP envelope AAD coverage and keep plaintext ACP protected-payload relay blocked"
  );
  assert(coreStateMachinePhysicalTestLayouts.every(({ production, tests }) =>
    /#\[cfg\(test\)\]\s*mod tests;/u.test(production) &&
    !production.includes("mod tests {") &&
    !production.includes("#[test]") &&
    !tests.includes("#[path") &&
    !tests.includes("include!(") &&
    !tests.includes("use super::*") &&
    !tests.includes("mod tests {")),
  "Secure Mesh state-machine regressions must retain ordinary physical test submodules"
  );
  assert(/#\[cfg\(test\)\]\s*mod test_support;/u.test(
    secureMeshMlsSecurityLedgerRustSource,
  ) &&
    !secureMeshMlsSecurityLedgerRustSource.includes("use rusqlite::OptionalExtension") &&
    !secureMeshMlsSecurityLedgerRustSource.includes("fn was_key_package_consumed") &&
    !secureMeshMlsSecurityLedgerRustSource.includes("fn key_package_consumed_at") &&
    secureMeshMlsSecurityLedgerTestSupportRustSource.includes("OptionalExtension") &&
    secureMeshMlsSecurityLedgerTestSupportRustSource.includes("fn was_key_package_consumed") &&
    secureMeshMlsSecurityLedgerTestSupportRustSource.includes("fn key_package_consumed_at"),
  "Secure Mesh MLS ledger test-only queries must retain a physical test-support owner"
  );
  assert(!licoClientBinSource.includes("payload seal") &&
    !licoClientBinSource.includes("payload open") &&
    !licoClientBinSource.includes("key-base64url") &&
    !licoClientBinSource.includes("contentKeyBase64url"),
    "licoup must not expose static endpoint-only payload seal/open production CLI routes"
  );
  assert(mobileRelayRustSource.includes("RUNTIME_SECRET_OVERRIDE_TRANSPORT") &&
    mobileRelayRustSource.includes('"secretOverrideTransport"') &&
    mobileRelayRustSource.includes("runtime_secret_overrides_require_platform_transport_marker"),
    "mobile_relay.rs must gate runtime secretOverrides behind an explicit platform bridge transport marker"
  );
  assert(mobileRelayRustSource.includes("SecureMeshPairwiseDurableStore") &&
    mobileRelayRustSource.includes("SecureMeshPairwiseSession::initiate") &&
    mobileRelayRustSource.includes("SecureMeshPairwiseSession::accept") &&
    mobileRelayRustSource.includes("complete_initiator_handshake") &&
    mobileRelayRustSource.includes("complete_responder_handshake") &&
    mobileRelayRustSource.includes("commit_session_with_authorized_session_and_capability_proofs") &&
    mobileRelayRustSource.includes("upsert_initial_with_local_prekey_claim_and_capability_proofs") &&
    mobileRelayRustSource.includes('"preKeyBundle"') &&
    mobileRelayRustSource.includes('"pairwiseIntro"') &&
    mobileRelayRustSource.includes('"pairwiseAccepted"') &&
    mobileRelayRustSource.includes('"pairwiseFinished"') &&
    mobileRelayRustSource.includes("mobile_relay_pairwise_initialization_requires_pqxdh_prekey_bundle") &&
    mobileRelayRustSource.includes("mobile_relay_pairwise_rejects_tampered_prekey_signature") &&
    mobileRelayRustSource.includes("seal_payload_envelope") &&
    mobileRelayRustSource.includes("open_payload_envelope"),
    "mobile_relay.rs must use PQXDH ML-KEM-1024 prekey initialization and durable Triple Ratchet pairwise envelopes"
  );
  assert(JSON.stringify(secureMeshCapabilityDiscoveredProductionPaths) ===
    JSON.stringify([...secureMeshCapabilityProductionPaths].sort()),
    "Secure Mesh capability production must retain exactly six independently owned leaves");
  assert(secureMeshCapabilityProductionPaths.every((relativePath) =>
      secureMeshCapabilityFacadeRustSource.includes(
        `mod ${path.basename(relativePath, ".rs")};`)) &&
    ["struct ", "enum ", "impl ", "fn ", "include_str!", "OnceLock"]
      .every((token) => !secureMeshCapabilityFacadeRustSource.includes(token)),
    "Secure Mesh capability root must remain a restricted stable facade with no retired implementation");
  assert(secureMeshCapabilityProductionSources["taxonomy.rs"].includes(
    "pub const COUNT: usize = 31") &&
    secureMeshCapabilityProductionSources["taxonomy.rs"].includes("match id {") &&
    !secureMeshCapabilityProductionSources["taxonomy.rs"].includes(".find(") &&
    secureMeshCapabilityProductionSources["catalog.rs"].includes(
      "MAX_CAPABILITY_CATALOG_BYTES") &&
    secureMeshCapabilityProductionSources["catalog.rs"].includes(
      "validated_topological_order") &&
    secureMeshCapabilityProductionSources["catalog.rs"].includes("OnceLock") &&
    secureMeshCapabilityProductionSources["catalog.rs"].includes("pop_first()") &&
    !secureMeshCapabilityProductionSources["catalog.rs"].includes("CapabilityFact") &&
    !secureMeshCapabilityProductionSources["catalog.rs"].includes("CapabilityEvaluation") &&
    !secureMeshCapabilityProductionSources["custody.rs"].includes("CapabilityCatalog") &&
    !secureMeshCapabilityProductionSources["custody.rs"].includes("CapabilityEvaluation") &&
    secureMeshCapabilityProductionSources["evaluation.rs"].includes(
      "[Option<&CapabilityFact>; SecurityCapability::COUNT]") &&
    (secureMeshCapabilityProductionSources["evaluation.rs"].match(
      /for capability in self\.topological_order\(\)/g) ?? []).length === 1 &&
    !secureMeshCapabilityProductionSources["evaluation.rs"].includes(
      "CapabilityEvaluationReport") &&
    !secureMeshCapabilityProductionSources["report.rs"].includes("impl CapabilityCatalog") &&
    !secureMeshCapabilityProductionSources["report.rs"].includes("topological_order") &&
    secureMeshCapabilityRustSource.includes("mandatory_foundation_complete") &&
    secureMeshCapabilityRustSource.includes("MemoryOnlyEphemeral") &&
    secureMeshCapabilityRustSource.includes("RePairRekeyAfterRestart") &&
    secureMeshCapabilityProbeRustSource.includes("trait SecureMeshCapabilityProbe") &&
    secureMeshCapabilityProbeRustSource.includes("CapabilityProbeSnapshot") &&
    secureMeshCapabilityReportSource.includes("validateCapabilityReport") &&
    secureMeshCapabilityReportSource.includes("reduceCapabilityFacts"),
    "Secure Mesh posture must keep taxonomy, bounded cached DAG, custody, evaluation, and report one-way and independently testable"
  );
  assert(JSON.stringify(secureMeshPrekeyDiscoveredProductionPaths) ===
    JSON.stringify([...secureMeshPrekeyProductionPaths].sort()),
    "Secure Mesh prekey production must retain exactly four independently owned leaves");
  assert(secureMeshPrekeyProductionPaths.every((relativePath) =>
      secureMeshPrekeyFacadeRustSource.includes(
        `mod ${path.basename(relativePath, ".rs")};`)) &&
    ["struct ", "enum ", "impl ", "fn ", "SigningKey", "OffsetDateTime"]
      .every((token) => !secureMeshPrekeyFacadeRustSource.includes(token)),
    "Secure Mesh prekey root must remain a restricted stable facade with no retired implementation");
  assert(secureMeshPrekeyProductionSources["pairwise.rs"].includes(
    "SecureMeshPairwisePreKeyBundle") &&
    secureMeshPrekeyProductionSources["pairwise.rs"].includes(
      "DirectoryAuthorizationPurpose::PairwiseSessionBootstrap") &&
    secureMeshPrekeyProductionSources["pairwise.rs"].includes(
      "ML_KEM_1024_PUBLIC_KEY_BYTES") &&
    !secureMeshPrekeyProductionSources["pairwise.rs"].includes(
      "SecureMeshKeyPackageRecord") &&
    secureMeshPrekeyProductionSources["key_package.rs"].includes(
      "KEYPACKAGE_MAGIC") &&
    secureMeshPrekeyProductionSources["key_package.rs"].includes(
      "SECURE_MESH_MLS_CIPHER_SUITE") &&
    !secureMeshPrekeyProductionSources["key_package.rs"].includes(
      "AuthorizedDirectoryLeaf") &&
    secureMeshPrekeyProductionSources["inventory.rs"].includes(
      "one_time_prekey_replenishment_required") &&
    secureMeshPrekeyProductionSources["inventory.rs"].includes(
      "key_package_replenishment_required") &&
    secureMeshPrekeyProductionSources["validation.rs"].includes(
      "MAX_PREKEY_CLOCK_SKEW_SECONDS") &&
    secureMeshPrekeyProductionSources["validation.rs"].includes(
      "ensure_active_trust_state") &&
    secureMeshPrekeyProductionSources["validation.rs"].includes("verify_signature") &&
    secureMeshPrekeyProductionSources["validation.rs"].includes(
      "String::with_capacity") &&
    !secureMeshPrekeyProductionSources["validation.rs"].includes(
      "SecureMeshPreKeyRecord") &&
    !Object.values(secureMeshPrekeyProductionSources).join("\n").includes(
      "SecureMeshKtLog") &&
    !Object.values(secureMeshPrekeyProductionSources).join("\n").includes("reqwest::"),
    "Secure Mesh prekeys must isolate pairwise PQXDH, MLS KeyPackage, local watermarks, and shared fail-closed validation"
  );
  assert(secureMeshCapabilityProofRustSource.includes("ClientCapabilityProjection") &&
    secureMeshCapabilityProofRustSource.includes("capability_projection_from_evaluation") &&
    secureMeshSessionNegotiationRustSource.includes("negotiated_protocol_capabilities") &&
    secureMeshSessionNegotiationRustSource.includes("peer: Some") &&
    secureMeshProtocolStatusRustSource.includes('"capabilityProjection"'),
    "Secure Mesh native status and verified sessions must expose one exact client capability projection"
  );
  assert(mobileRelayRustSource.includes("mobile_relay_e2ee_secret_store_status") &&
    mobileRelayRustSource.includes("privateKeyInSelectedCustody") &&
    mobileRelayRustSource.includes("signingKeyInSelectedCustody") &&
    mobileRelayRustSource.includes("signedPrekeyPrivateKeyInSelectedCustody") &&
    mobileRelayRustSource.includes("oneTimePrekeyPrivateKeyInSelectedCustody") &&
    mobileRelayRustSource.includes("allPrivateKeysInSelectedCustody") &&
    mobileRelayRustSource.includes("unsafePersistenceDetected") &&
    mobileRelayRustSource.includes("e2ee_status_rejects_private_key_material_in_portable_config") &&
    mobileRelayRustSource.includes("e2ee_status_accepts_memory_only_custody_but_does_not_overclaim_missing_session") &&
    mobileRelayRustSource.includes("e2ee_status_reports_only_confirmed_negotiated_durable_session") &&
    mobileRelayRustSource.includes("production_pairwise_store_reuses_selected_memory_custody_and_purges_after_restart") &&
    mobileRelayRustSource.includes("authorized_pairwise_session_status") &&
    mobileRelayRustSource.includes("handshake_confirmed") &&
    mobileRelayRustSource.includes("with_mobile_relay_secret_store_override") &&
    mobileRelayRustSource.includes("secure_command_create_rejects_raw_runtime_e2ee_secret_overrides") &&
    mobileRelayRustSource.includes("secure_command_create_uses_mobile_relay_secret_store_override_without_raw_e2ee_json") &&
    mobileRelayRustSource.includes("load_config_without_persistence") &&
    mobileRelayRustSource.includes("should_authorize_secret_read") &&
    mobileRelayRustSource.includes("public_config_get_does_not_begin_secret_store_authorization_session") &&
    mobileRelayRustSource.includes("e2ee_status_without_authorization_does_not_begin_secret_store_session") &&
    mobileRelayRustSource.includes("authorizationRequiredForFullStatus") &&
    mobileRelayRustSource.includes("e2ee_status_redacts_pairing_invite_secret"),
    "mobile_relay.rs must expose the shared exact capability result, safe selected custody, and unsafe-persistence rejection while public reads remain no-authorize"
  );
  const macosCargoDependencyStart = cargoToml.indexOf(
    "[target.'cfg(target_os = \"macos\")'.dependencies]"
  );
  const macosCargoDependencyEnd = cargoToml.indexOf(
    "[target.'cfg(target_os = \"linux\")'.dependencies]"
  );
  const macosCargoDependencies = cargoToml.slice(
    macosCargoDependencyStart,
    macosCargoDependencyEnd
  );
  assert(!cargoToml.includes("keyring =") &&
    macosCargoDependencyStart >= 0 &&
    macosCargoDependencyEnd > macosCargoDependencyStart &&
    macosCargoDependencies.includes("objc2 =") &&
    macosCargoDependencies.includes("objc2-local-authentication =") &&
    macosCargoDependencies.includes("security-framework =") &&
    macosCargoDependencies.includes("security-framework-sys =") &&
    !secureMeshSecretStoreRustSource.includes("keyring::") &&
    !await exists(
      "crates/licoup-native/src/platform/secure_mesh_secret_store/platform_backends/keyring.rs"
    ) &&
    mobileRelayRustSource.includes("NATIVE_SECRET_STORE_SERVICE") &&
    mobileRelayRustSource.includes("persist_config_secret_material_to_native_store") &&
    mobileRelayRustSource.includes("RuntimeSecretContext") &&
    mobileRelayRustSource.includes("load_config_with_runtime_secret_context") &&
    mobileRelayRustSource.includes("SecretStoreAuthorizationSession") &&
    mobileRelayRustSource.includes("begin_authorized_session") &&
    mobileRelayRustSource.includes("set_secret_with_session") &&
    mobileRelayRustSource.includes("get_secret_with_session") &&
    mobileRelayRustSource.includes("delete_secret_with_session") &&
    mobileRelayRustSource.includes("struct MobileRelayPairwiseOperation") &&
    mobileRelayRustSource.includes("Mobile Relay secure command operation authorization batch") &&
    mobileRelayRustSource.includes("Mobile Relay secure result operation authorization batch") &&
    mobileRelayRustSource.includes("Mobile Relay secure result replay proof authorization batch") &&
    mobileRelayRustSource.includes("Mobile Relay commands sync operation authorization batch") &&
    mobileRelayRustSource.includes("command_result_secure_reuses_single_operation_auth_batch_for_fetch_and_result_open") &&
    mobileRelayRustSource.includes("command_result_replay_proof_reuses_single_operation_auth_batch_for_fetch_and_replay_check") &&
    mobileRelayRustSource.includes("mobile_relay_commands_sync_reuses_single_operation_auth_batch_for_secure_commands") &&
    mobileRelayRustSource.includes("mobile_relay_secure_command_execute_reuses_single_operation_auth_batch_for_open_and_result_seal") &&
    mobileRelayRustSource.includes("e2ee_secret_store_self_test") &&
    mobileRelayRustSource.includes("MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS") &&
    secureMeshSecretStoreRustSource.includes("PlatformSecretStoreRuntimeState::Unverified") &&
    secureMeshSecretStoreRustSource.includes("CapabilityEvidenceKind::NotMeasured") &&
    secureMeshSecretStoreRustSource.includes("linux_secret_service_io_round_trip_unverified") &&
    secureMeshSecretStoreRustSource.includes("fail_closed::begin_authorized_session") &&
    secureMeshSecretStoreRustSource.includes("platform_secret_store_runtime_operation_unverified"),
    "desktop custody must use direct macOS Security.framework access while unmeasured Linux or Windows storage stays fail-closed"
  );
  const localAuthenticationEvaluation =
    platformUserPresenceRustSource.indexOf("evaluatePolicy_localizedReason_reply");
  const interactiveContextStart =
    platformUserPresenceRustSource.indexOf("context.setInteractionNotAllowed(false)");
  const authorizationOutcome =
    platformUserPresenceRustSource.indexOf("match receiver.recv_timeout");
  const approvedContextSeal =
    platformUserPresenceRustSource.indexOf("context.setInteractionNotAllowed(true)");
  assert(
    secureMeshSecretStoreAuthorizationRustSource.includes(
      "pub struct SecretStorePresenceBatchRequest"
    ) &&
    secureMeshSecretStoreAuthorizationRustSource.includes(
      "pub struct SecretStoreApprovedPresenceBatch"
    ) &&
    secureMeshSecretStoreAuthorizationRustSource.includes(
      "pub struct SecretStorePresenceGrant"
    ) &&
    secureMeshSecretStoreAuthorizationRustSource.includes(
      "pub struct SecretStoreConsumedPresence"
    ) &&
    secureMeshSecretStoreAuthorizationRustSource.includes(
      "MAX_SECRET_STORE_PRESENCE_GRANT_TTL: Duration = Duration::from_secs(30)"
    ) &&
    macosUserPresenceRustSource.includes("pub struct MacosPresenceBatchCoordinator") &&
    macosUserPresenceRustSource.includes("pub struct MacosAuthorizedPresence") &&
    macosUserPresenceRustSource.includes("pub struct SecurityFrameworkKeychain") &&
    macosUserPresenceRustSource.includes("pub trait MacosSecItemPort") &&
    macosUserPresenceRustSource.includes("kSecUseAuthenticationContext") &&
    macosUserPresenceRustSource.includes("crate::platform::user_presence::authorize(") &&
    platformUserPresenceRustSource.includes("APPLICATION_AUTHORIZATION") &&
    platformUserPresenceRustSource.includes("LAPolicy::DeviceOwnerAuthenticationWithBiometrics") &&
    platformUserPresenceRustSource.includes("password_fallback_allowed") &&
    platformUserPresenceRustSource.includes("setLocalizedFallbackTitle") &&
    platformUserPresenceRustSource.includes("block2::RcBlock::new") &&
    localAuthenticationEvaluation >= 0 &&
    localAuthenticationEvaluation ===
      platformUserPresenceRustSource.lastIndexOf("evaluatePolicy_localizedReason_reply") &&
    interactiveContextStart >= 0 &&
    interactiveContextStart < localAuthenticationEvaluation &&
    authorizationOutcome > localAuthenticationEvaluation &&
    approvedContextSeal > authorizationOutcome &&
    secureMeshSecretStoreAuthorizationRustSource.includes("app_password_prompt_used: false") &&
    !macosUserPresenceRustSource.includes("AUTHORIZATION_CONTEXT_CACHE") &&
    !platformUserPresenceRustSource.includes("AUTHORIZATION_CONTEXT_CACHE") &&
    !macosUserPresenceRustSource.includes("evaluatePolicy_localizedReason_reply") &&
    !macosUserPresenceRustSource.includes("keyring::") &&
    !await exists(
      "crates/licoup-native/src/platform/secure_mesh_secret_store/platform_backends/keyring.rs"
    ),
    "macOS Secure Mesh custody must bind exact 30-second single-use grants to one LocalAuthentication context and direct Security.framework effects without app passwords or legacy caches"
  );
  assert(macosUserPresenceProofSource.includes("reduceCapabilityFacts") &&
    macosUserPresenceProofSource.includes("validateCapabilityReport") &&
    macosUserPresenceProofSource.includes("standardKeychainAvailable") &&
    macosUserPresenceProofSource.includes("dataProtectionKeychainAvailable") &&
    macosUserPresenceProofSource.includes("userPresenceOperationSupported") &&
    macosUserPresenceProofSource.includes("secureEnclaveOperationSupported") &&
    macosUserPresenceProofSource.includes("promptBudgetSatisfied") &&
    macosUserPresenceProofSource.includes("zeroBackgroundPrompts") &&
    macosUserPresenceProofSource.includes("noAutomaticAuthorizationRetry") &&
    macosUserPresenceProofSource.includes("interactiveAuthorizationAttemptCount = 1") &&
    macosUserPresenceProofSource.includes("options.interactive === true") &&
    platformSecretStoreMatrixSource.includes("validateCapabilityReport") &&
    platformSecretStoreMatrixSource.includes("exactCapabilitySetValid") &&
    platformSecretStoreMatrixSource.includes("safeOsStoreAvailable") &&
    platformSecretStoreMatrixSource.includes("macosEnabledCapabilities"),
    "macOS Secure Mesh evidence must reduce independent platform facts into the shared exact adaptive capability set"
  );
  const nonInteractiveAuthorizationGate = macosUserPresenceRustSource.indexOf(
    "if !request.allow_interaction()",
  );
  const presenceRequestDigest = macosUserPresenceRustSource.indexOf(
    "let request_digest = request.canonical_digest()",
  );
  const batchCacheLock = macosUserPresenceRustSource.indexOf(
    "let mut batches = self",
  );
  const releasedBatchCacheScope = macosUserPresenceRustSource.indexOf(
    "if !prompt_owner",
  );
  const systemPresencePrompt = macosUserPresenceRustSource.indexOf(
    ".prompt(request)",
  );
  assert(
    nonInteractiveAuthorizationGate >= 0 &&
      presenceRequestDigest > nonInteractiveAuthorizationGate &&
      batchCacheLock > presenceRequestDigest &&
      releasedBatchCacheScope > batchCacheLock &&
      systemPresencePrompt > releasedBatchCacheScope &&
      macosUserPresenceRustSource.includes(
        "MACOS_AUTHORIZATION_CACHE_MAX_BATCHES: usize = 16"
      ) &&
      macosUserPresenceRustSource.includes(
        "batches.len() >= MACOS_AUTHORIZATION_CACHE_MAX_BATCHES"
      ) &&
      secureMeshSecretStoreAuthorizationRustSource.includes(
        "MAX_SECRET_STORE_PRESENCE_GRANT_TTL: Duration = Duration::from_secs(30)"
      ),
    "macOS background secret access must reject non-interactive requests before cache lookup and must never hold the bounded presence cache lock while system UI is active",
  );
  assert(clientCliVmSource.includes("dbus-run-session") &&
    clientCliVmSource.includes("gnome-keyring-daemon") &&
    clientCliVmSource.includes("secret-store-self-test") &&
    secureMeshSecretStoreRustSource.includes("linux_secret_service_io_round_trip_unverified") &&
    secureMeshSecretStoreRustSource.includes("fail_closed::get_secret_with_session"),
    "Ubuntu proof tooling may exercise Secret Service, but production selection must stay fail-closed until measured CRUD and native authorization are available"
  );
  const mobileRelaySupportRustSource = await readText(
    "crates/licoup-native/src/domain/mobile_relay/support.rs"
  );
  const mobileRelayRedactionTests = await readText(
    "crates/licoup-native/src/domain/mobile_relay/tests/relay_operations/identity_replay_safety.rs"
  );
  assert(mobileRelaySupportRustSource.includes("SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_DETAIL") &&
    mobileRelayRedactionTests.includes("commands_sync_redacts_malicious_station_crypto_errors") &&
    mobileRelayRedactionTests.includes("mobile_relay_command_error_result_redacts_internal_detail") &&
    !mobileRelayCommandSyncRustSource.includes("error.to_string()"),
    "mobile_relay.rs must redact endpoint crypto/runtime errors instead of returning raw local details"
  );
}
