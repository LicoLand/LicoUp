import { digestPattern } from "../constants.mjs";
import { requireValue, text } from "../util.mjs";

export function validateAndroidEvidence(payload, context) {
  const sourceBuild = payload.sourceBuild || {};
  const binding = payload.evidenceBinding || {};
  const signing = payload.signing || {};
  const install = payload.install || {};
  const launch = payload.launch || {};
  const summary = payload.summary || {};
  requireValue(payload.ok === true && payload.platform === "android" &&
    payload.physicalDevice === true, "android_evidence_not_ready");
  requireValue(payload.targetId === context.spec.evidenceTargetId,
    "evidence_target_mismatch");
  requireValue(payload.productVersion === context.productVersion, "evidence_version_mismatch");
  requireValue(payload.buildNumber === context.buildNumber,
    "evidence_build_number_mismatch");
  requireValue(payload.redacted === true && payload.reportLeakScan === true,
    "android_evidence_not_redacted");
  requireValue(payload.rawPrivateMaterialIncluded === false && payload.rawPlaintextIncluded === false,
    "android_evidence_contains_raw_data");
  requireValue(sourceBuild.sourceStateDigest === context.sourceStateDigest &&
    binding.sourceStateDigest === context.sourceStateDigest,
  "evidence_source_digest_mismatch");
  requireValue(payload.apk?.sha256 === context.artifactDigest &&
    binding.apkSha256 === context.artifactDigest,
  "evidence_artifact_digest_mismatch");
  requireValue(payload.apk?.nativeSecureMeshAbi === "arm64-v8a",
    "evidence_target_architecture_mismatch");
  requireValue(payload.packageName === "land.lico.licoup" &&
    payload.apkBinaryFacts?.packageName === payload.packageName &&
    payload.apkBinaryFacts?.versionName === payload.productVersion &&
    payload.apkBinaryFacts?.versionCode === String(payload.buildNumber) &&
    payload.apkBinaryFacts?.debuggable === false &&
    JSON.stringify(payload.apkBinaryFacts?.abis) === JSON.stringify(["arm64-v8a"]) &&
    text(payload.apkBinaryFacts?.launchableActivity) &&
    payload.apkBinaryFacts?.signerCount === 1 &&
    payload.apkBinaryFacts?.zipAligned === true &&
    payload.apkBinaryFacts?.nativeSecureMeshLibrary?.path ===
      "lib/arm64-v8a/liblicoup_native.so" &&
    payload.apkBinaryFacts?.nativeSecureMeshLibrary?.regular === true &&
    payload.apkBinaryFacts?.nativeSecureMeshLibrary?.unique === true &&
    payload.apkBinaryFacts?.nativeSecureMeshLibrary?.size > 0 &&
    digestPattern.test(text(
      payload.apkBinaryFacts?.nativeSecureMeshLibrary?.contentDigest,
    )) &&
    Array.isArray(payload.apkBinaryFacts?.signatureSchemes) &&
    payload.apkBinaryFacts.signatureSchemes.some((scheme) =>
      ["v2", "v3", "v4"].includes(scheme)),
  "android_binary_manifest_facts_mismatch");
  requireValue(signing.signingKind === "local-install-keystore" &&
    signing.signatureVerified === true && signing.singleSigner === true &&
    signing.signerIdentityVerified === true &&
    signing.signingPolicySatisfied === true &&
    signing.signatureMatchedBuildManifest === true &&
    binding.signatureMatchedBuildManifest === true,
  "evidence_signature_policy_mismatch");
  requireValue(install.attempted === true && install.installedViaVerifier === true &&
    install.packagePresentAfterInstall === true &&
    install.installedArtifactMatched === true && summary.installReady === true,
  "android_install_receipt_not_ready");
  requireValue(launch.attempted === true && launch.launchedViaVerifier === true &&
    launch.runtimeStatusFreshAfterLaunch === true && summary.launchReady === true,
  "android_launch_not_ready");
  requireValue(summary.runtimeStatusReady === true && summary.nativeRuntimeReady === true &&
    summary.androidCustodyReady === true &&
    summary.adaptiveAuthorizationReady === true &&
    summary.evidenceBindingReady === true && summary.closureChallengeBound === true &&
    summary.invocationNonceBound === true,
  "android_smoke_not_ready");
  return {
    consumerIntegritySignatureKind: "platform-local-validation",
    consumerIntegritySignatureReady: true,
    publicVerificationMaterialReady: false,
    platformSecurityReady: true,
    installReady: true,
    launchReady: true,
    smokeReady: true,
    runtimeExecutableDigest:
      payload.apkBinaryFacts.nativeSecureMeshLibrary.contentDigest,
    dependencies: [],
  };
}
