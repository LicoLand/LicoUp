import { digestPattern } from "../constants.mjs";
import { ReceiptValidationError } from "../errors.mjs";
import { requireValue, text } from "../util.mjs";

export function validateLinuxEvidence(payload, context, linuxValidator) {
  try {
    linuxValidator(payload, context.sourceStateDigest);
  } catch {
    throw new ReceiptValidationError("linux_evidence_not_ready");
  }
  requireValue(payload.target === "ubuntu-linux-arm64", "evidence_target_mismatch");
  requireValue(payload.sourceBinding?.sourceStateDigest === context.sourceStateDigest,
    "evidence_source_digest_mismatch");
  requireValue(context.artifactLineageReady === true &&
    digestPattern.test(text(context.artifactManifestDigest)),
  "artifact_distribution_lineage_mismatch");
  requireValue(payload.sourceBinding?.archiveDigest === context.artifactDigest,
    "evidence_artifact_digest_mismatch");
  requireValue(digestPattern.test(text(payload.sourceBinding?.nativeClientDigest)),
    "linux_native_client_digest_missing");
  requireValue(payload.package?.validationSignature === true &&
    payload.package?.signatureVerified === true, "evidence_signature_policy_mismatch");
  requireValue(payload.summary?.installReceiptReady === true,
    "linux_install_receipt_not_ready");
  requireValue(payload.summary?.sessionLaunchReady === true, "linux_launch_not_ready");
  requireValue(payload.summary?.smokeReady === true && payload.summary?.privacyReady === true,
    "linux_smoke_not_ready");
  requireValue(payload.productVersion === context.productVersion &&
    payload.buildNumber === context.buildNumber,
  "evidence_version_mismatch");
  return {
    consumerIntegritySignatureKind: "detached-validation",
    consumerIntegritySignatureReady: true,
    publicVerificationMaterialReady: true,
    platformSecurityReady: true,
    installReady: true,
    launchReady: true,
    smokeReady: true,
    runtimeExecutableDigest: payload.sourceBinding.nativeClientDigest,
    dependencies: [],
  };
}
