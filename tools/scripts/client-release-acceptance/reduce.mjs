import { sanitizeArtifactBinding } from "./sanitize-binding.mjs";
import { requireValue, result } from "./util.mjs";
import { SHA256 } from "./constants.mjs";

export function reduceClientReleaseAcceptance({
  selectedTargets,
  supportMatrixReady,
  reports,
  inputIntegrity = { ok: false, reports: [] },
  artifactBindings = {}
}) {
  requireValue(Array.isArray(selectedTargets) && selectedTargets.length > 0, "selected client release targets are required");
  const gates = [
    result("input-integrity", [
      { ok: inputIntegrity.ok === true, blocker: "release_input_provenance_not_ready" },
    ]),
    result("support-matrix", [
      { ok: supportMatrixReady === true, blocker: "support_matrix_missing_or_stale" }
    ]),
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
    productVersion: String(inputIntegrity.productVersion || "").trim(),
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
