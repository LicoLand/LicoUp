import { digestPattern } from "../constants.mjs";
import { requireValue, text } from "../util.mjs";

export function validateMacosEvidence(payload, context) {
  const receipt = Array.isArray(payload.receipts)
    ? payload.receipts.find((entry) =>
      entry?.targetId === context.spec.evidenceTargetId)
    : null;
  const dependency = Array.isArray(payload.dependencies) && payload.dependencies.length === 1
    ? payload.dependencies[0]
    : null;
  requireValue(payload.ok === true && payload.platform === "macos", "macos_evidence_not_ready");
  requireValue(payload.redacted === true && payload.reportLeakScan === true,
    "macos_evidence_not_redacted");
  requireValue(payload.rawRuntimeOutputIncluded === false && payload.rawPrivateMaterialIncluded === false,
    "macos_evidence_contains_raw_data");
  requireValue(payload.sourceStateDigest === context.sourceStateDigest,
    "evidence_source_digest_mismatch");
  requireValue(receipt?.targetId === context.spec.evidenceTargetId,
    "evidence_target_mismatch");
  requireValue(receipt?.productVersion === context.productVersion, "evidence_version_mismatch");
  requireValue(receipt?.buildNumber === context.buildNumber, "evidence_build_number_mismatch");
  requireValue(context.artifactLineageReady === true &&
    digestPattern.test(text(context.artifactManifestDigest)),
  "artifact_distribution_lineage_mismatch");
  requireValue(receipt?.artifactKind === context.spec.evidenceArtifactKind,
    "evidence_artifact_kind_mismatch");
  requireValue(receipt?.artifactDigest === context.evidenceArtifactDigest,
    "evidence_artifact_digest_mismatch");
  requireValue(digestPattern.test(text(receipt?.runtimeExecutableDigest)),
    "macos_runtime_executable_digest_missing");
  requireValue(dependency?.id === "macos-user-presence-proof" &&
    dependency?.ref ===
      "build/reports/secure-mesh-macos-keychain-user-presence-proof.json" &&
    digestPattern.test(text(dependency?.digest)),
  "macos_capability_dependency_receipt_missing");
  requireValue(receipt?.signatureKind === "local-identity-codesign" &&
    receipt?.platformLocalSignatureReady === true &&
    receipt?.hardenedRuntime === true &&
    receipt?.nestedCodeMinimalEntitlements === true,
  "evidence_signature_policy_mismatch");
  requireValue(receipt?.entitlementsMatch === true &&
    digestPattern.test(text(receipt?.entitlementsDigest)),
  "macos_entitlements_mismatch");
  requireValue(receipt?.installedArtifactMatched === true &&
    receipt?.installReceiptReady === true, "macos_install_receipt_not_ready");
  requireValue(receipt?.launchReady === true, "macos_launch_not_ready");
  requireValue(receipt?.newProcessReady === true &&
    receipt?.startedAfterInvocation === true &&
    receipt?.executableWithinInstalledBundle === true &&
    receipt?.closureChallengeBound === true &&
    receipt?.invocationNonceBound === true &&
    receipt?.stableProcessWindowReady === true &&
    receipt?.postLaunchArtifactStable === true,
  "macos_launch_binding_not_ready");
  requireValue(receipt?.smokeReady === true && receipt?.capabilityProofReady === true,
    "macos_smoke_not_ready");
  return {
    consumerIntegritySignatureKind: "platform-local-validation",
    consumerIntegritySignatureReady: true,
    publicVerificationMaterialReady: false,
    platformSecurityReady: true,
    installReady: true,
    launchReady: true,
    smokeReady: true,
    runtimeExecutableDigest: receipt.runtimeExecutableDigest,
    dependencies: [{
      id: dependency.id,
      ref: dependency.ref,
      digest: dependency.digest,
    }],
  };
}
