import { SHA256 } from "./constants.mjs";
import { sanitizeArtifactBinding } from "./sanitize-binding.mjs";
import { requireValue, text } from "./util.mjs";

export function validateAcceptanceReport(report) {
  requireValue(report?.schemaVersion === "licomesh.client-release-acceptance-report.v4", "client release report schema version mismatch");
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
    typeof report.inputIntegrity.candidateInputsStable === "boolean" &&
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
      report.inputIntegrity.candidateInputsStable === true &&
      report.inputIntegrity.supportMatrixStable === true &&
      report.inputIntegrity.targetCatalogStable === true &&
      report.inputIntegrity.policyInputsStable === true &&
      report.inputIntegrity.closureEvidenceDigestsStable === true,
    "client release cannot accept unstable closure evidence");
  }
}
