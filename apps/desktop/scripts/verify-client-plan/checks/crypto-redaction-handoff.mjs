export async function checkCryptoRedactionHandoff({ assert, files }) {
  const { readJson, readSourceBundle, readText } = files;
const secureMeshReportRedaction = await readText("tools/scripts/client-secure-mesh-report-redaction-verify.mjs");
const secureMeshReportRedactionConfig = await readText("tools/scripts/config/secure-mesh-report-redaction.json");
const secureMeshReportRedactionConfigJson = await readJson("tools/scripts/config/secure-mesh-report-redaction.json");
for (const token of [
  "licolite.secure-mesh.report-redaction-config.v1",
  "secure-mesh-report-redaction.json",
  "secure-mesh-release-input-report-redaction.json",
  "requiredRefs",
  "optionalRefs",
  "deferredGraphRefs",
  "build/reports/secure-mesh-pairwise-content-crypto-audit.json",
  "build/reports/secure-mesh-android-platform-crypto-acceptance.json",
  "build/reports/secure-client-relay-mock-e2e.json",
  "build/reports/secure-mesh-physical-evidence-manifest.json",
  "build/reports/secure-mesh-release-cli-proof-macos.json",
  "build/client-cli-vm/ubuntu-arm64/secure-mesh-release-cli-proof.json",
  "build/client-cli-vm/ubuntu-arm64/secure-mesh-linux-adaptive-custody-proof.json",
  "build/client-cli-vm/ubuntu-arm64/secure-mesh-linux-package-update-proof.json",
  "build/client-cli-vm/ubuntu-arm64/secure-mesh-linux-vm-package-receipt.json",
  "build/client-cli-vm/ubuntu-arm64/secure-mesh-linux-node-matrix.json",
  "build/reports/secure-client-mesh-e2ee/authority-proof-template.json",
  "build/reports/secure-client-mesh-e2ee-evidence-bundle.json"
]) {
  assert(secureMeshReportRedactionConfig.includes(token),
    `secure mesh report redaction config must keep physical/mobile coverage token ${token}`);
}
assert(Array.isArray(secureMeshReportRedactionConfigJson.modes?.default?.requiredRefs) &&
  secureMeshReportRedactionConfigJson.modes.default.requiredRefs.length === 19,
  "secure mesh report redaction config must scan the default E2EE evidence graph");
assert(Array.isArray(secureMeshReportRedactionConfigJson.modes?.releaseProofInputs?.requiredRefs) &&
  secureMeshReportRedactionConfigJson.modes.releaseProofInputs.requiredRefs.length === 9,
  "secure mesh report redaction config must scan release proof input reports");
assert(secureMeshReportRedactionConfigJson.modes?.releaseProofInputs?.deferredGraphRefs?.includes(
  "build/reports/secure-mesh-release-proof-bundle.json"
), "secure mesh report redaction config must defer release proof bundle recursion for release-input mode");
assert(secureMeshReportRedactionConfigJson.modes?.default?.optionalRefs?.includes(
  "build/reports/secure-client-mesh-e2ee/authority-proof-template.json"
), "secure mesh report redaction config must scan the optional authority-proof template in default mode");
assert(secureMeshReportRedactionConfigJson.modes?.releaseProofInputs?.optionalRefs?.includes(
  "build/reports/secure-client-mesh-e2ee/authority-proof-template.json"
), "secure mesh report redaction config must scan the optional authority-proof template in release-input mode");
const secureMeshReportRedactionConfigHelper =
  await readText("tools/scripts/lib/secure-mesh-report-redaction-config.mjs");
for (const token of [
  "loadSecureMeshReportRedactionConfig",
  "normalizeSafeReportRef",
  "assertNoLeak",
  "Duplicate Secure Mesh redaction",
  "must not scan verifier output reports as required input"
]) {
  assert(secureMeshReportRedactionConfigHelper.includes(token),
    `secure mesh report redaction config helper must keep safety token ${token}`);
}
for (const token of [
  "loadSecureMeshReportRedactionConfig",
  "selectedReportRefs",
  "selectedOptionalReportRefs",
  "selectedDeferredGraphRefs",
  "reportRefPattern",
  "collectLinkedReportRefs",
  "runSelfTest",
  "selfTestReady",
  "graphDerivedRefs",
  "graphDerivedReportCount",
  "scannedRefDigests",
  "scannedRefDigestCount",
  "redactionRunId",
  "redactionRunIdPresent",
  "deferredGraphRefs",
  "deferredGraphRefCount",
  "missingRefs.length === 0",
  "adb_device_listing",
  "labeled_device_identifier",
  "identity-or-local-string-field"
]) {
  assert(secureMeshReportRedaction.includes(token),
    `secure mesh report redaction verifier must keep physical/mobile report coverage token ${token}`);
}
async function assertContractBoundEvidenceReport(relativePath, blockerLabel, sourceDirectory = "") {
  const text = sourceDirectory
    ? await files.readSourceBundle(relativePath, sourceDirectory, ".mjs")
    : await readText(relativePath);
    for (const token of [
      "loadSecureClientContract",
      "SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS",
      "SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH",
      blockerLabel,
      "contractBinding",
      "generatedBy",
      "checkedAt",
      "reportLeakScan",
      "rawPrivateMaterialIncluded",
      "rawPlaintextIncluded",
      "rawPublicWireBytesIncluded"
    ]) {
      assert(text.includes(token), `${relativePath} must keep contract-bound token ${token}`);
    }
    assert(!text.includes("blockerStatus"),
      `${relativePath} must not publish blockerStatus; use diagnosticStatus for non-authoritative local diagnostics`);
    assert(text.includes("diagnosticStatus"),
      `${relativePath} must expose diagnosticStatus only as a non-authoritative local diagnostic`);
}
const pairwiseContentAudit = await files.readSourceBundle(
  "tools/scripts/client-secure-mesh-pairwise-content-audit.mjs",
  "tools/scripts/client-secure-mesh-pairwise-content-audit",
  ".mjs",
);
const pairwiseContentAuditConfig =
  await readText("tools/scripts/config/secure-mesh-pairwise-content-audit.json");
const pairwiseContentAuditConfigJson =
  await readJson("tools/scripts/config/secure-mesh-pairwise-content-audit.json");
for (const token of [
  "licolite.secure-mesh.pairwise-content-audit-config.v2",
  "build/reports/secure-mesh-pairwise-content-crypto-audit.json",
  "build/reports/secure-mesh-pairwise-content-vector-corpus.json",
  "build/reports/secure-mesh-pairwise-content-review-signoff.json",
  "LICO_SECURE_MESH_PAIRWISE_CONTENT_SIGNOFF",
  "sourceChecks",
  "nativeTestFilters",
  "client-relay-mock-covers-opaque-wire-adversarial-semantics",
  "client-relay-contract-pin-validates-exact-operation-and-envelope-sets",
  "mobile_relay_pairwise_rejects_relay_asserted_prekey_trust_state",
  "mobile_relay_pairwise_rejects_intro_signed_prekey_mismatch",
  "mobile_relay_pairwise_rejects_reused_remote_one_time_prekey",
  "SecureMeshRemotePreKeyUse",
  "secure_mesh_pairwise_remote_prekey_uses",
	  "record_remote_prekey_use",
	  "pairwise-authenticated-ratchet-is-restart-safe",
	  "handshake_transcript_hash",
	  "initiator_key_confirmed",
	  "pairwise_key_confirmation",
	  "pending_sending_ratchet",
	  "prepare_sending_ratchet_for_send",
	  "store_skipped_message_keys_until",
	  "secure_mesh_pairwise_dh_ratchet_reply_auto_rotates_after_remote_ratchet",
	  "secure_mesh_pairwise_dh_ratchet_preserves_old_chain_in_flight_messages",
	  "secure_mesh_pairwise_dh_ratchet_skip_limit_fails_closed_without_state_advance",
	  "secure_mesh_pairwise_pending_authenticated_ratchet_survives_restart",
	  "secure_mesh_pairwise_stale_and_replayed_relay_acks_do_not_advance_ratchet",
	  "secure_mesh_pairwise_revoked_session_fail_closed_for_seal_and_open",
	  "mls-product-policy-bindings-and-kt-signed-checkpoints",
	  "key-transparency-signed-checkpoints-non-authorizing-hash-chain",
	  "lifecycle-service-actions-require-pairwise-or-mls-envelopes",
	  "authorize_hashed_directory_view",
	  "seal_lifecycle_service_action_pairwise",
	  "mobile-ffi-forbids-raw-payload-crypto-actions",
  "includeBodyBase64url",
  "acp-envelope-aad-covers-protected-payload-binding",
  "acp-plaintext-protected-payload-relay-is-not-a-production-path",
  "static-endpoint-only-payload-cli-route-is-absent",
  "encode_acp_envelope_aad",
  "LCOSM-ACP-AAD-v1",
  "reject_plaintext_acp_protected_payload_relay",
  "secure_mesh_acp_envelope_aad_has_stable_digest_vector"
]) {
  assert(pairwiseContentAuditConfig.includes(token),
    `pairwise/content audit config must keep report token ${token}`);
}
assert(Array.isArray(pairwiseContentAuditConfigJson.reviewSignoff?.envKeys) &&
  pairwiseContentAuditConfigJson.reviewSignoff.envKeys.length === 1,
  "pairwise/content audit config must define the review signoff override env key");
assert(Array.isArray(pairwiseContentAuditConfigJson.sourceChecks) &&
  pairwiseContentAuditConfigJson.sourceChecks.length >= 18 &&
  Array.isArray(pairwiseContentAuditConfigJson.nativeTestFilters) &&
  pairwiseContentAuditConfigJson.nativeTestFilters.length >= 30,
  "pairwise/content audit config must define digest-bound source checks and native test filters");
const pairwiseContentAuditConfigHelper =
  await readText("tools/scripts/lib/secure-mesh-pairwise-content-audit-config.mjs");
for (const token of [
  "loadSecureMeshPairwiseContentAuditConfig",
  "normalizeSafeReportRef",
  "normalizeSafeSourceRef",
  "normalizeEnvKeys",
  "normalizeSourceChecks",
  "normalizeNativeTestFilters",
  "assertNoLeak",
  "must use distinct report refs",
  "source checks must have unique ids",
  "native test filters must be unique",
  "review signoff must not overwrite verifier outputs"
]) {
  assert(pairwiseContentAuditConfigHelper.includes(token),
    `pairwise/content audit config helper must keep safety token ${token}`);
}
for (const token of [
  "loadSecureMeshPairwiseContentAuditConfig",
  "pairwiseContentAuditConfig",
  "reportPath = pairwiseContentAuditConfig.reportOutput",
  "vectorCorpusPath = pairwiseContentAuditConfig.vectorCorpusOutput",
  "reviewSignoffPath = pairwiseContentAuditConfig.reviewSignoffRef",
  "--generate-signoff-template",
  "vectorCorpusSnapshotRefForCorpus",
  "loadVectorCorpusSnapshot",
  "vectorCorpusSnapshotReport",
  "reviewSignoffTemplateForCorpus",
  "licolite.secure-mesh.pairwise-content-review-signoff-template.v2",
  "reviewSignoffTemplatePresent",
  "reviewSignoffTemplateDigestMatched",
  "reviewSignoffTemplateSnapshotPresent",
  "reviewSignoffTemplateSnapshotDigestMatched",
  "loadSecureClientContract",
  "SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS",
  "SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH",
  "contractBinding",
  "secure_mesh_pairwise_pc_pc_command_result_relay_round_trip",
  "secure_mesh_pairwise_mobile_pc_command_result_relay_round_trip",
  "secure_mesh_pairwise_pc_mobile_command_result_relay_round_trip",
  "secure_mesh_pairwise_mobile_mobile_command_result_relay_round_trip",
  "secure_mesh_pairwise_cli_desktop_command_result_relay_round_trip",
  "secure_mesh_pairwise_agent_host_command_result_relay_round_trip",
  "secure_mesh_sesame_multi_device_fanout_uses_independent_pairwise_envelopes_and_ack_purge",
  "mobile_relay_file_key_envelope_hides_attachment_key_and_opens_file_after_decrypt",
  "mobile_relay_file_key_envelope_metadata_boundary_is_exhaustive",
  "mobile FFI raw payload key/body actions are absent",
  "runCargoTestFilter",
  "tampered_mobile_relay_command_envelope_is_rejected_before_execution",
  "replayed_mobile_relay_command_envelope_does_not_execute_twice",
  "rfc9162_inclusion_and_consistency_paths_are_logarithmic_and_exact",
  "secure_mesh_mls_product_forged_sender_and_typed_kt_member_add",
  "licolite.secure-mesh.pairwise-content-review-signoff.v2",
  "nativeTestFiltersDigest",
  "sourceCheckIdsDigest",
  "independentCryptographicReviewComplete: null",
  "releaseOwnerSignoffComplete: null",
  "approved_for_release_gate",
  "createSecureClientMeshE2eeRefReportScope",
  "reportRef: reportPath",
  "PC/Android/iPhone/CLI/runtime endpoint-kind command/result relay matrix",
  "Sesame-style multi-device fanout with independent pairwise envelopes"
]) {
  assert(pairwiseContentAudit.includes(token) || pairwiseContentAuditConfig.includes(token),
    `pairwise/content audit evidence report/config must keep contract-bound token ${token}`);
}
assert(pairwiseContentAudit.includes("sourceChecks = Object.freeze(pairwiseContentAuditConfig.sourceChecks)") &&
  pairwiseContentAudit.includes("nativeTestFilters = Object.freeze(pairwiseContentAuditConfig.nativeTestFilters)") &&
  !pairwiseContentAudit.includes("const sourceChecks = Object.freeze([") &&
  !pairwiseContentAudit.includes("const nativeTestFilters = Object.freeze(["),
  "pairwise/content audit must load source checks and native filters from config instead of hardcoding inline arrays");
for (const token of [
  "const reportPath = \"build/reports/secure-mesh-pairwise-content-crypto-audit.json\"",
  "const vectorCorpusPath = \"build/reports/secure-mesh-pairwise-content-vector-corpus.json\"",
  "process.env.LICO_SECURE_MESH_PAIRWISE_CONTENT_SIGNOFF",
  "\"build/reports/secure-mesh-pairwise-content-review-signoff.json\""
]) {
  assert(!pairwiseContentAudit.includes(token),
    `pairwise/content audit must load configured evidence ref instead of hardcoding ${token}`);
}
const secureClientRelayMockE2e =
  await readText("tools/scripts/client-secure-client-relay-mock-e2e.mjs");
const secureClientRelayMock = await readSourceBundle(
  "tools/scripts/lib/secure-client-relay-mock.mjs",
  "tools/scripts/lib/secure-client-relay-mock",
  ".mjs",
);
const secureClientRelayMockReport =
  await readText("tools/scripts/lib/secure-client-relay-mock-e2e-report.mjs");
for (const token of [
  "licolite.secure-client-relay.client-acceptance-report.v1",
  "licolite.secure-client-relay.mock-e2e-report.v1",
  "opaque relay protocol mock",
  "evidenceRefSchemaVersion",
  "productionReady: mock.ok === true",
  "releaseReady: mock.ok === true",
  "exactFiveOperationsObserved",
  "exactSixOuterFieldsObserved",
  "replayRejected",
  "staleLeaseRejected",
  "ackIdempotencyVerified",
  "plaintextAbsentFromServerVisibleWire",
  "wireBytesMeasured"
]) {
  assert(secureClientRelayMockE2e.includes(token),
    `secure client relay Mock E2E must keep protocol fact ${token}`);
}
for (const token of [
  "loadSecureClientRelayArtifacts",
  "exactKeys(envelope, outerFields",
  "secure_mesh_replay_rejected",
  "secure_mesh_stale_lease",
  "maxMailboxEntries",
  "maxMailboxBytes"
]) {
  assert(secureClientRelayMock.includes(token),
    `secure client relay Mock must keep bounded protocol behavior ${token}`);
}
for (const token of [
  "secureClientRelayMockE2eReady",
  "operationCount === 5",
  "outerEnvelopeFieldCount === 6",
  "plaintextAbsentFromServerVisibleWire === true"
]) {
  assert(secureClientRelayMockReport.includes(token),
    `secure client relay Mock report reducer must keep strict fact ${token}`);
}
const encryptedFileHandoff = await readText("tools/scripts/client-secure-mesh-encrypted-file-handoff.mjs");
const encryptedFileHandoffConfig =
  await readText("tools/scripts/config/secure-mesh-encrypted-file-handoff.json");
const encryptedFileHandoffConfigJson =
  await readJson("tools/scripts/config/secure-mesh-encrypted-file-handoff.json");
const encryptedFileHandoffConfigHelper =
  await readText("tools/scripts/lib/secure-mesh-encrypted-file-handoff-config.mjs");
for (const token of [
  "loadSecureMeshEncryptedFileHandoffConfig",
  "loadSecureMeshPhysicalEvidenceConfig",
  "encryptedFileHandoffConfig",
  "physicalEvidenceConfig",
  "physicalReportRefs",
  "sourceChecks = Object.freeze(encryptedFileHandoffConfig.sourceChecks)",
  "nativeTestFilters = Object.freeze(encryptedFileHandoffConfig.nativeTestFilters)",
  "reportPath = physicalReportRefs.encryptedFileHandoff",
  "physicalReportRefs.androidPlatformCrypto",
  "physicalReportRefs.relayMock",
  "physicalReportRefs.macosReleaseCliProof",
  "physicalReportRefs.ubuntuReleaseCliProof",
  "physicalReportRefs.windowsImplementation",
  "loadAndroidPlatformCryptoEvidence",
  "loadRelayMockEvidence",
  "secureClientRelayMockE2eReady",
  "loadSecureClientContract",
  "SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS",
  "SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH",
  "encrypted file handoff",
  "contractBinding",
  "secure_mesh_file_key_wraps_through_pairwise_session_before_file_open",
  "secure_mesh_file_key_wraps_out_of_order_and_revocation_fails_closed",
  "mobile_relay_file_key_envelope_hides_attachment_key_and_opens_file_after_decrypt",
  "mobile_relay_file_key_envelope_metadata_boundary_is_exhaustive",
  "secure_mesh_file_handoff_proof_reseals_distinct_ciphertext_for_multiple_recipients",
  "multiRecipientEndpointSpecificResealProofReady",
  "releaseBuiltDesktopMatrixSatisfied",
  "releaseBuiltDesktopWindowsLocalBlockersCleared",
  "androidPlatformCryptoReady",
  "relayMockReady",
  "plaintextAbsentFromRelayVisibleWire",
  "relayAckIdempotencyVerified",
  "shared Rust endpoint-specific reseal proof for every recipient"
]) {
  assert(encryptedFileHandoff.includes(token) || encryptedFileHandoffConfig.includes(token),
    `encrypted file handoff evidence report/config must keep contract-bound token ${token}`);
}
assert(!encryptedFileHandoff.includes("const sourceChecks = Object.freeze([") &&
  !encryptedFileHandoff.includes("const nativeTestFilters = Object.freeze(["),
  "encrypted file handoff must load source checks and native filters from config instead of hardcoding inline arrays");
for (const token of [
  "licolite.secure-mesh.encrypted-file-handoff-config.v1",
  "sourceChecks",
  "nativeTestFilters",
  "file-transfer-state-tracks-resume-ack-and-purge",
  "mobile-relay-file-key-envelope-uses-pairwise-transport-with-opaque-relay-wire",
  "android-platform-crypto-acceptance-covers-custody-authorization-and-ffi"
]) {
  assert(encryptedFileHandoffConfig.includes(token),
    `encrypted file handoff config must keep token ${token}`);
}
assert(Array.isArray(encryptedFileHandoffConfigJson.sourceChecks) &&
  encryptedFileHandoffConfigJson.sourceChecks.length >= 10 &&
  Array.isArray(encryptedFileHandoffConfigJson.nativeTestFilters) &&
  encryptedFileHandoffConfigJson.nativeTestFilters.length >= 21,
  "encrypted file handoff config must define source checks and native test filters");
for (const token of [
  "loadSecureMeshEncryptedFileHandoffConfig",
  "normalizeSafeSourceRef",
  "normalizeSourceChecks",
  "normalizeNativeTestFilters",
  "assertNoLeak",
  "source checks must have unique ids"
]) {
  assert(encryptedFileHandoffConfigHelper.includes(token),
    `encrypted file handoff config helper must keep safety token ${token}`);
}
for (const token of [
  "const reportPath = \"build/reports/secure-mesh-encrypted-file-handoff.json\"",
  "const report = \"build/reports/secure-mesh-android-platform-crypto-acceptance.json\"",
  "const report = \"build/reports/secure-client-relay-mock-e2e.json\"",
  "report: \"build/reports/secure-mesh-release-cli-proof-macos.json\"",
  "report: \"build/client-cli-vm/ubuntu-arm64/secure-mesh-release-cli-proof.json\"",
  "const report = \"build/reports/secure-mesh-windows-implementation.json\""
]) {
  assert(!encryptedFileHandoff.includes(token),
    `encrypted file handoff must load configured evidence ref instead of hardcoding ${token}`);
}
const e2eeEvidenceBundle = await readSourceBundle(
  "tools/scripts/client-secure-mesh-e2ee-evidence-bundle.mjs",
  "tools/scripts/client-secure-mesh-e2ee-evidence-bundle",
  ".mjs",
);
for (const token of [
  "inspectEvidenceRef",
  "verifySecureClientMeshEvidenceAuthorityProof",
  "authorityProofRequired",
  "authorityProofAccepted",
  "clientOrAuditProvenanceAccepted",
  "missingRequiredScopeClaims",
  "missingRequiredScopeEvidenceClaims",
  "freshUntil",
  "relayMockReportRef",
  "productionBlockerStates",
  "readinessReduction",
  "authorityTrustRootProvided",
  "authorityTrustRootAccepted"
]) {
  assert(e2eeEvidenceBundle.includes(token),
    `secure mesh e2ee evidence bundle must keep current contract diagnostic token ${token}`);
}
await Promise.all([
  assertContractBoundEvidenceReport(
    "tools/scripts/client-secure-mesh-pairwise-content-audit.mjs",
    "pairwise/content crypto audit",
    "tools/scripts/client-secure-mesh-pairwise-content-audit",
  ),
  assertContractBoundEvidenceReport(
    "tools/scripts/client-secure-mesh-platform-secret-store-matrix.mjs",
    "platform secret-store binding",
    "tools/scripts/client-secure-mesh-platform-secret-store-matrix",
  ),
  assertContractBoundEvidenceReport(
    "tools/scripts/client-secure-mesh-physical-device-matrix.mjs",
    "physical device matrix"
  ),
  assertContractBoundEvidenceReport(
    "tools/scripts/client-secure-mesh-physical-evidence-manifest.mjs",
    "physical device matrix"
  ),
  assertContractBoundEvidenceReport(
    "tools/scripts/client-secure-client-relay-mock-e2e.mjs",
    "opaque relay protocol mock"
  ),
  assertContractBoundEvidenceReport(
    "tools/scripts/client-secure-mesh-encrypted-file-handoff.mjs",
    "encrypted file handoff"
  ),
  assertContractBoundEvidenceReport(
    "tools/scripts/client-secure-mesh-trust-ux.mjs",
    "trust UX"
  ),
  assertContractBoundEvidenceReport(
    "tools/scripts/client-secure-mesh-release-proof-bundle.mjs",
    "release proof bundle",
    "tools/scripts/client-secure-mesh-release-proof-bundle",
  )
]);
for (const relativePath of [
  "tools/scripts/client-secure-mesh-windows-implementation.mjs",
  "tools/scripts/client-secure-mesh-physical-evidence-manifest.mjs"
]) {
  const text = await readText(relativePath);
  assert(!text.includes("blockerStatus"),
    `${relativePath} must not publish blockerStatus; diagnosticStatus is the only non-authoritative support-report status field`);
}

}
