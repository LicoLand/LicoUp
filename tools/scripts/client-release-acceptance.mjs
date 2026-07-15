#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import {
  createPublicKey,
  generateKeyPairSync,
  sign,
  verify,
} from "node:crypto";
import {
  existsSync
} from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  loadClientReleaseTargetCatalog,
  selectClientReleaseTargets,
  validateClientReleaseTargetCatalog,
} from "./lib/client-release-targets.mjs";
import {
  artifactTreeDigest,
  resolveContainedExistingPath,
  sha256Buffer,
  sha256File,
  stableHashFileSnapshot,
  stableReadFile,
  stableReadFileSnapshot,
} from "./lib/client-release-artifact-digest.mjs";
import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  canonicalClientSourceRootsMatch,
  clientSourceStateDigest,
} from "./lib/client-source-state-digest.mjs";
import {
  ANDROID_APK_RESOURCE_LIMITS,
  inspectAndroidApkFacts,
} from "./lib/android-apk-facts.mjs";
import { LINUX_TAR_RESOURCE_LIMITS } from "./lib/linux-tar-resource-bounds.mjs";
import {
  androidPlatformCryptoEvidenceReady,
  releaseCliTargetEvidenceReady,
} from "./lib/client-release-target-evidence.mjs";
import {
  inspectBoundedMacosCodePolicy,
} from "./lib/macos-code-signature.mjs";
import { androidReleaseBuildParametersReady } from "./lib/android-release-build-policy.mjs";
import {
  createReleaseClosureChallenge,
  createReleaseInvocationNonce,
  releaseClosureChallengeDigest,
  releaseClosureEnvironment,
  releaseInvocationEnvironment,
  releaseInvocationNonceDigest,
} from "./lib/release-closure-challenge.mjs";
import {
  atomicWriteReportJson,
  removeContainedReportIfExists,
} from "./lib/safe-report-io.mjs";
import {
  captureSourceBoundJsonPolicy,
  publicPolicyBindings,
  sourceBoundPolicySnapshotsStable,
} from "./lib/source-bound-policy-snapshot.mjs";
import {
  SECURE_MESH_TRUST_UX_IOS_SUPPORT_STATUS,
  SECURE_MESH_TRUST_UX_PRODUCT_TEST_ID,
  SECURE_MESH_TRUST_UX_REPORT_SCHEMA_VERSION,
  validateSecureMeshTrustUxV2Report
} from "./lib/secure-mesh-trust-ux-reducer.mjs";
import {
  selectedReleaseBlockingSupportReady,
  validateClientSupportMatrix,
} from "./client-support-matrix.mjs";
import { pairwiseAuditDependencyReceipts } from "./lib/client-release-dependency-receipts.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const configPath = path.join(repoRoot, "tools/scripts/config/client-release-acceptance.json");
const outputPath = path.join(repoRoot, "build/reports/client-release-acceptance.json");
const args = new Set(process.argv.slice(2));
const SHA256 = /^sha256:[a-f0-9]{64}$/u;
const maxJsonBytes = 16 * 1024 * 1024;
const maxProducerBytes = 16 * 1024 * 1024;
const maxMacosSidecarBytes = 512 * 1024 * 1024;
const maxMacosArchiveBytes = 8 * 1024 * 1024 * 1024;

function artifactFileByteLimit(spec) {
  return spec?.artifactKind === "android-apk"
    ? ANDROID_APK_RESOURCE_LIMITS.maxApkBytes
    : spec?.artifactKind === "macos-distribution-archive"
      ? maxMacosArchiveBytes
    : spec?.artifactKind === "linux-tar-archive"
      ? LINUX_TAR_RESOURCE_LIMITS.maxCompressedBytes
      : maxJsonBytes;
}

function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}

function text(value) {
  return String(value || "").trim();
}

function readJson(filePath) {
  return JSON.parse(stableReadFile(filePath, { maxBytes: maxJsonBytes }).toString("utf8"));
}

function allPassed(results) {
  return Array.isArray(results) && results.length > 0 && results.every((item) => item?.ok === true);
}

function result(id, conditions) {
  const blockers = conditions.filter((item) => !item.ok).map((item) => item.blocker);
  return { id, ok: blockers.length === 0, blockers };
}

function hasPassedNativeTest(report, id) {
  return report?.nativeResults?.some((item) => item?.id === id && item?.ok === true) === true;
}

const METADATA_PAYLOAD_CLASSES = Object.freeze([
  "command",
  "result",
  "error",
  "file_manifest",
  "file_chunk",
  "service_action",
  "typing_indicator",
  "read_receipt",
  "acp_protected",
  "mls_group",
]);

function metadataResistanceEvidenceReady(report, sourceStateDigest) {
  const evidence = report?.metadataResistanceEvidence || {};
  return evidence.schemaVersion ===
      "licolite.secure-mesh.metadata-resistance-evidence.v1" &&
    evidence.sourceStateDigest === sourceStateDigest &&
    SHA256.test(text(evidence.canonicalWireReportDigest)) &&
    SHA256.test(text(evidence.residualMetadataReportDigest)) &&
    SHA256.test(text(evidence.adaptiveTopologyReportDigest)) &&
    evidence.deterministic === true && evidence.canonicalEnvelopeReady === true &&
    evidence.fixedMlsPublicAadReady === true &&
    evidence.mailboxKeyedDirectionalRotating === true &&
    evidence.mailboxBoundedOverlapReady === true &&
    evidence.hostileRelayWireCanariesAbsent === true &&
    evidence.rawBypassRetired === true &&
    JSON.stringify(evidence.payloadClasses) ===
      JSON.stringify(METADATA_PAYLOAD_CLASSES);
}

function sanitizeArtifactBinding(binding = {}) {
  return {
    targetId: text(binding.targetId),
    productVersion: text(binding.productVersion),
    artifactKind: text(binding.artifactKind),
    artifactDigest: text(binding.artifactDigest),
    runtimeExecutableDigest: text(binding.runtimeExecutableDigest),
    artifactEvidenceReportDigest: text(binding.artifactEvidenceReportDigest),
    artifactEvidenceInvocationNonceDigest:
      text(binding.artifactEvidenceInvocationNonceDigest),
    versionReady: binding.versionReady === true,
    targetReady: binding.targetReady === true,
    consumerIntegritySignatureReady:
      binding.consumerIntegritySignatureReady === true,
    publicVerificationMaterialReady:
      binding.publicVerificationMaterialReady === true,
    consumerVerificationReady: binding.consumerVerificationReady === true,
    platformSecurityReady: binding.platformSecurityReady === true,
    consumerIntegritySignatureKind:
      text(binding.consumerIntegritySignatureKind),
    installReceiptReady: binding.installReceiptReady === true,
    receiptProvenanceReady: binding.receiptProvenanceReady === true,
    receiptProducer: text(binding.receiptProducer),
    receiptSourceDigest: text(binding.receiptSourceDigest),
    receiptReportDigest: text(binding.receiptReportDigest),
    ready: binding.ready === true
  };
}

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
    "secure_mesh_pairwise_client_local_runtime_command_result_relay_round_trip"
  ].every((id) => hasPassedNativeTest(reports.pairwise, id));
  const trustV2 = validateSecureMeshTrustUxV2Report(reports.trust);
  const gates = [
    result("input-integrity", [
      { ok: inputIntegrity.ok === true, blocker: "release_input_provenance_not_ready" }
    ]),
    result("support-matrix", [
      { ok: supportMatrixReady === true, blocker: "support_matrix_missing_or_stale" }
    ]),
    result("pairwise-metadata-resistance", [
      { ok: reports.pairwise?.summary?.verificationPassed === true, blocker: "pairwise_client_evidence_not_ready" },
      { ok: reports.pairwise?.summary?.metadataResistanceReady === true, blocker: "metadata_resistance_not_ready" },
      { ok: metadataResistanceEvidenceReady(reports.pairwise, inputIntegrity.sourceStateDigest), blocker: "canonical_wire_residual_metadata_topology_evidence_not_ready" },
      { ok: pairwiseTamperRejected, blocker: "encrypted_relay_header_tamper_not_rejected" },
      { ok: reports.pairwise?.summary?.reviewSignoffReady === true, blocker: "independent_cryptographic_review_signature_not_ready" },
      { ok: reports.pairwise?.summary?.reviewerSignatureVerified === true, blocker: "independent_reviewer_signature_invalid" },
      { ok: reports.pairwise?.summary?.releaseOwnerSignatureVerified === true, blocker: "release_owner_signature_invalid" }
    ]),
    result("opaque-relay-protocol", [
      { ok: reports.relayMock?.summary?.ok === true, blocker: "relay_mock_evidence_not_ready" },
      { ok: reports.relayMock?.summary?.exactFiveOperationsObserved === true, blocker: "relay_operation_contract_not_exact" },
      { ok: reports.relayMock?.summary?.exactSixOuterFieldsObserved === true, blocker: "relay_envelope_contract_not_exact" },
      { ok: reports.relayMock?.summary?.plaintextAbsentFromServerVisibleWire === true, blocker: "relay_wire_exposed_plaintext" },
      { ok: reports.relayMock?.summary?.wireBytesMeasured === true, blocker: "relay_wire_traffic_not_measured" }
    ]),
    result("client-transport", [
      { ok: commandResultMatrixReady, blocker: "client_command_result_matrix_missing" },
      { ok: reports.relayMock?.summary?.replayRejected === true, blocker: "relay_replay_not_rejected" },
      { ok: reports.relayMock?.summary?.staleLeaseRejected === true, blocker: "relay_stale_lease_not_rejected" },
      { ok: reports.relayMock?.summary?.ackIdempotencyVerified === true, blocker: "relay_ack_idempotency_not_verified" }
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
    schemaVersion: "licolite.client-release-acceptance-report.v3",
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
      opaqueRelayAllowed: true,
      externalCoreAcceptanceRequired: false,
      optionalExternalServicesBlocking: false,
      unselectedTargetsBlocking: false,
      telegramLevelClaimed: false
    }
  };
}

function inferHostTargetId(catalog) {
  const platform = process.platform === "darwin" ? "macos" : process.platform === "win32" ? "windows" : process.platform;
  const arch = process.arch === "x64" ? "x64" : process.arch === "arm64" ? "arm64" : process.arch;
  if (platform === "linux") {
    const glibcVersion = text(process.report?.getReport?.()?.header?.glibcVersionRuntime);
    requireValue(glibcVersion,
      "Linux libc is ambiguous; set LICO_CLIENT_RELEASE_TARGETS explicitly");
  }
  const match = catalog.targets.find((target) =>
    target.platform === platform && target.arch === arch &&
    target.releaseSupported === true);
  requireValue(match, `no release-supported client target matches the current host (${platform}/${arch})`);
  return match.id;
}

function selectedTargetIds(catalog, authorityIds) {
  const explicit = Object.hasOwn(process.env, "LICO_CLIENT_RELEASE_TARGETS");
  const requested = explicit
    ? String(process.env.LICO_CLIENT_RELEASE_TARGETS).split(",").map(text)
    : [inferHostTargetId(catalog)];
  requireValue(requested.every(Boolean),
    "release target selection contains an empty token");
  requireValue(new Set(requested).size === requested.length,
    "release target selection contains duplicates");
  const requestedSet = new Set(requested);
  const normalized = authorityIds.filter((id) => requestedSet.has(id));
  requireValue(normalized.length === requested.length,
    "release target selection is outside authority");
  return normalized;
}

function validateConfig(config) {
  requireValue(config?.schemaVersion === "licolite.client-release-acceptance-config.v3", "client release acceptance config schema mismatch");
  requireValue(config?.reportSchemaVersion === "licolite.client-release-acceptance-report.v3", "client release acceptance report schema mismatch");
  requireValue(config?.producerPolicy === "same-process-required", "client release acceptance must run approved producers in the same process closure");
  const authorityIds = config?.releaseTargetAuthority?.selectedTargetIds;
  requireValue(
    config?.releaseTargetAuthority?.schemaVersion ===
      "licolite.client-release-target-authority.v1" &&
      JSON.stringify(authorityIds) === JSON.stringify([
        "macos-arm64",
        "android-arm64",
        "linux-glibc-arm64",
      ]),
    "client release target authority is invalid",
  );
  requireValue(
    text(config.artifactReceipt?.ref) &&
      text(config.artifactReceipt?.schemaVersion) ===
        "licolite.client-artifact-verification-receipts.v3" &&
      text(config.artifactReceipt?.producer) ===
        "tools/scripts/client-artifact-verification-receipts.mjs",
    "client release acceptance artifact receipt authority is incomplete"
  );
  const requiredReports = [
    "pairwise",
    "relayMock",
    "file",
    "trust",
    "acp",
    "acpArchive",
    "androidPlatformCrypto",
    "macosCli",
    "linuxCli",
    "redaction",
  ];
  requireValue(canonicalClientSourceRootsMatch(config.sourceRoots),
    "client release acceptance source roots are not canonical");
  requireValue(JSON.stringify(config.reportOrder) === JSON.stringify([
    "pairwise",
    "relayMock",
    "file",
    "trust",
    "acp",
    "acpArchive",
    "androidPlatformCrypto",
    "macosCli",
    "linuxCli",
    "redaction",
  ]), "client release acceptance producer DAG is invalid");
  requireValue(requiredReports.every((id) => {
    const spec = config.reports?.[id];
    return text(spec?.ref) && text(spec?.schemaVersion) && text(spec?.producer);
  }), "client release acceptance report producer map is incomplete");
  requireValue(
    config.reports.trust.schemaVersion === SECURE_MESH_TRUST_UX_REPORT_SCHEMA_VERSION &&
      config.reports.trust.producer === "tools/scripts/client-secure-mesh-trust-ux.mjs",
    "client release acceptance must bind Trust UX v2 to its canonical producer"
  );
  requireValue(
    JSON.stringify(config.reports.androidPlatformCrypto?.targetIds) ===
      JSON.stringify(["android-arm64"]) &&
      config.reports.androidPlatformCrypto?.producer ===
        "tools/scripts/client-android-native-tests.mjs" &&
      JSON.stringify(config.reports.macosCli?.targetIds) ===
        JSON.stringify(["macos-arm64"]) &&
      config.reports.macosCli?.producer ===
        "tools/scripts/client-secure-mesh-release-cli-proof.mjs" &&
      JSON.stringify(config.reports.linuxCli?.targetIds) ===
        JSON.stringify(["linux-glibc-arm64"]) &&
      config.reports.linuxCli?.producer ===
        "tools/scripts/client-secure-mesh-release-cli-proof.mjs" &&
      Array.isArray(config.reports.linuxCli?.args),
    "client release target-specific evidence DAG is incomplete",
  );
  for (const [targetId, artifact] of Object.entries(config.artifacts || {})) {
    requireValue(
      text(artifact.artifactKind) && text(artifact.ref) &&
        artifact.consumerVerificationPolicy ===
          "provenance-or-verifiable-signature",
      `client release acceptance artifact policy is incomplete: ${targetId}`
    );
    if (artifact.artifactKind === "android-apk") {
      requireValue(text(artifact.packageName),
        `client release acceptance Android package policy is incomplete: ${targetId}`);
    }
    if (artifact.artifactKind === "macos-distribution-archive") {
      requireValue(text(artifact.distributionManifestRef) &&
        text(artifact.installArtifactRef) && text(artifact.entitlementsRef),
      `client release acceptance macOS lineage policy is incomplete: ${targetId}`);
    }
    if (artifact.artifactKind === "linux-tar-archive") {
      requireValue(text(artifact.distributionManifestRef),
        `client release acceptance Linux manifest policy is incomplete: ${targetId}`);
    }
  }
  requireValue(
    JSON.stringify(Object.keys(config.artifacts || {})) === JSON.stringify(authorityIds),
    "client release artifact catalog does not match target authority",
  );
}

export function validateReleaseSelectionPreflight({
  catalog,
  config,
  receiptConfig,
  selectedTargetIds: requestedTargetIds,
}) {
  validateConfig(config);
  const authorityIds = config.releaseTargetAuthority.selectedTargetIds;
  const releaseSupportedIds = catalog.targets
    .filter((target) => target.releaseSupported === true)
    .map((target) => target.id);
  requireValue(JSON.stringify([...releaseSupportedIds].sort()) ===
    JSON.stringify([...authorityIds].sort()),
    "release-supported catalog targets do not match selected target authority");
  requireValue(
    receiptConfig?.schemaVersion ===
      "licolite.client-artifact-verification-receipts-config.v3" &&
      JSON.stringify(Object.keys(receiptConfig.targets || {})) ===
        JSON.stringify(authorityIds),
    "artifact receipt target authority is incomplete",
  );
  requireValue(Array.isArray(requestedTargetIds) && requestedTargetIds.length > 0 &&
    new Set(requestedTargetIds).size === requestedTargetIds.length,
  "release target selection is invalid");
  requireValue(JSON.stringify(requestedTargetIds) === JSON.stringify(
    authorityIds.filter((id) => requestedTargetIds.includes(id)),
  ), "release target selection is not in canonical authority order");
  const targetEvidenceByTarget = {
    "macos-arm64": "macosCli",
    "android-arm64": "androidPlatformCrypto",
    "linux-glibc-arm64": "linuxCli",
  };
  for (const targetId of requestedTargetIds) {
    const target = catalog.targets.find((entry) => entry.id === targetId);
    requireValue(target?.releaseSupported === true && authorityIds.includes(targetId),
      `selected target is outside release authority: ${targetId}`);
    const artifact = config.artifacts[targetId];
    const receipt = receiptConfig.targets[targetId];
    const evidenceId = targetEvidenceByTarget[targetId];
    const targetEvidence = config.reports[evidenceId];
    requireValue(artifact && receipt && evidenceId && targetEvidence,
      `selected target closure specification is missing: ${targetId}`);
    requireValue(
      receipt.platform === target.platform &&
        receipt.artifactKind === artifact.artifactKind &&
        receipt.artifactRef === artifact.ref &&
        text(receipt.distributionManifestRef) ===
          text(artifact.distributionManifestRef) &&
        receipt.consumerVerificationPolicy ===
          artifact.consumerVerificationPolicy,
      `selected target artifact/receipt specification mismatch: ${targetId}`,
    );
    requireValue(
      JSON.stringify(targetEvidence.targetIds) === JSON.stringify([targetId]),
      `selected target evidence specification mismatch: ${targetId}`,
    );
    if (targetId === "macos-arm64") {
      requireValue(receipt.evidenceArtifactKind === "macos-app-bundle" &&
        receipt.evidenceArtifactRef === artifact.installArtifactRef,
      "macOS install evidence is not bound to the distribution lineage");
    }
  }
  return true;
}

function buildRelativeRef(ref) {
  const normalized = text(ref).replaceAll("\\", "/");
  requireValue(normalized.startsWith("build/") && !normalized.includes("../"),
    "client release report reference is invalid");
  return normalized.slice("build/".length);
}

function reportSelectedForTargets(spec, selectedTargetIdSet) {
  if (!Array.isArray(spec.targetIds)) return true;
  return spec.targetIds.length > 0 &&
    spec.targetIds.some((targetId) => selectedTargetIdSet.has(targetId));
}

function closureRedactionSeedRefs(
  config,
  selectedTargets,
  artifactContext,
  targetConfig,
) {
  return [
    config.artifactReceipt.ref,
    ...selectedTargets.map((target) => targetConfig.targets?.[target.id]?.evidenceRef),
    ...(artifactContext?.ok === true
      ? (artifactContext.payload?.receipts || []).flatMap((receipt) =>
          (receipt?.dependencies || []).map((dependency) => dependency?.ref))
      : []),
  ].map(text).filter(Boolean);
}

function reportDependencyReceipts(id, payload, buildRoot) {
  if (id === "pairwise") {
    return pairwiseAuditDependencyReceipts(buildRoot, payload);
  }
  if (id === "redaction") {
    return Array.isArray(payload?.scannedRefDigests)
      ? payload.scannedRefDigests.map((entry) => ({
          id: `redaction-input:${text(entry?.ref)}`,
          ref: text(entry?.ref),
          digest: text(entry?.sha256),
        }))
      : [];
  }
  return [];
}

function reportDependenciesReady(id, dependencies) {
  if (id !== "pairwise") return true;
  return dependencies.length === 3 &&
    JSON.stringify(dependencies.map((entry) => entry.id)) === JSON.stringify([
      "pairwise-vector-corpus",
      "pairwise-review-signoff",
      "pairwise-vector-corpus-snapshot",
    ]);
}

function runAndLoadApprovedReports(
  config,
  selectedTargets,
  artifactContext,
  closureStartedAtMs,
  closureChallenge,
  receiptConfig,
) {
  const reports = {};
  const receipts = [];
  const invocationNonceDigests = new Set();
  const selectedTargetIdSet = new Set(selectedTargets.map((target) => target.id));
  const closureReportRefs = closureRedactionSeedRefs(
    config,
    selectedTargets,
    artifactContext,
    receiptConfig,
  );
  const expectedClosureChallengeDigest =
    releaseClosureChallengeDigest(closureChallenge);
  const buildRoot = path.join(repoRoot, "build");
  const producerRoot = path.join(repoRoot, "tools/scripts");
  for (const id of config.reportOrder) {
    const spec = config.reports[id];
    if (!reportSelectedForTargets(spec, selectedTargetIdSet)) continue;
    const sourcePath = path.join(repoRoot, spec.producer);
    const reportRef = buildRelativeRef(spec.ref);
    const reportPath = path.join(buildRoot, reportRef);
    let sourceDigest = "";
    let payload = {};
    let reportDigest = "";
    let generatedAtMs = Number.NaN;
    let invocationStartedAtMs = Number.NaN;
    let producerExitCode = -1;
    let producerStable = false;
    let dependencies = [];
    const invocationNonce = createReleaseInvocationNonce();
    const expectedInvocationNonceDigest =
      releaseInvocationNonceDigest(invocationNonce);
    requireValue(SHA256.test(expectedInvocationNonceDigest),
      "client release producer invocation nonce digest is missing");
    requireValue(!invocationNonceDigests.has(expectedInvocationNonceDigest),
      "client release producer invocation nonce was reused");
    invocationNonceDigests.add(expectedInvocationNonceDigest);
    try {
      const safeSourcePath = resolveContainedExistingPath(producerRoot, sourcePath, {
        expectedKind: "file",
      });
      const sourceBefore = stableHashFileSnapshot(safeSourcePath, {
        maxBytes: maxProducerBytes,
      });
      sourceDigest = sourceBefore.digest;
      invocationStartedAtMs = Date.now();
      removeContainedReportIfExists(buildRoot, reportRef);
      const selectedClosureRefs = [...new Set([
        ...closureReportRefs,
        ...receipts.filter((receipt) => receipt.ok).map((receipt) =>
          config.reports[receipt.id]?.ref),
        ...receipts.filter((receipt) => receipt.ok).flatMap((receipt) =>
          (receipt.dependencies || []).map((dependency) => dependency.ref)),
        ...(Array.isArray(spec.redactionRefs) ? spec.redactionRefs : []),
      ].map(text).filter(Boolean))];
      const command = spawnSync(process.execPath, [
        safeSourcePath,
        ...(Array.isArray(spec.args) ? spec.args.map(String) : []),
      ], {
        cwd: repoRoot,
        env: {
          ...process.env,
          ...releaseClosureEnvironment(
            closureChallenge,
            new Date(closureStartedAtMs),
          ),
          ...releaseInvocationEnvironment(invocationNonce),
          LICO_CLIENT_RELEASE_SELECTED_TARGETS:
            [...selectedTargetIdSet].join(","),
          ...(id === "redaction" ? {
            LICO_CLIENT_RELEASE_CLOSURE_REPORT_REFS_JSON:
              JSON.stringify(selectedClosureRefs),
            LICO_SECURE_MESH_REDACTION_RUN_ID:
              expectedInvocationNonceDigest,
          } : {}),
        },
        encoding: "utf8",
        stdio: "pipe",
        maxBuffer: 16 * 1024 * 1024,
        timeout: Number(spec.timeoutMs || 900_000)
      });
      producerExitCode = Number.isInteger(command.status) ? command.status : -1;
      const sourceAfter = stableHashFileSnapshot(safeSourcePath, {
        maxBytes: maxProducerBytes,
      });
      producerStable = sourceBefore.digest === sourceAfter.digest &&
        sourceBefore.device === sourceAfter.device &&
        sourceBefore.inode === sourceAfter.inode;
      if (producerExitCode === 0) {
        const safeReportPath = resolveContainedExistingPath(buildRoot, reportPath, {
          expectedKind: "file",
        });
        const reportSnapshot = stableReadFileSnapshot(safeReportPath, {
          maxBytes: maxJsonBytes,
        });
        payload = JSON.parse(reportSnapshot.bytes.toString("utf8"));
        reportDigest = sha256Buffer(reportSnapshot.bytes);
        generatedAtMs = Date.parse(String(payload.generatedAt || payload.checkedAt || ""));
        dependencies = reportDependencyReceipts(id, payload, buildRoot);
      }
    } catch {
      payload = {};
    }
    const validation = validateProducedReportReceipt({
      payload,
      spec,
      sourceDigest,
      reportDigest,
      producerExitCode,
      producerStable,
      generatedAtMs,
      invocationStartedAtMs,
      closureStartedAtMs,
      expectedClosureChallengeDigest,
      expectedInvocationNonceDigest,
      maxClockSkewMs: Number(config.maxClockSkewMs || 0),
      nowMs: Date.now(),
      dependenciesReady: reportDependenciesReady(id, dependencies),
    });
    reports[id] = validation.ok ? payload : {};
    receipts.push({
      id,
      ok: validation.ok,
      schemaVersion: text(payload.schemaVersion || spec.schemaVersion),
      producer: validation.producerMatched ? spec.producer : "producer-mismatch",
      producerExitCode,
      sourceDigest,
      reportDigest,
      freshnessReady: validation.freshnessReady,
      closureChallengeBound: validation.closureChallengeBound,
      invocationNonceDigest: expectedInvocationNonceDigest,
      dependencies,
    });
    if (validation.ok) {
      closureReportRefs.push(spec.ref);
      if (Array.isArray(spec.redactionRefs)) {
        closureReportRefs.push(...spec.redactionRefs);
      }
    }
  }
  return {
    reports,
    receipts,
    ok: receipts.length > 0 && receipts.every((item) => item.ok)
  };
}

function validateProducedReportReceipt({
  payload,
  spec,
  sourceDigest,
  reportDigest,
  producerExitCode,
  producerStable,
  generatedAtMs,
  invocationStartedAtMs,
  closureStartedAtMs,
  expectedClosureChallengeDigest,
  expectedInvocationNonceDigest,
  maxClockSkewMs,
  nowMs,
  dependenciesReady = true,
}) {
  const producer = text(payload?.verifier || payload?.generatedBy);
  const producerMatched = producer === spec.producer;
  const closureChallengeBound =
    payload?.closureChallengeDigest === expectedClosureChallengeDigest;
  const invocationNonceBound =
    payload?.invocationNonceDigest === expectedInvocationNonceDigest;
  const freshnessReady = Number.isFinite(generatedAtMs) &&
    Number.isFinite(invocationStartedAtMs) &&
    invocationStartedAtMs >= closureStartedAtMs - maxClockSkewMs &&
    generatedAtMs >= invocationStartedAtMs - maxClockSkewMs &&
    generatedAtMs >= closureStartedAtMs - maxClockSkewMs &&
    generatedAtMs <= nowMs + maxClockSkewMs;
  const ok = producerExitCode === 0 && producerStable === true &&
    payload?.schemaVersion === spec.schemaVersion &&
    producerMatched &&
    closureChallengeBound && invocationNonceBound &&
    SHA256.test(sourceDigest) &&
    SHA256.test(reportDigest) &&
    freshnessReady && dependenciesReady === true;
  return {
    ok,
    producerMatched,
    freshnessReady,
    closureChallengeBound,
    invocationNonceBound,
  };
}

function plistValue(appPath, key) {
  const result = spawnSync("/usr/libexec/PlistBuddy", ["-c", `Print :${key}`, path.join(appPath, "Contents", "Info.plist")], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
    timeout: 5_000
  });
  return result.status === 0 ? text(result.stdout) : "";
}

function artifactPlatformVersion(spec, productVersion) {
  if (spec.versionPolicy === "numeric-core") {
    return productVersion.split("-", 1)[0];
  }
  return productVersion;
}

function materializeArtifactReceipts(
  config,
  selectedTargets,
  productVersion,
  buildNumber,
  expectedSourceStateDigest,
  closureStartedAtMs,
  closureChallenge,
  expectedPolicyBindings,
) {
  const spec = config.artifactReceipt || {};
  const sourcePath = path.join(repoRoot, text(spec.producer));
  const buildRoot = path.join(repoRoot, "build");
  const reportRef = buildRelativeRef(spec.ref);
  const reportPath = path.join(buildRoot, reportRef);
  try {
    removeContainedReportIfExists(buildRoot, reportRef);
  } catch {
    return emptyArtifactReceiptContext();
  }
  if (!text(spec.ref) || !text(spec.producer) || !text(spec.schemaVersion) ||
    !existsSync(sourcePath)) {
    return emptyArtifactReceiptContext();
  }
  const selectedTargetIds = selectedTargets.map((target) => target.id);
  const expectedClosureChallengeDigest = releaseClosureChallengeDigest(closureChallenge);
  let invocationStartedAtMs = Number.NaN;
  let safeSourcePath = "";
  let sourceBefore;
  try {
    safeSourcePath = resolveContainedExistingPath(
      path.join(repoRoot, "tools/scripts"), sourcePath, {
      expectedKind: "file",
      },
    );
    sourceBefore = stableHashFileSnapshot(safeSourcePath, {
      maxBytes: maxProducerBytes,
    });
    invocationStartedAtMs = Date.now();
  } catch {
    return emptyArtifactReceiptContext();
  }
  const command = spawnSync(process.execPath, [safeSourcePath, "--targets", selectedTargetIds.join(",")], {
    cwd: repoRoot,
    env: {
      ...process.env,
      ...releaseClosureEnvironment(closureChallenge, new Date(closureStartedAtMs)),
    },
    encoding: "utf8",
    stdio: "pipe",
    maxBuffer: 4 * 1024 * 1024,
    timeout: 3_900_000
  });
  let sourceAfter;
  try {
    sourceAfter = stableHashFileSnapshot(safeSourcePath, {
      maxBytes: maxProducerBytes,
    });
  } catch {
    return emptyArtifactReceiptContext();
  }
  const producerStable = stableProducerSnapshotMatched(sourceBefore, sourceAfter);
  if (command.status !== 0 || producerStable !== true) {
    return emptyArtifactReceiptContext();
  }
  try {
    const safeReportPath = resolveContainedExistingPath(buildRoot, reportPath, {
      expectedKind: "file",
    });
    const reportSnapshot = stableReadFileSnapshot(safeReportPath, {
      maxBytes: maxJsonBytes,
    });
    const payload = JSON.parse(reportSnapshot.bytes.toString("utf8"));
    const receiptSourceDigest = sourceBefore.digest;
    const receiptReportDigest = sha256Buffer(reportSnapshot.bytes);
    const generatedAtMs = Date.parse(text(payload.generatedAt));
    const fresh = Number.isFinite(generatedAtMs) &&
      Number.isFinite(invocationStartedAtMs) &&
      invocationStartedAtMs >= closureStartedAtMs - Number(config.maxClockSkewMs || 0) &&
      generatedAtMs >= invocationStartedAtMs - Number(config.maxClockSkewMs || 0) &&
      generatedAtMs >= closureStartedAtMs - Number(config.maxClockSkewMs || 0) &&
      generatedAtMs <= Date.now() + Number(config.maxClockSkewMs || 0);
    const selectedTargetsMatched =
      JSON.stringify(payload.selectedTargetIds) === JSON.stringify(selectedTargetIds);
    const receipts = Array.isArray(payload.receipts) ? payload.receipts : [];
    const receiptTargetIds = receipts.map((entry) => text(entry?.targetId));
    const receiptTargetsMatched = receipts.length === selectedTargetIds.length &&
      new Set(receiptTargetIds).size === receiptTargetIds.length &&
      JSON.stringify(receiptTargetIds) === JSON.stringify(selectedTargetIds);
    const receiptDependencyBindingsReady = receipts.every((entry) =>
      SHA256.test(text(entry?.runtimeExecutableDigest)) &&
      (!text(config.artifacts?.[entry?.targetId]?.distributionManifestRef) ||
        SHA256.test(text(entry?.artifactManifestDigest))) &&
      Array.isArray(entry?.dependencies) && entry.dependencies.length <= 16 &&
      entry.dependencies.every((dependency) =>
        text(dependency?.id) && text(dependency?.ref).startsWith("build/") &&
        SHA256.test(text(dependency?.digest)))) &&
      receipts.every((entry) => entry.targetId !== "macos-arm64" ||
        (entry.dependencies.length === 1 &&
          entry.dependencies[0].id === "macos-user-presence-proof" &&
          entry.dependencies[0].ref ===
            "build/reports/secure-mesh-macos-keychain-user-presence-proof.json"));
    const privacyReady = payload.privacy?.redacted === true &&
      payload.privacy?.absolutePathsIncluded === false &&
      payload.privacy?.runtimeIdentityIncluded === false &&
      payload.privacy?.deviceIdentifiersIncluded === false &&
      payload.privacy?.deviceModelsIncluded === false &&
      payload.privacy?.signingIdentitiesIncluded === false &&
      payload.privacy?.keyMaterialIncluded === false &&
      payload.privacy?.rawLogsIncluded === false;
    const ok = payload.ok === true &&
      payload.schemaVersion === spec.schemaVersion &&
      payload.generatedBy === spec.producer &&
      payload.productVersion === productVersion &&
      payload.buildNumber === buildNumber &&
      payload.githubReleaseReady === payload.ok &&
      payload.nonBlockingDistributionGuidance?.blocking === false &&
      payload.closureChallengeDigest === expectedClosureChallengeDigest &&
      payload.sourceStateDigest === expectedSourceStateDigest &&
      JSON.stringify(payload.policyBindings) ===
        JSON.stringify(expectedPolicyBindings) &&
      selectedTargetsMatched && receiptTargetsMatched &&
      receiptDependencyBindingsReady && privacyReady && fresh &&
      SHA256.test(receiptSourceDigest) && SHA256.test(receiptReportDigest);
    return {
      ok,
      payload,
      producer: payload.generatedBy === spec.producer ? spec.producer : "producer-mismatch",
      receiptSourceDigest,
      receiptReportDigest,
      fresh,
      producerStable,
    };
  } catch {
    return emptyArtifactReceiptContext();
  }
}

function emptyArtifactReceiptContext() {
  return {
    ok: false,
    payload: {},
    producer: "",
    receiptSourceDigest: "",
    receiptReportDigest: "",
    fresh: false,
    producerStable: false,
  };
}

function stableProducerSnapshotMatched(before, after) {
  return before?.digest === after?.digest &&
    before?.device === after?.device &&
    before?.inode === after?.inode;
}

function digestBindingStable(expectedDigest, actualDigest) {
  return SHA256.test(text(expectedDigest)) && expectedDigest === actualDigest;
}

function verifyClosureEvidenceDigests(
  config,
  produced,
  artifactContext,
  targetConfig,
) {
  try {
    const buildRoot = path.join(repoRoot, "build");
    const producerRoot = path.join(repoRoot, "tools/scripts");
    for (const receipt of produced.receipts) {
      if (receipt.ok !== true) return false;
      const spec = config.reports[receipt.id];
      const reportPath = resolveContainedExistingPath(
        buildRoot,
        path.join(repoRoot, spec.ref),
        { expectedKind: "file" },
      );
      const producerPath = resolveContainedExistingPath(
        producerRoot,
        path.join(repoRoot, spec.producer),
        { expectedKind: "file" },
      );
      if (!digestBindingStable(receipt.reportDigest, sha256File(reportPath, {
        maxBytes: maxJsonBytes,
      })) || !digestBindingStable(receipt.sourceDigest, sha256File(producerPath, {
        maxBytes: maxProducerBytes,
      }))) {
        return false;
      }
      for (const dependency of receipt.dependencies || []) {
        const dependencyPath = resolveContainedExistingPath(
          buildRoot,
          path.join(repoRoot, dependency.ref),
          { expectedKind: "file" },
        );
        if (!digestBindingStable(
          dependency.digest,
          sha256File(dependencyPath, { maxBytes: maxJsonBytes }),
        )) return false;
      }
    }

    const canonicalReportPath = resolveContainedExistingPath(
      buildRoot,
      path.join(repoRoot, config.artifactReceipt.ref),
      { expectedKind: "file" },
    );
    const canonicalProducerPath = resolveContainedExistingPath(
      producerRoot,
      path.join(repoRoot, config.artifactReceipt.producer),
      { expectedKind: "file" },
    );
    if (!digestBindingStable(
      artifactContext.receiptReportDigest,
      sha256File(canonicalReportPath, { maxBytes: maxJsonBytes }),
    ) || !digestBindingStable(
      artifactContext.receiptSourceDigest,
      sha256File(canonicalProducerPath, { maxBytes: maxProducerBytes }),
    )) return false;

    for (const receipt of artifactContext.payload.receipts || []) {
      const target = targetConfig.targets?.[receipt.targetId];
      if (!target) return false;
      const evidencePath = resolveContainedExistingPath(
        buildRoot,
        path.join(repoRoot, target.evidenceRef),
        { expectedKind: "file" },
      );
      const evidenceProducerPath = resolveContainedExistingPath(
        producerRoot,
        path.join(repoRoot, target.evidenceProducer),
        { expectedKind: "file" },
      );
      if (!digestBindingStable(
        receipt.evidenceReportDigest,
        sha256File(evidencePath, { maxBytes: maxJsonBytes }),
      ) || !digestBindingStable(
        receipt.evidenceProducerSourceDigest,
        sha256File(evidenceProducerPath, { maxBytes: maxProducerBytes }),
      )) return false;
      for (const dependency of receipt.dependencies || []) {
        const dependencyPath = resolveContainedExistingPath(
          buildRoot,
          path.join(repoRoot, dependency.ref),
          { expectedKind: "file" },
        );
        if (!digestBindingStable(
          dependency.digest,
          sha256File(dependencyPath, { maxBytes: maxJsonBytes }),
        )) return false;
      }
    }
    return true;
  } catch {
    return false;
  }
}

function verifyArtifactReceipt(
  context,
  spec,
  targetId,
  productVersion,
  buildNumber,
  artifactDigest,
  artifactManifestDigest = "",
) {
  const entry = Array.isArray(context.payload?.receipts)
    ? context.payload.receipts.find((item) => item?.targetId === targetId)
    : null;
  const matched = context.ok === true && entry?.targetId === targetId &&
    entry?.productVersion === productVersion &&
    entry?.buildNumber === buildNumber &&
    entry?.artifactKind === spec.artifactKind &&
    entry?.artifactDigest === artifactDigest &&
    (!text(spec.distributionManifestRef) ||
      entry?.artifactManifestDigest === artifactManifestDigest) &&
    entry?.sourceStateDigest === context.payload.sourceStateDigest &&
    entry?.platformSecurityReady === true &&
    entry?.consumerVerificationReady === true;
  const receiptProvenanceReady = matched && context.fresh === true &&
    entry?.freshnessReady === true && entry?.provenanceReady === true &&
    SHA256.test(text(entry?.runtimeExecutableDigest)) &&
    SHA256.test(text(entry?.evidenceProducerSourceDigest)) &&
    SHA256.test(text(entry?.evidenceReportDigest)) &&
    SHA256.test(context.receiptSourceDigest) && SHA256.test(context.receiptReportDigest);
  return {
    matched,
    installReceiptReady: matched && entry?.installReceiptReady === true,
    receiptProvenanceReady,
    receiptProducer: context.producer,
    receiptSourceDigest: context.receiptSourceDigest,
    receiptReportDigest: context.receiptReportDigest,
    consumerIntegritySignatureReady:
      matched && entry?.consumerIntegritySignatureReady === true,
    publicVerificationMaterialReady:
      matched && entry?.publicVerificationMaterialReady === true,
    consumerVerificationReady:
      matched && entry?.consumerVerificationReady === true,
    platformSecurityReady: matched && entry?.platformSecurityReady === true,
    consumerIntegritySignatureKind: matched
      ? text(entry.consumerIntegritySignatureKind)
      : "none"
    ,runtimeExecutableDigest: matched ? text(entry.runtimeExecutableDigest) : ""
    ,artifactEvidenceReportDigest: matched ? text(entry.evidenceReportDigest) : ""
    ,artifactEvidenceInvocationNonceDigest:
      matched ? text(entry.invocationNonceDigest) : ""
    ,artifactManifestDigest:
      matched ? text(entry.artifactManifestDigest) : ""
  };
}

function verifyMacosArtifact(target, spec, clientVersion, receiptContext) {
  const productVersion = clientVersion.productVersion;
  const artifactPath = path.join(repoRoot, spec.ref);
  if (!existsSync(artifactPath)) return sanitizeArtifactBinding({ targetId: target.id });
  const safeArtifactPath = resolveContainedExistingPath(
    path.join(repoRoot, "build"),
    artifactPath,
    { expectedKind: "file" },
  );
  const safeInstallArtifactPath = resolveContainedExistingPath(
    path.join(repoRoot, "build"),
    path.join(repoRoot, spec.installArtifactRef),
    { expectedKind: "directory" },
  );
  const manifestPath = resolveContainedExistingPath(
    path.join(repoRoot, "build"),
    path.join(repoRoot, spec.distributionManifestRef),
    { expectedKind: "file" },
  );
  const manifestSnapshot = stableReadFileSnapshot(manifestPath, {
    maxBytes: maxJsonBytes,
  });
  const distribution = JSON.parse(manifestSnapshot.bytes.toString("utf8"));
  const artifactManifestDigest = sha256Buffer(manifestSnapshot.bytes);
  const artifactDigest = sha256File(safeArtifactPath, {
    maxBytes: artifactFileByteLimit(spec),
  });
  const expectedVersion = artifactPlatformVersion(spec, productVersion);
  const executable = plistValue(safeInstallArtifactPath, "CFBundleExecutable");
  const version = plistValue(safeInstallArtifactPath, "CFBundleShortVersionString");
  const buildNumber = plistValue(safeInstallArtifactPath, "CFBundleVersion");
  const executablePath = executable
    ? resolveContainedExistingPath(
        safeInstallArtifactPath,
        path.join(safeInstallArtifactPath, "Contents", "MacOS", executable),
        { expectedKind: "file" },
      )
    : "";
  const architecture = executable
    ? spawnSync("/usr/bin/lipo", ["-archs", executablePath], { cwd: repoRoot, encoding: "utf8", stdio: "pipe", timeout: 5_000 })
    : { status: 1, stdout: "" };
  const entitlementsPath = resolveContainedExistingPath(
    path.join(repoRoot, "build"),
    path.join(repoRoot, spec.entitlementsRef),
    { expectedKind: "file" },
  );
  const codePolicy = executable
    ? inspectBoundedMacosCodePolicy(
        safeInstallArtifactPath,
        executable,
        entitlementsPath,
      )
    : null;
  const signature = codePolicy?.signature || {};
  const nestedCodeReady = codePolicy?.nestedSignatures?.length > 0 &&
    codePolicy.nestedSignatures.every(({ signature: nestedSignature }) =>
      nestedSignature.verified === true &&
      nestedSignature.signatureKind === "local-identity-codesign" &&
      nestedSignature.hardenedRuntime === true &&
      nestedSignature.entitlementsEmpty === true);
  const signatureKind = signature.signatureKind === "local-identity-codesign"
    ? "identity"
    : signature.signatureKind === "local-ad-hoc-codesign" ? "adhoc" : "unknown";
  const installArtifactDigest = text(codePolicy?.artifactDigest);
  const targetReady = architecture.status === 0 &&
    text(architecture.stdout).split(/\s+/u).includes(spec.requiredArchitecture) &&
    distribution.schemaVersion === "v0.0.1:client-macos:distribution-1" &&
    distribution.targetId === target.id && distribution.platform === "macos" &&
    distribution.architecture === spec.requiredArchitecture &&
    distribution.archive === path.basename(safeArtifactPath) &&
    distribution.sha256 === artifactDigest.slice("sha256:".length) &&
    distribution.sourceStateDigest === receiptContext.payload?.sourceStateDigest &&
    distribution.installArtifactKind === "macos-app-bundle" &&
    distribution.installArtifactDigest === installArtifactDigest &&
    SHA256.test(text(distribution.bundleManifestDigest)) &&
    distribution.artifactReady === true &&
    distribution.productionReady !== true;
  const versionReady = version === expectedVersion &&
    buildNumber === String(clientVersion.buildNumber) &&
    distribution.productVersion === productVersion &&
    distribution.buildNumber === clientVersion.buildNumber;
  const receipt = verifyArtifactReceipt(
    receiptContext,
    spec,
    target.id,
    productVersion,
    clientVersion.buildNumber,
    artifactDigest,
    artifactManifestDigest,
  );
  const runtimeExecutableDigest = executablePath
    ? sha256File(resolveContainedExistingPath(
        safeInstallArtifactPath,
        path.join(safeInstallArtifactPath, "Contents/MacOS/lico-client"),
        { expectedKind: "file" },
      ), { maxBytes: maxMacosSidecarBytes })
    : "";
  const runtimeDigestReady = SHA256.test(runtimeExecutableDigest) &&
    receipt.runtimeExecutableDigest === runtimeExecutableDigest;
  const localValidationReady = signature.verified === true &&
    signature.hardenedRuntime === true && signature.entitlementsMatch === true &&
    nestedCodeReady === true &&
    SHA256.test(text(signature.entitlementsDigest)) &&
    receipt.consumerVerificationReady === true;
  return sanitizeArtifactBinding({
    targetId: target.id,
    productVersion,
    artifactKind: spec.artifactKind,
    artifactDigest,
    versionReady,
    targetReady,
    consumerIntegritySignatureReady:
      receipt.consumerIntegritySignatureReady,
    publicVerificationMaterialReady:
      receipt.publicVerificationMaterialReady,
    consumerVerificationReady: receipt.consumerVerificationReady,
    platformSecurityReady: receipt.platformSecurityReady,
    consumerIntegritySignatureKind:
      receipt.consumerIntegritySignatureKind,
    ...receipt,
    runtimeExecutableDigest,
    ready: versionReady && targetReady && localValidationReady &&
      runtimeDigestReady && receipt.installReceiptReady &&
      receipt.receiptProvenanceReady
  });
}

function verifyAndroidArtifact(target, spec, clientVersion, receiptContext) {
  const productVersion = clientVersion.productVersion;
  const artifactPath = path.join(repoRoot, spec.ref);
  if (!existsSync(artifactPath)) {
    return sanitizeArtifactBinding({ targetId: target.id, artifactKind: spec.artifactKind });
  }
  const safeArtifactPath = resolveContainedExistingPath(
    path.join(repoRoot, "build"), artifactPath, { expectedKind: "file" },
  );
  const facts = inspectAndroidApkFacts(repoRoot, safeArtifactPath, {
    requireApprovedToolchain: true,
  });
  const buildManifestPath = resolveContainedExistingPath(
    path.dirname(safeArtifactPath),
    path.join(path.dirname(safeArtifactPath), "build-manifest.json"),
    { expectedKind: "file" },
  );
  const manifest = readJson(buildManifestPath);
  const artifactDigest = facts.artifactDigest;
  const receipt = verifyArtifactReceipt(
    receiptContext, spec, target.id, productVersion, clientVersion.buildNumber, artifactDigest,
  );
  const targetReady = facts.packageName === text(spec.packageName) &&
    facts.debuggable === false &&
    JSON.stringify(facts.abis) === JSON.stringify([spec.requiredArchitecture]) &&
    facts.signerCount === 1 && facts.zipAligned === true &&
    facts.signatureSchemes.some((scheme) => ["v2", "v3", "v4"].includes(scheme)) &&
    manifest.schemaVersion === "licolite.client-android.apk-build-manifest.v3" &&
    manifest.targetId === target.id && manifest.mode === "release" &&
    androidReleaseBuildParametersReady(manifest.buildParameters) &&
    manifest.sourceStateDigest === receiptContext.payload?.sourceStateDigest &&
    manifest.packageName === facts.packageName &&
    manifest.debuggable === false &&
    JSON.stringify(manifest.abis) === JSON.stringify(facts.abis) &&
    manifest.launchableActivity === facts.launchableActivity &&
    manifest.signerCount === facts.signerCount &&
    JSON.stringify(manifest.signatureSchemes) === JSON.stringify(facts.signatureSchemes) &&
    manifest.zipAligned === true && manifest.signingKind === "local-install-keystore" &&
    manifest.signerIdentityVerified === true &&
    manifest.signingPolicySatisfied === true &&
    facts.nativeSecureMeshLibrary?.path ===
      "lib/arm64-v8a/liblico_client_native.so" &&
    facts.nativeSecureMeshLibrary?.regular === true &&
    facts.nativeSecureMeshLibrary?.unique === true &&
    facts.nativeSecureMeshLibrary?.size > 0 &&
    SHA256.test(text(facts.nativeSecureMeshLibrary?.contentDigest)) &&
    JSON.stringify(manifest.nativeSecureMeshLibrary) ===
      JSON.stringify(facts.nativeSecureMeshLibrary) &&
    manifest.nonBlockingDistributionGuidance?.blocking === false &&
    manifest.artifact?.digest === artifactDigest;
  const versionReady = facts.versionName === productVersion &&
    facts.versionCode === String(clientVersion.buildNumber) &&
    manifest.productVersion === productVersion &&
    manifest.buildNumber === clientVersion.buildNumber &&
    manifest.versionName === facts.versionName &&
    manifest.versionCode === facts.versionCode;
  const runtimeExecutableDigest = text(
    facts.nativeSecureMeshLibrary?.contentDigest,
  );
  const runtimeDigestReady = SHA256.test(runtimeExecutableDigest) &&
    receipt.runtimeExecutableDigest === runtimeExecutableDigest;
  return sanitizeArtifactBinding({
    targetId: target.id,
    productVersion,
    artifactKind: spec.artifactKind,
    artifactDigest,
    versionReady,
    targetReady,
    consumerIntegritySignatureReady:
      receipt.consumerIntegritySignatureReady,
    publicVerificationMaterialReady:
      receipt.publicVerificationMaterialReady,
    consumerVerificationReady: receipt.consumerVerificationReady,
    platformSecurityReady: receipt.platformSecurityReady,
    consumerIntegritySignatureKind:
      receipt.consumerIntegritySignatureKind,
    ...receipt,
    runtimeExecutableDigest,
    ready: versionReady && targetReady && receipt.consumerVerificationReady &&
      runtimeDigestReady && receipt.installReceiptReady &&
      receipt.receiptProvenanceReady
  });
}

function verifyLinuxArtifact(target, spec, clientVersion, receiptContext) {
  const productVersion = clientVersion.productVersion;
  const artifactPath = path.join(repoRoot, spec.ref);
  if (!existsSync(artifactPath)) {
    return sanitizeArtifactBinding({ targetId: target.id, artifactKind: spec.artifactKind });
  }
  const buildRoot = path.join(repoRoot, "build");
  const safeArtifactPath = resolveContainedExistingPath(buildRoot, artifactPath, {
    expectedKind: "file",
  });
  const artifactDigest = sha256File(safeArtifactPath, {
    maxBytes: artifactFileByteLimit(spec),
  });
  const manifestPath = resolveContainedExistingPath(
    buildRoot,
    path.join(repoRoot, spec.distributionManifestRef),
    { expectedKind: "file" },
  );
  const manifestSnapshot = stableReadFileSnapshot(manifestPath, {
    maxBytes: maxJsonBytes,
  });
  const distribution = JSON.parse(manifestSnapshot.bytes.toString("utf8"));
  const artifactManifestDigest = sha256Buffer(manifestSnapshot.bytes);
  const signaturePath = resolveContainedExistingPath(
    path.dirname(safeArtifactPath),
    `${safeArtifactPath}.sig`,
    { expectedKind: "file" },
  );
  const signatureEncoded = stableReadFile(signaturePath, {
    maxBytes: 16 * 1024,
  }).toString("utf8").trim();
  const signatureBytes = decodeCanonicalBase64(signatureEncoded);
  const receipt = verifyArtifactReceipt(
    receiptContext,
    spec,
    target.id,
    productVersion,
    clientVersion.buildNumber,
    artifactDigest,
    artifactManifestDigest,
  );
  const targetReady = distribution.targetId === target.id &&
    distribution.platform === "linux" &&
    distribution.architecture === spec.requiredArchitecture &&
    distribution.mode === "release" &&
    distribution.archive === path.basename(safeArtifactPath) &&
    distribution.sha256 === artifactDigest.slice("sha256:".length) &&
    distribution.sourceStateDigest === receiptContext.payload?.sourceStateDigest &&
    SHA256.test(text(distribution.bundleManifestDigest)) &&
    distribution.artifactReady === true &&
    distribution.nonBlockingDistributionGuidance?.githubReleaseBlocked === false;
  const versionReady = distribution.productVersion === productVersion &&
    distribution.buildNumber === clientVersion.buildNumber;
  const directSignatureReady = distribution.signature?.algorithm === "Ed25519" &&
    distribution.signature?.payload === "archive-sha256-digest" &&
    distribution.signature?.keyId === "linux-vm-acceptance" &&
    distribution.signature?.file === path.basename(signaturePath) &&
    SHA256.test(text(distribution.signature?.publicKeyFingerprint)) &&
    verifyLinuxArchiveDigestSignature(distribution, signatureBytes, artifactDigest);
  const consumerVerificationReady = directSignatureReady ||
    receipt.consumerVerificationReady === true;
  return sanitizeArtifactBinding({
    targetId: target.id,
    productVersion,
    artifactKind: spec.artifactKind,
    artifactDigest,
    versionReady,
    targetReady,
    consumerIntegritySignatureReady: directSignatureReady,
    publicVerificationMaterialReady: directSignatureReady,
    consumerVerificationReady,
    platformSecurityReady: receipt.platformSecurityReady,
    consumerIntegritySignatureKind: directSignatureReady
      ? "detached-validation"
      : receipt.consumerIntegritySignatureKind,
    ...receipt,
    ready: versionReady && targetReady && consumerVerificationReady &&
      receipt.installReceiptReady && receipt.receiptProvenanceReady,
  });
}

function decodeCanonicalBase64(value) {
  const encoded = text(value);
  if (!encoded || encoded.length > 16 * 1024 ||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u.test(encoded)) {
    return Buffer.alloc(0);
  }
  const bytes = Buffer.from(encoded, "base64");
  return bytes.length > 0 && bytes.toString("base64") === encoded
    ? bytes
    : Buffer.alloc(0);
}

function verifyLinuxArchiveDigestSignature(distribution, signatureBytes, artifactDigest) {
  try {
    if (!SHA256.test(text(artifactDigest)) || signatureBytes.length !== 64) return false;
    const publicKeyDer = decodeCanonicalBase64(
      distribution.signature?.publicKeySpkiBase64,
    );
    if (!publicKeyDer.length) return false;
    const publicKey = createPublicKey({ key: publicKeyDer, type: "spki", format: "der" });
    if (publicKey.asymmetricKeyType !== "ed25519" ||
      distribution.signature?.publicKeyFingerprint !== sha256Buffer(publicKeyDer)) {
      return false;
    }
    return verify(
      null,
      Buffer.from(artifactDigest.slice("sha256:".length), "hex"),
      publicKey,
      signatureBytes,
    );
  } catch {
    return false;
  }
}

function verifySelectedArtifacts(config, selectedTargets, clientVersion, receiptContext) {
  return Object.fromEntries(selectedTargets.map((target) => {
    const spec = config.artifacts?.[target.id];
    if (!spec) return [target.id, sanitizeArtifactBinding({ targetId: target.id })];
    if (spec.artifactKind === "macos-distribution-archive") {
      return [target.id, verifyMacosArtifact(target, spec, clientVersion, receiptContext)];
    }
    if (spec.artifactKind === "android-apk") {
      return [target.id, verifyAndroidArtifact(target, spec, clientVersion, receiptContext)];
    }
    return [target.id, verifyLinuxArtifact(target, spec, clientVersion, receiptContext)];
  }));
}

function artifactBindingMapsEqual(left, right, selectedTargets) {
  return selectedTargets.every((target) =>
    JSON.stringify(sanitizeArtifactBinding(left?.[target.id])) ===
      JSON.stringify(sanitizeArtifactBinding(right?.[target.id])));
}

function captureSelectedArtifactInputState(config, selectedTargets) {
  const buildRoot = path.join(repoRoot, "build");
  return Object.fromEntries(selectedTargets.map((target) => {
    const spec = config.artifacts[target.id];
    const artifactPath = resolveContainedExistingPath(
      buildRoot,
      path.join(repoRoot, spec.ref),
      { expectedKind: "file" },
    );
    const state = {
      artifactDigest: sha256File(artifactPath, {
        maxBytes: artifactFileByteLimit(spec),
      }),
    };
    if (spec.artifactKind === "macos-distribution-archive") {
      state.entitlementsDigest = sha256File(resolveContainedExistingPath(
        buildRoot,
        path.join(repoRoot, spec.entitlementsRef),
        { expectedKind: "file" },
      ), { maxBytes: maxJsonBytes });
      state.installArtifactDigest = artifactTreeDigest(resolveContainedExistingPath(
        buildRoot,
        path.join(repoRoot, spec.installArtifactRef),
        { expectedKind: "directory" },
      ));
      state.distributionManifestDigest = sha256File(resolveContainedExistingPath(
        buildRoot,
        path.join(repoRoot, spec.distributionManifestRef),
        { expectedKind: "file" },
      ), { maxBytes: maxJsonBytes });
    } else if (spec.artifactKind === "android-apk") {
      state.buildManifestDigest = sha256File(resolveContainedExistingPath(
        path.dirname(artifactPath),
        path.join(path.dirname(artifactPath), "build-manifest.json"),
        { expectedKind: "file" },
      ), { maxBytes: maxJsonBytes });
    } else {
      state.distributionManifestDigest = sha256File(resolveContainedExistingPath(
        buildRoot,
        path.join(repoRoot, spec.distributionManifestRef),
        { expectedKind: "file" },
      ), { maxBytes: maxJsonBytes });
      state.signatureDigest = sha256File(resolveContainedExistingPath(
        path.dirname(artifactPath),
        `${artifactPath}.sig`,
        { expectedKind: "file" },
      ), { maxBytes: 16 * 1024 });
    }
    return [target.id, state];
  }));
}

function artifactInputStatesEqual(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function validateAcceptanceReport(report) {
  requireValue(report?.schemaVersion === "licolite.client-release-acceptance-report.v3", "client release report schema version mismatch");
  requireValue(Number.isFinite(Date.parse(String(report.generatedAt || ""))), "client release report generatedAt is invalid");
  requireValue(text(report.productVersion), "client release report productVersion is required");
  requireValue(Array.isArray(report.inputIntegrity?.reports) && report.inputIntegrity.reports.length > 0, "client release input receipts are required");
  requireValue(SHA256.test(text(report.inputIntegrity.supportMatrixDigest)), "client release support matrix digest is invalid");
  requireValue(SHA256.test(text(report.inputIntegrity.targetCatalogDigest)), "client release target catalog digest is invalid");
  requireValue(SHA256.test(text(report.inputIntegrity.closureChallengeDigest)),
    "client release closure challenge digest is invalid");
  requireValue(SHA256.test(text(report.inputIntegrity.sourceStateDigest)) &&
    typeof report.inputIntegrity.sourceStateStable === "boolean" &&
    typeof report.inputIntegrity.artifactInputsStable === "boolean" &&
    typeof report.inputIntegrity.supportMatrixStable === "boolean" &&
    typeof report.inputIntegrity.targetCatalogStable === "boolean" &&
    typeof report.inputIntegrity.policyInputsStable === "boolean" &&
    typeof report.inputIntegrity.closureEvidenceDigestsStable === "boolean",
  "client release closure source or evidence stability declaration is invalid");
  const expectedPolicyBindings = [
    ["acceptance-config", "tools/scripts/config/client-release-acceptance.json"],
    ["target-catalog", "tools/client-release-targets.json"],
    ["receipt-config", "tools/scripts/config/client-artifact-verification-receipts.json"],
    ["client-version", "tools/client-version.json"],
  ];
  requireValue(Array.isArray(report.inputIntegrity.policyBindings) &&
    report.inputIntegrity.policyBindings.length === expectedPolicyBindings.length &&
    report.inputIntegrity.policyBindings.every((binding, index) =>
      binding?.id === expectedPolicyBindings[index][0] &&
      binding?.ref === expectedPolicyBindings[index][1] &&
      SHA256.test(text(binding?.digest))),
  "client release policy bindings are invalid");
  for (const receipt of report.inputIntegrity.reports) {
    requireValue(text(receipt.id) && text(receipt.schemaVersion) && text(receipt.producer), "client release producer receipt identity is incomplete");
    if (receipt.ok === true) {
      requireValue(SHA256.test(text(receipt.sourceDigest)) && SHA256.test(text(receipt.reportDigest)), "accepted client release producer receipt digest is invalid");
      requireValue(receipt.closureChallengeBound === true &&
        SHA256.test(text(receipt.invocationNonceDigest)),
      "accepted client release producer receipt is not invocation-bound");
      requireValue(Array.isArray(receipt.dependencies),
        "accepted client release producer dependency receipts are missing");
      requireValue(new Set(receipt.dependencies.map((entry) => entry.id)).size ===
        receipt.dependencies.length && receipt.dependencies.every((entry) =>
          text(entry.id) && text(entry.ref).startsWith("build/") &&
          SHA256.test(text(entry.digest))),
      "accepted client release producer dependency receipt is invalid");
    }
  }
  requireValue(new Set(report.inputIntegrity.reports.map(
    (receipt) => receipt.invocationNonceDigest,
  )).size === report.inputIntegrity.reports.length,
  "client release producer invocation nonce was reused");
  requireValue(Array.isArray(report.targetResults) && report.targetResults.length === report.selectedTargetIds.length, "client release selected-target result count mismatch");
  for (const target of report.targetResults) {
    const artifact = target.artifactBinding || {};
    requireValue(artifact.targetId === target.targetId, "client release artifact target binding mismatch");
    if (target.ok === true) {
      requireValue(artifact.ready === true && SHA256.test(text(artifact.artifactDigest)), "accepted client target lacks an exact artifact digest");
      requireValue(SHA256.test(text(artifact.runtimeExecutableDigest)) &&
        SHA256.test(text(artifact.artifactEvidenceReportDigest)) &&
        SHA256.test(text(artifact.artifactEvidenceInvocationNonceDigest)),
      "accepted client target lacks exact runtime or evidence digest binding");
      requireValue(artifact.consumerVerificationReady === true &&
        artifact.installReceiptReady === true,
      "accepted client target lacks consumer verification or local installation evidence");
      requireValue(artifact.receiptProvenanceReady === true && SHA256.test(text(artifact.receiptSourceDigest)) && SHA256.test(text(artifact.receiptReportDigest)), "accepted client target lacks receipt producer provenance");
    }
  }
  requireValue(report.githubReleaseReady === (report.blockers.length === 0), "client release readiness does not match blockers");
  requireValue(report.nonBlockingDistributionGuidance?.blocking === false,
    "distribution guidance must not block GitHub release readiness");
  if (report.githubReleaseReady) {
    requireValue(report.inputIntegrity.ok === true, "client release cannot accept unproven input integrity");
    requireValue(report.inputIntegrity.sourceStateStable === true &&
      report.inputIntegrity.artifactInputsStable === true &&
      report.inputIntegrity.supportMatrixStable === true &&
      report.inputIntegrity.targetCatalogStable === true &&
      report.inputIntegrity.policyInputsStable === true &&
      report.inputIntegrity.closureEvidenceDigestsStable === true,
    "client release cannot accept unstable closure evidence");
  }
}

function assertAcceptancePrivacy(value) {
  if (Array.isArray(value)) {
    value.forEach(assertAcceptancePrivacy);
    return;
  }
  if (value && typeof value === "object") {
    for (const [key, nested] of Object.entries(value)) {
      requireValue(![
        "stdout",
        "stderr",
        "rawLog",
        "deviceSerial",
        "deviceModel",
        "signingIdentity",
        "keyMaterial",
      ].includes(key) &&
        !/(?:(?:signer|certificate|team).*(?:digest|sha(?:256)?|fingerprint)|(?:digest|sha(?:256)?|fingerprint).*(?:signer|certificate|team))/iu.test(key),
      "client release report contains a forbidden privacy field");
      assertAcceptancePrivacy(nested);
    }
    return;
  }
  if (typeof value === "string") {
    requireValue(!/(?:^|["'\s])\/(?:Users|home|private|tmp|var\/folders)\//u.test(value) &&
      !/-----BEGIN [A-Z ]*PRIVATE KEY-----/u.test(value) &&
      !/Bearer\s+(?!\[redacted\])\S+/u.test(value),
    "client release report contains a forbidden privacy value");
  }
}

function runSupportMatrixCheck(selectedTargetIds) {
  const matrixPath = resolveContainedExistingPath(
    path.join(repoRoot, "docs/releases"),
    path.join(repoRoot, "docs/releases/client-support-matrix.md"),
    { expectedKind: "file" },
  );
  const catalogPath = resolveContainedExistingPath(
    path.join(repoRoot, "tools"),
    path.join(repoRoot, "tools/client-support-matrix.json"),
    { expectedKind: "file" },
  );
  const before = stableHashFileSnapshot(matrixPath, { maxBytes: 4 * 1024 * 1024 });
  const catalogBefore = stableReadFileSnapshot(catalogPath, {
    maxBytes: 4 * 1024 * 1024,
  });
  const validated = validateClientSupportMatrix(JSON.parse(
    catalogBefore.bytes.toString("utf8"),
  ));
  const selectedBlockingServicesSupported =
    selectedReleaseBlockingSupportReady(validated, selectedTargetIds);
  const command = spawnSync(process.execPath, ["tools/scripts/client-support-matrix.mjs", "check"], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
    maxBuffer: 4 * 1024 * 1024,
    timeout: 60_000,
  });
  const after = stableHashFileSnapshot(matrixPath, { maxBytes: 4 * 1024 * 1024 });
  const catalogAfter = stableHashFileSnapshot(catalogPath, {
    maxBytes: 4 * 1024 * 1024,
  });
  const catalogSnapshot = {
    digest: sha256Buffer(catalogBefore.bytes),
    device: catalogBefore.device,
    inode: catalogBefore.inode,
  };
  return {
    ready: command.status === 0 && selectedBlockingServicesSupported &&
      stableProducerSnapshotMatched(before, after) &&
      stableProducerSnapshotMatched(catalogSnapshot, catalogAfter),
    snapshot: catalogSnapshot,
    snapshots: [
      { path: matrixPath, snapshot: before },
      { path: catalogPath, snapshot: catalogSnapshot },
    ],
    selectedBlockingServicesSupported,
  };
}

function selfTestAndroidTrustEvidence(ready) {
  return {
    ok: ready,
    present: ready,
    platform: "android",
    physicalDevice: ready,
    peerVerified: ready,
    capabilityReportValid: ready,
    mandatoryFoundationComplete: ready,
    custodyStrategy: ready ? "os_secure_store" : "",
    safeCustodyReady: ready,
    portableConfigPrivateMaterialAbsent: ready,
    restartReplayReady: ready,
    lifecycleFfiReady: ready,
    trustLifecycleReady: ready,
    qrVerificationReady: ready,
    sasVerificationReady: ready,
    keyChangeBlocksSensitive: ready,
    rotateLifecycleReady: ready,
    revokeBlocksSensitive: ready,
    recoveryRequiresConfirmation: ready,
    status: ready ? "android-physical-trust-lifecycle-verified" : "missing"
  };
}

function selfTestTrustReport({
  productTrustUxReady = true,
  androidPhysicalTrustReady = true,
  macosTrustReceiptReady = true,
  schemaVersion = SECURE_MESH_TRUST_UX_REPORT_SCHEMA_VERSION,
  includeUnknownAuthorityField = false
} = {}) {
  const selectedTargetReleaseReady =
    productTrustUxReady && androidPhysicalTrustReady && macosTrustReceiptReady;
  const summary = {
    verificationPassed: true,
    mobileNativeTrustActionsReady: true,
    productTrustUxTestsReady: productTrustUxReady,
    productTrustUxReady,
    androidPhysicalTrustLifecycleReady: androidPhysicalTrustReady,
    macosTrustReceiptReady,
    iosSupportStatus: SECURE_MESH_TRUST_UX_IOS_SUPPORT_STATUS,
    iosReleaseGate: false,
    selectedTargetReleaseReady,
    productionReady: false,
    releaseReady: selectedTargetReleaseReady,
    ...(includeUnknownAuthorityField ? { unrecognizedTrustAuthorityOverride: true } : {})
  };
  return {
    schemaVersion,
    ok: true,
    productionReady: false,
    releaseReady: selectedTargetReleaseReady,
    productTestResults: [{
      id: SECURE_MESH_TRUST_UX_PRODUCT_TEST_ID,
      ok: productTrustUxReady
    }],
    physicalTrustEvidence: {
      android: selfTestAndroidTrustEvidence(androidPhysicalTrustReady),
      ios: {
        ok: false,
        supportStatus: SECURE_MESH_TRUST_UX_IOS_SUPPORT_STATUS,
        releaseGate: false
      }
    },
    selectedTargetAcceptance: {
      selectedTargets: ["macos", "android"],
      productTrustUxReady,
      androidPhysicalTrustReady,
      macosTrustReceiptReady,
      iosSupportStatus: SECURE_MESH_TRUST_UX_IOS_SUPPORT_STATUS,
      iosReleaseGate: false,
      selectedTargetReleaseReady
    },
    summary
  };
}

function selfTestReports({
  plaintextReady = true,
  tamperReady = true,
  reviewSignoffReady = true,
  productTrustUxReady = true,
  androidPhysicalTrustReady = true,
  macosTrustReceiptReady = true,
  trustSchemaVersion = SECURE_MESH_TRUST_UX_REPORT_SCHEMA_VERSION,
  includeUnknownAuthorityField = false
} = {}) {
  const passed = [{ id: "check", ok: true }];
  return {
    pairwise: {
      summary: {
        verificationPassed: true,
        metadataResistanceReady: true,
        reviewSignoffReady,
        reviewerSignatureVerified: reviewSignoffReady,
        releaseOwnerSignatureVerified: reviewSignoffReady,
      },
      metadataResistanceEvidence: {
        schemaVersion: "licolite.secure-mesh.metadata-resistance-evidence.v1",
        sourceStateDigest: `sha256:${"a".repeat(64)}`,
        canonicalWireReportDigest: `sha256:${"d".repeat(64)}`,
        residualMetadataReportDigest: `sha256:${"e".repeat(64)}`,
        adaptiveTopologyReportDigest: `sha256:${"f".repeat(64)}`,
        deterministic: true,
        canonicalEnvelopeReady: true,
        fixedMlsPublicAadReady: true,
        mailboxKeyedDirectionalRotating: true,
        mailboxBoundedOverlapReady: true,
        hostileRelayWireCanariesAbsent: true,
        rawBypassRetired: true,
        payloadClasses: [...METADATA_PAYLOAD_CLASSES],
      },
      nativeResults: tamperReady ? [
        { id: "secure_mesh_pairwise_encrypted_relay_header_hides_ratchet_structure_and_rejects_tamper", ok: true },
        { id: "secure_mesh_pairwise_pc_pc_command_result_relay_round_trip", ok: true },
        { id: "secure_mesh_pairwise_mobile_pc_command_result_relay_round_trip", ok: true },
        { id: "secure_mesh_pairwise_pc_mobile_command_result_relay_round_trip", ok: true },
        { id: "secure_mesh_pairwise_mobile_mobile_command_result_relay_round_trip", ok: true },
        { id: "secure_mesh_pairwise_cli_desktop_command_result_relay_round_trip", ok: true },
        { id: "secure_mesh_pairwise_client_local_runtime_command_result_relay_round_trip", ok: true }
      ] : []
    },
    relayMock: { summary: {
      ok: true,
      exactFiveOperationsObserved: true,
      exactSixOuterFieldsObserved: true,
      plaintextAbsentFromServerVisibleWire: plaintextReady,
      wireBytesMeasured: true,
      replayRejected: true,
      staleLeaseRejected: true,
      ackIdempotencyVerified: true
    } },
    file: { summary: { verificationPassed: true, multiRecipientEndpointSpecificResealProofReady: true, releaseBuiltDesktopFilePolicyReady: true, releaseBuiltDesktopReadyPlatforms: ["macos"], androidPhysicalEndpointFilePolicyReady: true, androidPhysicalReceiveConfirmationReady: true } },
    trust: selfTestTrustReport({
      productTrustUxReady,
      androidPhysicalTrustReady,
      macosTrustReceiptReady,
      schemaVersion: trustSchemaVersion,
      includeUnknownAuthorityField
    }),
    acp: {
      summary: { clientEnvelopeReady: true, gatewaySupportEvidenceProvided: false },
      sourceResults: passed,
      nativeResults: passed
    },
    acpArchive: { summary: { archiveLayerReady: true, releaseFilePolicyReady: true, releaseBuiltDesktopReadyPlatforms: ["macos"] }, sourceResults: passed, nativeResults: passed },
    androidPlatformCrypto: {
      schemaVersion: "licolite.secure-mesh.android-platform-crypto-acceptance.v1",
      verifier: "tools/scripts/client-android-native-tests.mjs",
      ok: true,
      platform: "android",
      redacted: true,
      rawPrivateMaterialIncluded: false,
      rawPlaintextIncluded: false,
      rawPublicWireBytesIncluded: false,
      summary: {
        ok: true,
        platformCryptoAcceptanceReady: true,
        platformCustodyContractReady: true,
        platformAuthorizationContractReady: true,
        rustFfiActionContractReady: true,
        mlsMemberRemoveReleaseActionReady: true,
        unknownReleaseActionsFailClosed: true,
        nativeTestClassCount: 6,
        privatePathsIncluded: false,
      },
    },
    macosCli: selfTestReleaseCliReport("macos", "3"),
    redaction: { ok: true, summary: { reportRedactionReady: true, hitCount: 0 } },
    externalAcceptance: { productionReady: false },
    optionalExternalServices: { gemini: "unsupported", kimi: "unverified" }
  };
}

function selfTestReleaseCliReport(platform, digestDigit) {
  return {
    schemaVersion: "licolite.secure-mesh.release-cli-proof-report.v1",
    verifier: "tools/scripts/client-secure-mesh-release-cli-proof.mjs",
    ok: true,
    platform,
    artifactKind: "release-cli-binary",
    sourceStateDigest: `sha256:${"a".repeat(64)}`,
    cliArtifactDigest: `sha256:${digestDigit.repeat(64)}`,
    redacted: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    summary: {
      releaseCliProofReady: true,
      statusReady: true,
      commandExecuteReady: true,
      commandReplayRejected: true,
      filePolicyReady: true,
      fileRouteReady: true,
      fileReceiveDestinationReady: true,
      fileReceiveConfirmationReady: true,
      trustPolicyReady: true,
    },
  };
}

function runSelfTest({ schemaFixture = false } = {}) {
  const selected = [
    { id: "macos-arm64", platform: "macos", arch: "arm64", supported: true, releaseSupported: true },
    { id: "android-arm64", platform: "android", arch: "arm64", supported: true, releaseSupported: true }
  ];
  const readyIntegrity = {
    ok: true,
    productVersion: "1.2.3",
    sourceStateDigest: `sha256:${"a".repeat(64)}`,
    sourceStateStable: true,
    artifactInputsStable: true,
    supportMatrixStable: true,
    targetCatalogStable: true,
    policyInputsStable: true,
    closureEvidenceDigestsStable: true,
    closureStartedAt: "2030-01-01T00:00:00.000Z",
    closureChallengeDigest: `sha256:${"9".repeat(64)}`,
    supportMatrixDigest: `sha256:${"8".repeat(64)}`,
    targetCatalogDigest: `sha256:${"7".repeat(64)}`,
    policyBindings: [
      ["acceptance-config", "tools/scripts/config/client-release-acceptance.json", "1"],
      ["target-catalog", "tools/client-release-targets.json", "2"],
      ["receipt-config", "tools/scripts/config/client-artifact-verification-receipts.json", "3"],
      ["client-version", "tools/client-version.json", "4"],
    ].map(([id, ref, digit]) => ({ id, ref, digest: `sha256:${digit.repeat(64)}` })),
    reports: [{
      id: "linuxCli",
      ok: true,
      schemaVersion: "licolite.secure-mesh.release-cli-proof-report.v1",
      producer: "tools/scripts/client-secure-mesh-release-cli-proof.mjs",
      producerExitCode: 0,
      sourceDigest: `sha256:${"1".repeat(64)}`,
      reportDigest: `sha256:${"2".repeat(64)}`,
      freshnessReady: true,
      closureChallengeBound: true,
      invocationNonceDigest: `sha256:${"3".repeat(64)}`,
      dependencies: [],
    }]
  };
  const readyArtifactFor = (targetId, artifactKind, digestDigit) => ({
    targetId,
    productVersion: "1.2.3",
    artifactKind,
    artifactDigest: `sha256:${digestDigit.repeat(64)}`,
    runtimeExecutableDigest: `sha256:${digestDigit.repeat(64)}`,
    artifactEvidenceReportDigest: targetId === "android-arm64"
      ? `sha256:${"b".repeat(64)}`
      : `sha256:${"d".repeat(64)}`,
    artifactEvidenceInvocationNonceDigest: targetId === "android-arm64"
      ? `sha256:${"c".repeat(64)}`
      : `sha256:${"e".repeat(64)}`,
    versionReady: true,
    targetReady: true,
    consumerIntegritySignatureReady: false,
    publicVerificationMaterialReady: false,
    consumerVerificationReady: true,
    platformSecurityReady: true,
    consumerIntegritySignatureKind: "platform-local-validation",
    installReceiptReady: true,
    receiptProvenanceReady: true,
    receiptProducer: "tools/scripts/fixture-receipt.mjs",
    receiptSourceDigest: `sha256:${"6".repeat(64)}`,
    receiptReportDigest: `sha256:${"7".repeat(64)}`,
    ready: true
  });
  const readyArtifact = {
    "macos-arm64": readyArtifactFor(
      "macos-arm64",
      "macos-distribution-archive",
      "3",
    ),
    "android-arm64": readyArtifactFor("android-arm64", "android-apk", "8")
  };
  const base = {
    selectedTargets: selected,
    supportMatrixReady: true,
    inputIntegrity: readyIntegrity,
    artifactBindings: readyArtifact
  };
  const externalAndUnselected = reduceClientReleaseAcceptance({ ...base, reports: selfTestReports() });
  if (schemaFixture) return externalAndUnselected;
  requireValue(externalAndUnselected.githubReleaseReady,
    `macOS and Android selected targets must pass without iOS or external evidence: ${externalAndUnselected.blockers.join(",")}`);
  const productTrustMissing = reduceClientReleaseAcceptance({
    ...base,
    reports: selfTestReports({ productTrustUxReady: false })
  });
  requireValue(!productTrustMissing.githubReleaseReady && productTrustMissing.blockers.includes("client_product_trust_ux_not_ready"), "missing product trust UX must fail closed");
  const unsupportedSchema = reduceClientReleaseAcceptance({
    ...base,
    reports: selfTestReports({ trustSchemaVersion: "licolite.secure-mesh.trust-ux-report.unsupported" })
  });
  requireValue(!unsupportedSchema.githubReleaseReady && unsupportedSchema.blockers.includes("client_trust_v2_contract_not_ready"), "unsupported Trust UX schema must fail closed");
  const unknownAuthority = reduceClientReleaseAcceptance({
    ...base,
    reports: selfTestReports({ includeUnknownAuthorityField: true })
  });
  requireValue(!unknownAuthority.githubReleaseReady && unknownAuthority.blockers.includes("client_trust_v2_contract_not_ready"), "unknown trust authority field must fail closed");
  const missingSelected = reduceClientReleaseAcceptance({
    ...base,
    artifactBindings: {
      ...readyArtifact,
      "macos-arm64": {
        ...readyArtifact["macos-arm64"],
        platformSecurityReady: false,
        ready: false,
      },
    },
    reports: selfTestReports(),
  });
  requireValue(!missingSelected.githubReleaseReady && missingSelected.blockers.some((item) => item.startsWith("selected_platform_security_not_ready:")), "selected missing evidence must block");
  const plaintext = reduceClientReleaseAcceptance({ ...base, reports: selfTestReports({ plaintextReady: false }) });
  requireValue(!plaintext.githubReleaseReady && plaintext.blockers.some((item) => item.includes("plaintext")), "mock relay plaintext observation must fail closed");
  const tamper = reduceClientReleaseAcceptance({ ...base, reports: selfTestReports({ tamperReady: false }) });
  requireValue(!tamper.githubReleaseReady && tamper.blockers.includes("encrypted_relay_header_tamper_not_rejected"), "mock relay tamper must fail closed");
  const legacyMetadataReports = selfTestReports();
  delete legacyMetadataReports.pairwise.metadataResistanceEvidence;
  const legacyMetadata = reduceClientReleaseAcceptance({
    ...base,
    reports: legacyMetadataReports,
  });
  requireValue(!legacyMetadata.githubReleaseReady && legacyMetadata.blockers.includes(
    "canonical_wire_residual_metadata_topology_evidence_not_ready",
  ), "legacy metadata-resistance boolean without complete wire evidence must fail closed");
  const unsignedReview = reduceClientReleaseAcceptance({
    ...base,
    reports: selfTestReports({ reviewSignoffReady: false }),
  });
  requireValue(!unsignedReview.githubReleaseReady &&
    unsignedReview.blockers.includes("independent_cryptographic_review_signature_not_ready") &&
    unsignedReview.blockers.includes("independent_reviewer_signature_invalid") &&
    unsignedReview.blockers.includes("release_owner_signature_invalid"),
  "boolean-only independent audit signoff must fail closed");
  const ambiguousCustody = reduceClientReleaseAcceptance({
    ...base,
    artifactBindings: {
      ...readyArtifact,
      "macos-arm64": {
        ...readyArtifact["macos-arm64"],
        platformSecurityReady: false,
        ready: false,
      },
    },
    reports: selfTestReports(),
  });
  requireValue(!ambiguousCustody.githubReleaseReady && ambiguousCustody.blockers.some((item) => item.startsWith("selected_platform_security_not_ready:")), "missing exact adaptive custody evidence must fail closed");
  const forgedInput = reduceClientReleaseAcceptance({
    ...base,
    inputIntegrity: { ...readyIntegrity, ok: false },
    reports: selfTestReports()
  });
  requireValue(!forgedInput.githubReleaseReady && forgedInput.blockers.includes("release_input_provenance_not_ready"), "editable report booleans without current producer provenance must fail closed");
  const missingArtifact = reduceClientReleaseAcceptance({
    ...base,
    artifactBindings: {},
    reports: selfTestReports()
  });
  requireValue(!missingArtifact.githubReleaseReady && missingArtifact.blockers.some((item) => item.startsWith("selected_target_exact_artifact_not_ready:")), "missing exact selected-target artifact must fail closed");
  const unsignedArtifact = reduceClientReleaseAcceptance({
    ...base,
    artifactBindings: {
      ...readyArtifact,
      "macos-arm64": { ...readyArtifact["macos-arm64"], consumerVerificationReady: false, ready: false }
    },
    reports: selfTestReports()
  });
  requireValue(!unsignedArtifact.githubReleaseReady && unsignedArtifact.blockers.some((item) => item.startsWith("selected_target_consumer_verification_not_ready:")), "artifact without consumer verification must fail closed");
  const missingReceipt = reduceClientReleaseAcceptance({
    ...base,
    artifactBindings: {
      ...readyArtifact,
      "macos-arm64": { ...readyArtifact["macos-arm64"], installReceiptReady: false, receiptProvenanceReady: false, ready: false }
    },
    reports: selfTestReports()
  });
  requireValue(!missingReceipt.githubReleaseReady && missingReceipt.blockers.some((item) => item.startsWith("selected_target_install_receipt_not_ready:")), "artifact without exact local install receipt must fail closed");
  const distributionGuidance = reduceClientReleaseAcceptance({
    ...base,
    artifactBindings: {
      ...readyArtifact,
      "macos-arm64": {
        ...readyArtifact["macos-arm64"],
        nonBlockingDistributionStatus: "ready",
      },
    },
    reports: selfTestReports(),
  });
  requireValue(distributionGuidance.githubReleaseReady,
    "distribution guidance must not block GitHub release readiness");
  const receiptChallengeDigest = `sha256:${"1".repeat(64)}`;
  const receiptNonceDigest = `sha256:${"2".repeat(64)}`;
  const receiptFixture = {
    payload: {
      schemaVersion: "fixture.v1",
      verifier: "tools/scripts/fixture.mjs",
      closureChallengeDigest: receiptChallengeDigest,
      invocationNonceDigest: receiptNonceDigest,
    },
    spec: { schemaVersion: "fixture.v1", producer: "tools/scripts/fixture.mjs" },
    sourceDigest: `sha256:${"4".repeat(64)}`,
    reportDigest: `sha256:${"5".repeat(64)}`,
    producerExitCode: 0,
    producerStable: true,
    generatedAtMs: 10_001,
    invocationStartedAtMs: 10_000,
    closureStartedAtMs: 10_000,
    expectedClosureChallengeDigest: receiptChallengeDigest,
    expectedInvocationNonceDigest: receiptNonceDigest,
    maxClockSkewMs: 5,
    nowMs: 10_010
  };
  requireValue(validateProducedReportReceipt(receiptFixture).ok, "current approved producer receipt must validate");
  requireValue(!validateProducedReportReceipt({
    ...receiptFixture,
    payload: { ...receiptFixture.payload, verifier: "tools/scripts/forged.mjs" }
  }).ok, "forged producer identity must fail closed");
  requireValue(!validateProducedReportReceipt({
    ...receiptFixture,
    generatedAtMs: 9_000,
  }).ok, "stale producer output must fail closed");
  requireValue(!validateProducedReportReceipt({
    ...receiptFixture,
    producerExitCode: 1,
  }).ok, "failed producer must not reuse an old green report");
  requireValue(!validateProducedReportReceipt({
    ...receiptFixture,
    producerStable: false,
  }).ok, "mutated producer source must fail closed");
  requireValue(!validateProducedReportReceipt({
    ...receiptFixture,
    payload: {
      ...receiptFixture.payload,
      invocationNonceDigest: `sha256:${"3".repeat(64)}`,
    },
  }).ok, "producer output with the wrong invocation nonce must fail closed");
  requireValue(!validateProducedReportReceipt({
    ...receiptFixture,
    reportDigest: "sha256:editable-json"
  }).ok, "invalid report input digest must fail closed");
  requireValue(digestBindingStable(
    `sha256:${"a".repeat(64)}`,
    `sha256:${"a".repeat(64)}`,
  ) && !digestBindingStable(
    `sha256:${"a".repeat(64)}`,
    `sha256:${"b".repeat(64)}`,
  ), "replaced physical evidence digest must fail closed");
  const producerSnapshot = {
    digest: `sha256:${"c".repeat(64)}`,
    device: 1,
    inode: 2,
  };
  requireValue(stableProducerSnapshotMatched(
    producerSnapshot,
    { ...producerSnapshot },
  ) && !stableProducerSnapshotMatched(
    producerSnapshot,
    { ...producerSnapshot, inode: 3 },
  ), "replaced canonical receipt producer must fail closed");
  const artifactBindingFixture = {
    "macos-arm64": sanitizeArtifactBinding({
      targetId: "macos-arm64",
      artifactDigest: `sha256:${"a".repeat(64)}`,
    }),
  };
  requireValue(artifactBindingMapsEqual(
    artifactBindingFixture,
    structuredClone(artifactBindingFixture),
    [{ id: "macos-arm64" }],
  ) && !artifactBindingMapsEqual(
    artifactBindingFixture,
    {
      "macos-arm64": {
        ...artifactBindingFixture["macos-arm64"],
        artifactDigest: `sha256:${"b".repeat(64)}`,
      },
    },
    [{ id: "macos-arm64" }],
  ), "replaced final artifact input must fail closed");
  requireValue(artifactInputStatesEqual(
    { linux: { artifactDigest: `sha256:${"a".repeat(64)}`, signatureDigest: "one" } },
    { linux: { artifactDigest: `sha256:${"a".repeat(64)}`, signatureDigest: "one" } },
  ) && !artifactInputStatesEqual(
    { linux: { artifactDigest: `sha256:${"a".repeat(64)}`, signatureDigest: "one" } },
    { linux: { artifactDigest: `sha256:${"a".repeat(64)}`, signatureDigest: "two" } },
  ), "replaced artifact sidecar input must fail closed");
  const { publicKey: linuxPublicKey, privateKey: linuxPrivateKey } =
    generateKeyPairSync("ed25519");
  const linuxPublicKeyDer = linuxPublicKey.export({ type: "spki", format: "der" });
  const linuxArtifactDigest = `sha256:${"d".repeat(64)}`;
  const linuxSignature = sign(
    null,
    Buffer.from(linuxArtifactDigest.slice("sha256:".length), "hex"),
    linuxPrivateKey,
  );
  const linuxDistribution = {
    signature: {
      publicKeySpkiBase64: linuxPublicKeyDer.toString("base64"),
      publicKeyFingerprint: sha256Buffer(linuxPublicKeyDer),
    },
  };
  requireValue(verifyLinuxArchiveDigestSignature(
    linuxDistribution,
    linuxSignature,
    linuxArtifactDigest,
  ) && !verifyLinuxArchiveDigestSignature(
    linuxDistribution,
    linuxSignature,
    `sha256:${"e".repeat(64)}`,
  ), "Linux archive signature direct verification must fail closed");
  let privacyRejected = false;
  try {
    assertAcceptancePrivacy({ fixture: ["", "Users", "fixture", "secret"].join("/") });
  } catch {
    privacyRejected = true;
  }
  requireValue(privacyRejected, "acceptance privacy scan must reject local paths");
  privacyRejected = false;
  try {
    const hostileCertificateDigestKey = ["certificate", "Identity", "Digest"].join("");
    assertAcceptancePrivacy({
      [hostileCertificateDigestKey]: `sha256:${"f".repeat(64)}`,
    });
  } catch {
    privacyRejected = true;
  }
  requireValue(privacyRejected,
    "acceptance privacy scan must reject stable signing identity digests");
  const defaultVerifySource = stableReadFile(
    path.join(repoRoot, "tools/run-client-verify.mjs"),
    { maxBytes: 2 * 1024 * 1024 },
  ).toString("utf8");
  const packageScripts = readJson(path.join(repoRoot, "package.json")).scripts;
  requireValue(defaultVerifySource.includes("client:verify:secure-mesh-e2ee-evidence:diagnostic"), "default verification must retain the cross-product diagnostic");
  requireValue(!defaultVerifySource.includes('["npm", ["run", "client:verify:secure-mesh-e2ee-evidence"]]'), "default verification must not run strict A10 acceptance");
  requireValue(defaultVerifySource.includes(
    "client:verify:client-release-acceptance:self-test",
  ), "default verification must run the side-effect-free client release acceptance self-test");
  requireValue(!defaultVerifySource.includes(
    '["npm", ["run", "client:verify:client-release-acceptance"]]',
  ), "default verification must not run the side-effecting client release reducer");
  requireValue(packageScripts["client:verify:github-release"]?.includes(
    "client-github-release-acceptance.mjs",
  ), "explicit GitHub release must run the artifact-only GitHub reducer");
  requireValue(packageScripts["client:verify:product-line-security"]?.includes(
    "client-release-acceptance.mjs",
  ), "product-line security must retain the full client evidence reducer");
  for (const scriptName of [
    "client:verify:release-artifact-io:self-test",
    "client:verify:release-dependency-receipts:self-test",
    "client:verify:source-state-digest:self-test",
    "client:verify:linux-tar-resource-bounds:self-test",
    "client:verify:android-apk-zip-facts:self-test",
    "client:verify:android-release-toolchain:self-test",
    "client:verify:macos-distribution:self-test",
    "client:verify:review-signoff:self-test",
    "client:verify:release-target-evidence:self-test",
    "client:verify:release-report-schema:self-test",
    "client:verify:macos-nested-code-bounds:self-test",
    "client:verify:package-client:self-test",
    "client:native:smoke:policy:self-test",
    "client:verify:closure-producer-writer:self-test",
  ]) {
    requireValue(defaultVerifySource.includes(scriptName),
    `default verification must run ${scriptName}`);
  }
  requireValue(packageScripts["client:verify:secure-mesh-platform-acceptance"]?.includes("client:verify:secure-mesh-e2ee-evidence"), "strict Secure Mesh platform acceptance must remain explicitly callable");
  const preflightConfig = readJson(configPath);
  const preflightCatalog = loadClientReleaseTargetCatalog();
  const preflightReceiptConfig = readJson(path.join(
    repoRoot,
    "tools/scripts/config/client-artifact-verification-receipts.json",
  ));
  requireValue(validateReleaseSelectionPreflight({
    catalog: preflightCatalog,
    config: preflightConfig,
    receiptConfig: preflightReceiptConfig,
    selectedTargetIds: preflightConfig.releaseTargetAuthority.selectedTargetIds,
  }), "authorized release target preflight failed");
  const mismatchedLineageReceiptConfig = structuredClone(preflightReceiptConfig);
  mismatchedLineageReceiptConfig.targets["linux-glibc-arm64"].distributionManifestRef =
    "build/apps/desktop/distribution/linux-arm64/retired-manifest.json";
  let mismatchedLineageRejected = false;
  try {
    validateReleaseSelectionPreflight({
      catalog: preflightCatalog,
      config: preflightConfig,
      receiptConfig: mismatchedLineageReceiptConfig,
      selectedTargetIds: ["linux-glibc-arm64"],
    });
  } catch {
    mismatchedLineageRejected = true;
  }
  requireValue(mismatchedLineageRejected,
    "mismatched release artifact manifest lineage was accepted");
  const supportMatrixFixture = readJson(path.join(
    repoRoot,
    "tools/client-support-matrix.json",
  ));
  for (const target of supportMatrixFixture.targets) {
    if (!["macos-arm64", "android-arm64", "linux-glibc-arm64"].includes(
      target.targetId,
    )) continue;
    target.overrides = {
      ...(target.overrides || {}),
      "client-shell": "supported",
      "secure-mesh-pairwise": "supported",
    };
  }
  const validatedSupportMatrix = validateClientSupportMatrix(supportMatrixFixture);
  requireValue(selectedReleaseBlockingSupportReady(
    validatedSupportMatrix,
    ["macos-arm64", "android-arm64", "linux-glibc-arm64"],
  ), "selected supported blocking services were rejected");
  supportMatrixFixture.targets.find((target) =>
    target.targetId === "android-arm64").overrides["secure-mesh-pairwise"] = "preview";
  requireValue(!selectedReleaseBlockingSupportReady(
    validateClientSupportMatrix(supportMatrixFixture),
    ["macos-arm64", "android-arm64", "linux-glibc-arm64"],
  ), "selected preview blocking service was accepted");
  const childProofRef =
    "build/reports/secure-mesh-macos-keychain-user-presence-proof.json";
  requireValue(closureRedactionSeedRefs(
    preflightConfig,
    [{ id: "macos-arm64" }],
    { ok: true, payload: { receipts: [{ dependencies: [{ ref: childProofRef }] }] } },
    preflightReceiptConfig,
  ).includes(childProofRef),
  "selected closure redaction omitted macOS child proof dependency");
  for (const targetId of ["macos-x64", "linux-musl-arm64", "windows-x64"]) {
    let rejected = false;
    try {
      validateReleaseSelectionPreflight({
        catalog: preflightCatalog,
        config: preflightConfig,
        receiptConfig: preflightReceiptConfig,
        selectedTargetIds: [targetId],
      });
    } catch {
      rejected = true;
    }
    requireValue(rejected, `non-authoritative target passed preflight: ${targetId}`);
  }
  let authorityOrderRejected = false;
  try {
    validateReleaseSelectionPreflight({
      catalog: preflightCatalog,
      config: preflightConfig,
      receiptConfig: preflightReceiptConfig,
      selectedTargetIds: [...preflightConfig.releaseTargetAuthority.selectedTargetIds]
        .reverse(),
    });
  } catch {
    authorityOrderRejected = true;
  }
  requireValue(authorityOrderRejected,
    "noncanonical release target authority order was accepted");
  const previousTargetSelection = process.env.LICO_CLIENT_RELEASE_TARGETS;
  const previousTargetSelectionPresent = Object.hasOwn(
    process.env,
    "LICO_CLIENT_RELEASE_TARGETS",
  );
  let emptyTokenRejected = false;
  try {
    process.env.LICO_CLIENT_RELEASE_TARGETS = "macos-arm64,";
    selectedTargetIds(
      preflightCatalog,
      preflightConfig.releaseTargetAuthority.selectedTargetIds,
    );
  } catch {
    emptyTokenRejected = true;
  } finally {
    if (previousTargetSelectionPresent) {
      process.env.LICO_CLIENT_RELEASE_TARGETS = previousTargetSelection;
    } else {
      delete process.env.LICO_CLIENT_RELEASE_TARGETS;
    }
  }
  requireValue(emptyTokenRejected, "explicit empty release target token was accepted");
  return { ok: true, caseCount: 43 };
}

function main() {
  if (args.has("--self-test")) {
    requireValue(args.size === 1, "client release self-test arguments are invalid");
    console.log(JSON.stringify(runSelfTest()));
    return;
  }
  if (args.has("--schema-fixture")) {
    requireValue(args.size === 1, "client release schema fixture arguments are invalid");
    console.log(JSON.stringify(runSelfTest({ schemaFixture: true })));
    return;
  }
  removeContainedReportIfExists(
    path.join(repoRoot, "build"),
    path.relative(path.join(repoRoot, "build"), outputPath),
  );
  requireValue(args.size === 0, "client release acceptance arguments are invalid");
  const sourceStateDigest = clientSourceStateDigest(
    repoRoot,
    CANONICAL_CLIENT_SOURCE_ROOTS,
  );
  const safeConfigPath = resolveContainedExistingPath(
    path.join(repoRoot, "tools/scripts/config"),
    configPath,
    { expectedKind: "file" },
  );
  const targetCatalogPath = resolveContainedExistingPath(
    path.join(repoRoot, "tools"),
    path.join(repoRoot, "tools/client-release-targets.json"),
    { expectedKind: "file" },
  );
  const receiptConfigPath = resolveContainedExistingPath(
    path.join(repoRoot, "tools/scripts/config"),
    path.join(
      repoRoot,
      "tools/scripts/config/client-artifact-verification-receipts.json",
    ),
    { expectedKind: "file" },
  );
  const clientVersionPath = resolveContainedExistingPath(
    path.join(repoRoot, "tools"),
    path.join(repoRoot, "tools/client-version.json"),
    { expectedKind: "file" },
  );
  const policySnapshots = [
    captureSourceBoundJsonPolicy({
      allowedRoot: path.join(repoRoot, "tools/scripts/config"),
      filePath: safeConfigPath,
      id: "acceptance-config",
      ref: "tools/scripts/config/client-release-acceptance.json",
    }),
    captureSourceBoundJsonPolicy({
      allowedRoot: path.join(repoRoot, "tools"),
      filePath: targetCatalogPath,
      id: "target-catalog",
      ref: "tools/client-release-targets.json",
    }),
    captureSourceBoundJsonPolicy({
      allowedRoot: path.join(repoRoot, "tools/scripts/config"),
      filePath: receiptConfigPath,
      id: "receipt-config",
      ref: "tools/scripts/config/client-artifact-verification-receipts.json",
    }),
    captureSourceBoundJsonPolicy({
      allowedRoot: path.join(repoRoot, "tools"),
      filePath: clientVersionPath,
      id: "client-version",
      ref: "tools/client-version.json",
    }),
  ];
  const policyBindings = publicPolicyBindings(policySnapshots);
  const config = policySnapshots[0].payload;
  validateConfig(config);
  const targetCatalogBefore = policySnapshots[1];
  const catalog = validateClientReleaseTargetCatalog(policySnapshots[1].payload);
  const requestedTargetIds = selectedTargetIds(
    catalog,
    config.releaseTargetAuthority.selectedTargetIds,
  );
  const receiptConfig = policySnapshots[2].payload;
  validateReleaseSelectionPreflight({
    catalog,
    config,
    receiptConfig,
    selectedTargetIds: requestedTargetIds,
  });
  const selectedTargets = selectClientReleaseTargets(catalog, requestedTargetIds);
  const clientVersion = policySnapshots[3].payload;
  const productVersion = text(clientVersion.productVersion);
  requireValue(productVersion && Number.isInteger(clientVersion.buildNumber) &&
    clientVersion.buildNumber > 0, "client version manifest is invalid");
  const closureStartedAtMs = Date.now();
  const closureChallenge = createReleaseClosureChallenge();
  const receiptPolicyBindings = policyBindings.filter((binding) =>
    ["receipt-config", "client-version"].includes(binding.id));
  const artifactReceiptContext = materializeArtifactReceipts(
    config,
    selectedTargets,
    productVersion,
    clientVersion.buildNumber,
    sourceStateDigest,
    closureStartedAtMs,
    closureChallenge,
    receiptPolicyBindings,
  );
  const produced = runAndLoadApprovedReports(
    config,
    selectedTargets,
    artifactReceiptContext,
    closureStartedAtMs,
    closureChallenge,
    receiptConfig,
  );
  const initialArtifactInputState = captureSelectedArtifactInputState(
    config,
    selectedTargets,
  );
  const initialArtifactBindings = verifySelectedArtifacts(
    config,
    selectedTargets,
    clientVersion,
    artifactReceiptContext
  );
  const supportMatrix = runSupportMatrixCheck(requestedTargetIds);
  const closureEvidenceDigestsStable = verifyClosureEvidenceDigests(
    config,
    produced,
    artifactReceiptContext,
    receiptConfig,
  );
  const artifactBindings = verifySelectedArtifacts(
    config,
    selectedTargets,
    clientVersion,
    artifactReceiptContext,
  );
  const finalArtifactInputState = captureSelectedArtifactInputState(
    config,
    selectedTargets,
  );
  const artifactInputsStable = artifactBindingMapsEqual(
    initialArtifactBindings,
    artifactBindings,
    selectedTargets,
  ) && artifactInputStatesEqual(
    initialArtifactInputState,
    finalArtifactInputState,
  );
  const supportMatrixStable = supportMatrix.ready === true &&
    supportMatrix.snapshots.every((entry) => stableProducerSnapshotMatched(
      entry.snapshot,
      stableHashFileSnapshot(entry.path, { maxBytes: 4 * 1024 * 1024 }),
    ));
  const targetCatalogAfter = stableHashFileSnapshot(targetCatalogPath, {
    maxBytes: 4 * 1024 * 1024,
  });
  const targetCatalogStable = stableProducerSnapshotMatched(
    targetCatalogBefore,
    targetCatalogAfter,
  );
  const policyInputsStable = sourceBoundPolicySnapshotsStable(policySnapshots);
  const sourceStateStable =
    clientSourceStateDigest(repoRoot, config.sourceRoots) === sourceStateDigest;
  const inputIntegrity = {
    ok: produced.ok && artifactReceiptContext.ok === true &&
      closureEvidenceDigestsStable && artifactInputsStable && sourceStateStable &&
      supportMatrixStable && targetCatalogStable && policyInputsStable,
    productVersion,
    sourceStateDigest,
    sourceStateStable,
    artifactInputsStable,
    supportMatrixStable,
    targetCatalogStable,
    policyInputsStable,
    closureEvidenceDigestsStable,
    closureStartedAt: new Date(closureStartedAtMs).toISOString(),
    closureChallengeDigest: releaseClosureChallengeDigest(closureChallenge),
    supportMatrixDigest: supportMatrix.snapshot.digest,
    targetCatalogDigest: targetCatalogBefore.digest,
    policyBindings,
    reports: produced.receipts
  };
  const report = reduceClientReleaseAcceptance({
    selectedTargets,
    supportMatrixReady: supportMatrixStable,
    reports: produced.reports,
    inputIntegrity,
    artifactBindings
  });
  validateAcceptanceReport(report);
  assertAcceptancePrivacy(report);
  atomicWriteReportJson(
    path.join(repoRoot, "build"),
    path.relative(path.join(repoRoot, "build"), outputPath),
    report,
  );
  console.log(JSON.stringify({
    ok: report.ok,
    githubReleaseReady: report.githubReleaseReady,
    selectedTargetIds: report.selectedTargetIds,
    blockerCount: report.blockers.length,
    report: path.relative(repoRoot, outputPath)
  }));
  if (!report.ok) process.exitCode = 1;
}

try {
  main();
} catch (error) {
  console.error(JSON.stringify({
    ok: false,
    error: args.has("--self-test")
      ? text(error instanceof Error ? error.message : error).slice(0, 240)
      : "client_release_acceptance_failed",
  }));
  process.exitCode = 1;
}
