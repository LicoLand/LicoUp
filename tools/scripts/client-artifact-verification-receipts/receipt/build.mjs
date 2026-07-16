import { validateLinuxVmPackageReceipt } from "../../lib/secure-mesh-linux-evidence.mjs";
import { digestPattern, producer } from "../constants.mjs";
import { ReceiptValidationError } from "../errors.mjs";
import { assertReceiptPrivacy } from "../privacy.mjs";
import { requireValue, text, validatePolicyBindings } from "../util.mjs";
import { validateConfig } from "../validate-config.mjs";
import { validateAndroidEvidence } from "../validate-evidence/android.mjs";
import { validateCommonEvidence } from "../validate-evidence/common.mjs";
import { validateLinuxEvidence } from "../validate-evidence/linux.mjs";
import { validateMacosEvidence } from "../validate-evidence/macos.mjs";
import { emptyReceipt } from "./empty.mjs";

export function buildCanonicalReceiptReport({
  config,
  selectedTargetIds,
  productVersion,
  buildNumber,
  sourceStateDigest,
  closureChallengeDigest,
  closureStartedAtMs,
  targetInputs,
  policyBindings,
  nowMs = Date.now(),
  linuxValidator = validateLinuxVmPackageReceipt,
}) {
  validateConfig(config);
  requireValue(Array.isArray(selectedTargetIds) && selectedTargetIds.length > 0,
    "receipt_target_selection_empty");
  requireValue(new Set(selectedTargetIds).size === selectedTargetIds.length,
    "receipt_target_selection_duplicate");
  requireValue(selectedTargetIds.every((id) => config.targets[id]),
    "receipt_target_selection_unsupported");
  requireValue(text(productVersion), "receipt_product_version_missing");
  requireValue(Number.isInteger(buildNumber) && buildNumber > 0,
    "receipt_build_number_missing");
  requireValue(digestPattern.test(text(sourceStateDigest)), "receipt_source_digest_missing");
  requireValue(digestPattern.test(text(closureChallengeDigest)),
    "receipt_closure_challenge_missing");
  requireValue(Number.isFinite(closureStartedAtMs), "receipt_closure_start_missing");
  validatePolicyBindings(policyBindings);

  const receipts = selectedTargetIds.map((targetId) => {
    const spec = config.targets[targetId];
    const input = targetInputs[targetId] || {};
    const receipt = emptyReceipt({
      targetId,
      productVersion,
      buildNumber,
      sourceStateDigest,
      closureChallengeDigest,
      spec,
      input,
    });
    try {
      const common = validateCommonEvidence(
        input.payload,
        spec,
        input,
        closureChallengeDigest,
        closureStartedAtMs,
        nowMs,
        config,
      );
      const context = {
        targetId,
        productVersion,
        buildNumber,
        sourceStateDigest,
        artifactDigest: input.artifactDigest,
        artifactManifestDigest: input.artifactManifestDigest,
        artifactLineageReady: input.artifactLineageReady,
        evidenceArtifactDigest: input.evidenceArtifactDigest,
        spec,
      };
      const facts = spec.platform === "macos"
        ? validateMacosEvidence(input.payload, context)
        : spec.platform === "android"
          ? validateAndroidEvidence(input.payload, context)
          : validateLinuxEvidence(input.payload, context, linuxValidator);
      Object.assign(receipt, common, facts);
      receipt.installReceiptReady =
        receipt.installReady === true && receipt.launchReady === true &&
        receipt.smokeReady === true && receipt.freshnessReady === true &&
        receipt.provenanceReady === true;
      receipt.consumerVerificationReady = receipt.provenanceReady === true ||
        (receipt.consumerIntegritySignatureReady === true &&
          receipt.publicVerificationMaterialReady === true);
      receipt.ready = receipt.installReceiptReady &&
        receipt.consumerVerificationReady === true;
    } catch (error) {
      receipt.blockers = [error instanceof ReceiptValidationError
        ? error.code
        : "approved_evidence_invalid"];
    }
    return receipt;
  });
  const report = {
    schemaVersion: config.reportSchemaVersion,
    generatedAt: new Date(nowMs).toISOString(),
    generatedBy: producer,
    selectedTargetIds: [...selectedTargetIds],
    productVersion,
    buildNumber,
    sourceStateDigest,
    closureChallengeDigest,
    policyBindings: policyBindings.map((binding) => ({ ...binding })),
    ok: receipts.every((receipt) => receipt.ready === true),
    githubReleaseReady: receipts.every((receipt) => receipt.ready === true),
    nonBlockingDistributionGuidance: {
      blocking: false,
      storeListingStatus: "not-configured",
      platformSigningStatus: "not-configured",
      notarizationStatus: "not-configured",
      publicDownloadStatus: "not-configured",
      updateChannelStatus: "not-configured",
      rollbackChannelStatus: "not-configured",
    },
    receipts,
    privacy: {
      redacted: true,
      absolutePathsIncluded: false,
      runtimeIdentityIncluded: false,
      deviceIdentifiersIncluded: false,
      deviceModelsIncluded: false,
      signingIdentitiesIncluded: false,
      keyMaterialIncluded: false,
      rawLogsIncluded: false,
    },
  };
  requireValue(new Set(receipts.map((receipt) => receipt.invocationNonceDigest)).size ===
    receipts.length, "receipt_invocation_nonce_reused");
  assertReceiptPrivacy(report);
  return report;
}
