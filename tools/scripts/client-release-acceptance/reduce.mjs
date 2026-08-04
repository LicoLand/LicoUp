import {
  androidPlatformCryptoEvidenceReady,
  releaseCliTargetEvidenceReady,
} from "../lib/client-release-target-evidence.mjs";
import {
  SECURE_MESH_TRUST_UX_IOS_SUPPORT_STATUS,
  SECURE_MESH_TRUST_UX_PRODUCT_TEST_ID,
  SECURE_MESH_TRUST_UX_REPORT_SCHEMA_VERSION,
  validateSecureMeshTrustUxV2Report,
} from "../lib/secure-mesh-trust-ux-reducer.mjs";
import { sanitizeArtifactBinding } from "./sanitize-binding.mjs";
import { allPassed, requireValue, result, text } from "./util.mjs";
import {
  hasPassedNativeTest,
  metadataResistanceEvidenceReady,
} from "./evidence.mjs";
import { SHA256 } from "./constants.mjs";
import {
  licoArcBadTowerAcceptanceCoverage,
} from "../lib/licoarc-badtower-acceptance-report.mjs";
import {
  LICOARC_BADTOWER_CANDIDATE_BINDING_KEY,
} from "../lib/licoarc-badtower-candidate-binding.mjs";

export function reduceClientReleaseAcceptance({
  selectedTargets,
  supportMatrixReady,
  reports,
  inputIntegrity = { ok: false, reports: [] },
  artifactBindings = {}
}) {
  requireValue(Array.isArray(selectedTargets) && selectedTargets.length > 0, "selected client release targets are required");
  const pairwiseTamperRejected = hasPassedNativeTest(
    reports.pairwise,
    "secure_mesh_pairwise_encrypted_relay_header_hides_ratchet_structure_and_rejects_tamper"
  );
  const commandResultMatrixReady = [
    "secure_mesh_pairwise_pc_pc_command_result_relay_round_trip",
    "secure_mesh_pairwise_mobile_pc_command_result_relay_round_trip",
    "secure_mesh_pairwise_pc_mobile_command_result_relay_round_trip",
    "secure_mesh_pairwise_mobile_mobile_command_result_relay_round_trip",
    "secure_mesh_pairwise_cli_desktop_command_result_relay_round_trip",
    "secure_mesh_pairwise_agent_host_command_result_relay_round_trip"
  ].every((id) => hasPassedNativeTest(reports.pairwise, id));
  const stationCandidateBindings =
    artifactBindings[LICOARC_BADTOWER_CANDIDATE_BINDING_KEY] || {};
  const stationAcceptance = licoArcBadTowerAcceptanceCoverage(
    reports.stationAcceptance,
    {
      clientCandidateDigest: inputIntegrity.sourceStateDigest,
      protocolCandidateDigest:
        stationCandidateBindings.protocolCandidateDigest,
      stationCandidateDigest: stationCandidateBindings.stationCandidateDigest,
    },
  );
  const trustV2 = validateSecureMeshTrustUxV2Report(reports.trust);
  const gates = [
    result("input-integrity", [
      { ok: inputIntegrity.ok === true, blocker: "release_input_provenance_not_ready" },
      { ok: inputIntegrity.candidateInputsStable === true, blocker: "licoarc_badtower_candidate_inputs_unstable" },
    ]),
    result("support-matrix", [
      { ok: supportMatrixReady === true, blocker: "support_matrix_missing_or_stale" }
    ]),
    result("pairwise-metadata-resistance", [
      { ok: reports.pairwise?.summary?.verificationPassed === true, blocker: "pairwise_client_evidence_not_ready" },
      { ok: reports.pairwise?.summary?.metadataResistanceReady === true, blocker: "metadata_resistance_not_ready" },
      { ok: metadataResistanceEvidenceReady(reports.pairwise, inputIntegrity.sourceStateDigest), blocker: "canonical_wire_residual_metadata_topology_evidence_not_ready" },
      { ok: pairwiseTamperRejected, blocker: "encrypted_private_header_tamper_not_rejected" },
      { ok: reports.pairwise?.summary?.reviewSignoffReady === true, blocker: "independent_cryptographic_review_signature_not_ready" },
      { ok: reports.pairwise?.summary?.reviewerSignatureVerified === true, blocker: "independent_reviewer_signature_invalid" },
      { ok: reports.pairwise?.summary?.releaseOwnerSignatureVerified === true, blocker: "release_owner_signature_invalid" }
    ]),
    result("licoarc-badtower-interoperability", [
      { ok: stationAcceptance.reportValid, blocker: "licoarc_badtower_acceptance_not_ready" },
      { ok: stationAcceptance.candidateBindingsReady, blocker: "licoarc_badtower_candidate_bindings_stale" },
      { ok: stationAcceptance.freshEndpointCount === 2, blocker: "fresh_endpoint_pair_not_verified" },
      { ok: stationAcceptance.positiveExchange, blocker: "positive_exchange_not_verified" },
      { ok: stationAcceptance.roundTrip, blocker: "round_trip_not_verified" },
      { ok: stationAcceptance.stationPlaintextAbsent, blocker: "station_plaintext_absence_not_verified" },
      { ok: stationAcceptance.nonConformantEnvelopeRejected, blocker: "non_conformant_envelope_not_rejected" },
      { ok: stationAcceptance.transportHintsNonAuthoritative, blocker: "transport_hints_authority_not_rejected" },
      { ok: stationAcceptance.exactFiveOuterFields, blocker: "licoarc_outer_field_contract_not_exact" },
      { ok: stationAcceptance.mobileFfiDispatch, blocker: "mobile_ffi_dispatch_not_verified" },
      { ok: stationAcceptance.typedPendingObserved, blocker: "typed_pending_state_not_observed" },
      { ok: stationAcceptance.durableResultReceiptAcknowledged, blocker: "durable_result_receipt_not_acknowledged" },
    ]),
    result("client-e2ee", [
      { ok: commandResultMatrixReady, blocker: "client_command_result_matrix_missing" },
    ]),
    result("client-file", [
      { ok: reports.file?.summary?.verificationPassed === true, blocker: "encrypted_file_client_evidence_not_ready" },
      { ok: reports.file?.summary?.multiRecipientEndpointSpecificResealProofReady === true, blocker: "endpoint_specific_file_reseal_not_ready" }
    ]),
    result("client-trust", [
      { ok: trustV2.contractReady, blocker: "client_trust_v2_contract_not_ready" },
      { ok: reports.trust?.summary?.verificationPassed === true, blocker: "client_trust_evidence_not_ready" },
      { ok: reports.trust?.summary?.mobileNativeTrustActionsReady === true, blocker: "client_trust_actions_not_ready" },
      { ok: trustV2.productTrustUxReady, blocker: "client_product_trust_ux_not_ready" },
    ]),
    result("client-acp", [
      { ok: reports.acp?.summary?.clientEnvelopeReady === true, blocker: "client_acp_envelope_not_ready" },
      { ok: allPassed(reports.acp?.sourceResults), blocker: "client_acp_source_checks_failed" },
      { ok: allPassed(reports.acp?.nativeResults), blocker: "client_acp_native_checks_failed" },
      { ok: reports.acpArchive?.summary?.archiveLayerReady === true, blocker: "client_acp_archive_layer_not_ready" },
      { ok: allPassed(reports.acpArchive?.sourceResults), blocker: "client_acp_archive_source_checks_failed" },
      { ok: allPassed(reports.acpArchive?.nativeResults), blocker: "client_acp_archive_native_checks_failed" }
    ]),
    result("report-redaction", [
      { ok: reports.redaction?.ok === true, blocker: "client_report_redaction_verifier_failed" },
      { ok: reports.redaction?.summary?.reportRedactionReady === true, blocker: "client_reports_not_redaction_ready" },
      { ok: reports.redaction?.summary?.hitCount === 0, blocker: "client_report_privacy_hits_present" }
    ])
  ];

  const targetResults = selectedTargets.map((target) => {
    const artifact = artifactBindings[target.id] || {};
    const conditions = [
      { ok: target.releaseSupported === true, blocker: `selected_target_unsupported:${target.id}` },
      { ok: artifact.platformSecurityReady === true, blocker: `selected_platform_security_not_ready:${target.id}` },
      { ok: artifact.ready === true, blocker: `selected_target_exact_artifact_not_ready:${target.id}` },
      { ok: artifact.targetId === target.id, blocker: `selected_target_artifact_target_mismatch:${target.id}` },
      { ok: artifact.targetReady === true, blocker: `selected_target_artifact_architecture_mismatch:${target.id}` },
      { ok: artifact.versionReady === true, blocker: `selected_target_artifact_version_mismatch:${target.id}` },
      { ok: SHA256.test(String(artifact.artifactDigest || "")), blocker: `selected_target_artifact_digest_missing:${target.id}` },
      { ok: artifact.consumerVerificationReady === true, blocker: `selected_target_consumer_verification_not_ready:${target.id}` },
      { ok: artifact.installReceiptReady === true, blocker: `selected_target_install_receipt_not_ready:${target.id}` },
      { ok: artifact.receiptProvenanceReady === true, blocker: `selected_target_receipt_provenance_not_ready:${target.id}` }
    ];
    if (target.platform === "android") {
      conditions.push(
        { ok: androidPlatformCryptoEvidenceReady(reports.androidPlatformCrypto),
          blocker: `selected_android_platform_crypto_evidence_not_ready:${target.id}` }
      );
    } else if (target.platform === "ios") {
      conditions.push(
        {
          ok: false,
          blocker: `selected_ios_${SECURE_MESH_TRUST_UX_IOS_SUPPORT_STATUS}:${target.id}`
        }
      );
    } else if (target.platform === "macos") {
      conditions.push(
        { ok: releaseCliTargetEvidenceReady(reports.macosCli, {
          platform: "macos",
          sourceStateDigest: inputIntegrity.sourceStateDigest,
          runtimeExecutableDigest: artifact.runtimeExecutableDigest,
        }), blocker: `selected_macos_same_closure_cli_evidence_not_ready:${target.id}` }
      );
    } else if (target.platform === "linux") {
      conditions.push(
        { ok: releaseCliTargetEvidenceReady(reports.linuxCli, {
          platform: "ubuntu-linux-arm64",
          sourceStateDigest: inputIntegrity.sourceStateDigest,
          runtimeExecutableDigest: artifact.runtimeExecutableDigest,
        }), blocker: `selected_linux_same_closure_cli_evidence_not_ready:${target.id}` }
      );
    } else {
      conditions.push({ ok: false, blocker: `selected_target_runtime_evidence_not_supported:${target.id}` });
    }
    return {
      targetId: target.id,
      selected: true,
      artifactBinding: sanitizeArtifactBinding(artifact),
      ...result(`target:${target.id}`, conditions)
    };
  });
  const blockers = [...new Set([...gates, ...targetResults].flatMap((item) => item.blockers))].sort();
  return {
    schemaVersion: "licomesh.client-release-acceptance-report.v4",
    ok: blockers.length === 0,
    githubReleaseReady: blockers.length === 0,
    nonBlockingDistributionGuidance: {
      blocking: false,
      storeListingStatus: "not-configured",
      platformSigningStatus: "not-configured",
      notarizationStatus: "not-configured",
      publicDownloadStatus: "not-configured",
      updateChannelStatus: "not-configured",
      rollbackChannelStatus: "not-configured",
    },
    selectedTargetIds: selectedTargets.map((target) => target.id),
    generatedAt: new Date().toISOString(),
    productVersion: text(inputIntegrity.productVersion),
    inputIntegrity,
    gateResults: gates,
    targetResults,
    blockers,
    scope: {
      clientOwnedOnly: true,
      untrustedStationAllowed: true,
      externalCoreAcceptanceRequired: false,
      optionalExternalServicesBlocking: false,
      unselectedTargetsBlocking: false,
      telegramLevelClaimed: false
    }
  };
}
