import { VERIFIER_PATH, reportPath, SHA256_DIGEST } from "../constants.mjs";
import {
  androidPhysicalDeviceProofMissingFields,
  androidPhysicalDeviceProofWeakProofFields,
} from "../device/classify.mjs";
import { sha256Canonical } from "../util/hash.mjs";
import { stringList, stableUniquePaths } from "../util/paths.mjs";

export function buildInstallLaunchReport({
  options,
  apk,
  device,
  install,
  packageInstalled,
  launchable,
  installedArtifactMatched,
  launch,
  runtimeRead,
  runtimeValidation,
  rawJsonSecretOverridesStaticSourceProof,
  closureChallengeDigest,
  invocationNonceDigest,
  closureStartedAt,
  productVersion,
}) {
  const androidPhysicalDeviceProof = device.physicalProof;
  const runtimeSummary = runtimeValidation.summary || {};
  const runtimeMobileRelaySecretStore = runtimeSummary.mobileRelaySecretStore || {};
  const capabilityReportDigest = runtimeMobileRelaySecretStore.capabilityReport
    ? sha256Canonical(runtimeMobileRelaySecretStore.capabilityReport)
    : "";

  const summary = {
    apkReady: apk.ok === true && apk.hasNativeSecureMeshLibrary === true,
    installReady: options.install === true &&
      install.installedViaVerifier === true &&
      packageInstalled === true,
    launchReady: options.launch === true &&
      launch.launchedViaVerifier === true &&
      runtimeRead.freshAfterLaunch === true,
    runtimeStatusReady: runtimeRead.ok === true && runtimeValidation.ok === true,
    nativeRuntimeReady: runtimeValidation.nativeRuntimeReady === true,
    authenticatedPairwiseV2RuntimeReady:
      runtimeValidation.authenticatedPairwiseV2RuntimeReady === true,
    runtimeStatusRedacted: runtimeValidation.runtimeStatusRedacted === true,
    androidCustodyReady: runtimeValidation.androidCustodyReady === true,
    adaptiveAuthorizationReady:
      runtimeValidation.adaptiveAuthorizationReady === true,
    freshOneShotAuthorizationPolicyReady:
      runtimeValidation.freshOneShotAuthorizationPolicyReady === true,
    androidPhysicalDeviceProofReady:
      androidPhysicalDeviceProof.androidPhysicalDeviceProofReady === true,
    androidDeviceClass: String(androidPhysicalDeviceProof.androidDeviceClass || "unknown"),
    androidGetpropProbeReady: androidPhysicalDeviceProof.androidGetpropProbeReady === true,
    rawGetpropIncluded: androidPhysicalDeviceProof.rawGetpropIncluded === true,
    rawDeviceIdentifiersIncluded:
      androidPhysicalDeviceProof.rawDeviceIdentifiersIncluded === true,
    androidMissingFields: stableUniquePaths([
      ...(runtimeValidation.summary?.androidMissingFields || []),
      ...androidPhysicalDeviceProofMissingFields(androidPhysicalDeviceProof)
    ]),
    androidWeakProofFields: stableUniquePaths([
      ...(runtimeValidation.summary?.androidWeakProofFields || []),
      ...androidPhysicalDeviceProofWeakProofFields(androidPhysicalDeviceProof)
    ]),
    mobileRelaySecretStoreContractReady:
      runtimeSummary.mobileRelaySecretStoreContractReady === true,
    jniSecretCallbackInProcessReady:
      runtimeMobileRelaySecretStore.ffiBoundary === "jni" &&
      runtimeMobileRelaySecretStore.secretTransport ===
        "jni_callback_in_process_secret_bytes" &&
      runtimeMobileRelaySecretStore.decryptedSecretCrossesJniInProcess === true,
    statusProbeSideEffectFree:
      runtimeMobileRelaySecretStore.statusProbeSideEffectFree === true,
    androidKeyMaterialExportedPresent:
      runtimeMobileRelaySecretStore.androidKeyMaterialExportedPresent === true,
    androidKeyMaterialExported:
      runtimeMobileRelaySecretStore.androidKeyMaterialExported === true,
    androidKeyMaterialNotExported:
      runtimeMobileRelaySecretStore.androidKeyMaterialExportedPresent === true &&
      runtimeMobileRelaySecretStore.androidKeyMaterialExported === false,
    rawJsonSecretOverridesUsedPresent:
      runtimeMobileRelaySecretStore.rawJsonSecretOverridesUsedPresent === true,
    rawJsonSecretOverridesUsed:
      runtimeMobileRelaySecretStore.rawJsonSecretOverridesUsed === true,
    rawJsonSecretOverridesProvenAbsent:
      runtimeMobileRelaySecretStore.rawJsonSecretOverridesProvenAbsent === true,
    rawJsonSecretOverridesStaticSourceProvenAbsent:
      rawJsonSecretOverridesStaticSourceProof.staticSourceProofReady === true,
    rawJsonSecretOverridesUnknown:
      runtimeMobileRelaySecretStore.rawJsonSecretOverridesUsedPresent !== true &&
      rawJsonSecretOverridesStaticSourceProof.staticSourceProofReady !== true,
    custodyStrategy: String(runtimeMobileRelaySecretStore.custodyStrategy || ""),
    restartSemantics: String(runtimeMobileRelaySecretStore.restartSemantics || ""),
    securityLevel: String(runtimeMobileRelaySecretStore.securityLevel || ""),
    enabledCapabilities:
      Array.isArray(runtimeMobileRelaySecretStore.enabledCapabilities)
        ? runtimeMobileRelaySecretStore.enabledCapabilities
        : [],
    sourceBuildBound:
      apk.sourceStateMatchesCurrent === true && apk.manifestArtifactMatched === true,
    apkSignatureReady:
      apk.signatureVerified === true && apk.facts?.signerCount === 1,
    capabilityReportBound: SHA256_DIGEST.test(capabilityReportDigest),
    installedArtifactMatched,
    closureChallengeBound:
      runtimeValidation.summary?.closureChallengeBound === true &&
      closureStartedAt.milliseconds <= Date.now(),
    invocationNonceBound:
      runtimeValidation.summary?.invocationNonceBound === true,
  };
  summary.evidenceBindingReady = summary.sourceBuildBound === true &&
    summary.apkSignatureReady === true && summary.capabilityReportBound === true &&
    summary.installedArtifactMatched === true && summary.closureChallengeBound === true &&
    summary.invocationNonceBound === true;
  summary.androidMissingFieldCount = summary.androidMissingFields.length;
  summary.androidMissingFieldsAbsent = summary.androidMissingFields.length === 0;
  summary.androidWeakProofFieldCount = summary.androidWeakProofFields.length;
  summary.androidWeakProofFieldsAbsent = summary.androidWeakProofFields.length === 0;

  const ok = [
    summary.apkReady,
    summary.installReady,
    summary.launchReady,
    summary.runtimeStatusReady,
    summary.androidPhysicalDeviceProofReady,
    summary.nativeRuntimeReady,
    summary.authenticatedPairwiseV2RuntimeReady,
    summary.runtimeStatusRedacted,
    summary.androidCustodyReady,
    summary.adaptiveAuthorizationReady,
    summary.freshOneShotAuthorizationPolicyReady,
    summary.jniSecretCallbackInProcessReady,
    summary.statusProbeSideEffectFree,
    summary.androidKeyMaterialNotExported,
    summary.evidenceBindingReady,
    summary.androidMissingFieldsAbsent,
    summary.androidWeakProofFieldsAbsent
  ].every((value) => value === true);

  return {
    schemaVersion: "licolite.secure-mesh.android-physical-install-launch-report.v3",
    verifier: VERIFIER_PATH,
    generatedAt: new Date().toISOString(),
    report: reportPath,
    reportLeakScan: true,
    redacted: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    nonBlockingDistributionGuidance: {
      blocking: false,
      storeListingStatus: "not-configured",
      platformSigningStatus: "not-configured",
      publicDownloadStatus: "not-configured",
      updateChannelStatus: "not-configured",
      rollbackChannelStatus: "not-configured"
    },
    ok,
    closureChallengeDigest,
    invocationNonceDigest,
    targetId: "android-arm64",
    productVersion,
    buildNumber: apk.buildNumber,
    platform: "android",
    physicalDevice: summary.androidPhysicalDeviceProofReady === true,
    packageName: options.packageName,
    requestedActions: {
      install: options.install,
      launch: options.launch
    },
    apk: {
      inspected: apk.ok === true,
      mode: apk.mode,
      byteSize: apk.byteSize,
      sha256: apk.sha256,
      hasNativeSecureMeshLibrary: apk.hasNativeSecureMeshLibrary === true,
      nativeSecureMeshAbi: apk.nativeSecureMeshAbi,
      inspectedWithUnzip: apk.inspectedWithUnzip === true,
      manifestArtifactMatched: apk.manifestArtifactMatched === true
    },
    apkBinaryFacts: {
      packageName: apk.packageName,
      versionCode: apk.versionCode,
      versionName: apk.versionName,
      debuggable: apk.debuggable,
      abis: apk.abis,
      launchableActivity: apk.launchableActivity,
      signerCount: apk.facts.signerCount,
      signatureSchemes: apk.facts.signatureSchemes,
      zipAligned: apk.facts.zipAligned,
      nativeSecureMeshLibrary: apk.facts.nativeSecureMeshLibrary
    },
    sourceBuild: {
      sourceStateDigest: apk.sourceStateDigest,
      buildManifestDigest: apk.buildManifestDigest,
      sourceStateMatchesCurrent: apk.sourceStateMatchesCurrent === true,
      manifestArtifactMatched: apk.manifestArtifactMatched === true
    },
    signing: {
      signingKind: apk.signingKind,
      signatureVerified: apk.signatureVerified === true,
      signerIdentityVerified: apk.signatureVerified === true,
      signingPolicySatisfied:
        apk.signatureVerified === true && apk.facts.signerCount === 1,
      singleSigner: apk.facts.signerCount === 1,
      signatureMatchedBuildManifest: apk.signatureVerified === true,
      localDebug: apk.mode === "debug"
    },
    evidenceBinding: {
      sourceStateDigest: apk.sourceStateDigest,
      buildManifestDigest: apk.buildManifestDigest,
      apkSha256: apk.sha256,
      signatureMatchedBuildManifest: apk.signatureVerified === true,
      capabilityReportSha256: capabilityReportDigest,
      ready: summary.evidenceBindingReady === true
    },
    device: {
      authorizedDeviceCount: device.authorizedDeviceCount,
      selectedPhysicalDevice: summary.androidPhysicalDeviceProofReady === true,
      androidAdbTransportAuthorized:
        androidPhysicalDeviceProof.androidAdbTransportAuthorized === true,
      androidDeviceClass: String(androidPhysicalDeviceProof.androidDeviceClass || "unknown"),
      androidPhysicalDeviceProofReady:
        androidPhysicalDeviceProof.androidPhysicalDeviceProofReady === true,
      androidGetpropProbeReady: androidPhysicalDeviceProof.androidGetpropProbeReady === true,
      rawGetpropIncluded: androidPhysicalDeviceProof.rawGetpropIncluded === true,
      rawDeviceIdentifiersIncluded:
        androidPhysicalDeviceProof.rawDeviceIdentifiersIncluded === true,
      androidEmulatorSignalCategories:
        stringList(androidPhysicalDeviceProof.androidEmulatorSignalCategories),
      androidPhysicalSignalCategories:
        stringList(androidPhysicalDeviceProof.androidPhysicalSignalCategories),
      androidGetpropMissingFields:
        stringList(androidPhysicalDeviceProof.androidGetpropMissingFields),
      androidGetpropAmbiguousFields:
        stringList(androidPhysicalDeviceProof.androidGetpropAmbiguousFields)
    },
    install: {
      attempted: install.attempted === true,
      installedViaVerifier: install.installedViaVerifier === true,
      packagePresentAfterInstall: packageInstalled === true,
      installedArtifactMatched
    },
    launch: {
      attempted: launch.attempted === true,
      launchedViaVerifier: launch.launchedViaVerifier === true,
      launchableActivityResolved: launchable === true,
      runtimeStatusFreshAfterLaunch: runtimeRead.freshAfterLaunch === true
    },
    runtimeStatus: runtimeValidation.summary,
    rawJsonSecretOverridesStaticSourceProof,
    summary
  };
}
