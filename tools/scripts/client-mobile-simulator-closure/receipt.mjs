import { requireValue } from "./errors.mjs";

export function buildReceipt({
  platform,
  targetId,
  sourceStateDigest,
  artifactKind,
  artifactDigest,
  runtimeExecutableDigest,
  integrationSummary,
  blockedClaims,
  functionalHarnessExactArtifact = platform !== "ios",
}) {
  const report = {
    schemaVersion: "licomesh.client-mobile-simulator-closure.v2",
    generatedAt: new Date().toISOString(),
    generatedBy: "tools/scripts/client-mobile-simulator-closure.mjs",
    platform,
    targetId,
    sourceStateDigest,
    artifact: {
      kind: artifactKind,
      digest: artifactDigest,
      runtimeExecutableDigest,
      sourceBound: true,
      installedArtifactMatched: true,
    },
    closure: {
      buildReady: true,
      installReady: true,
      launchReady: true,
    },
    functionalHarness: {
      purpose: "same-source-bridge-ffi-simulated-authorization",
      sourceBound: true,
      exactReleaseArtifact: functionalHarnessExactArtifact,
      bridgeReady: integrationSummary.bridgeReady === true,
      nativeFfiReady: integrationSummary.nativeFfiReady === true,
      runtimeStatusWritten: integrationSummary.runtimeStatusWritten === true,
      simulatedAuthorizationReady:
        integrationSummary.simulatedAuthorizationReady === true,
      simulatorOnlyAuthorization:
        integrationSummary.simulatorOnlyAuthorization === true,
    },
    exactReleaseArtifact: {
      sourceBound: true,
      stagingSnapshotReady: true,
      cleanInstallReady: true,
      launchReady: true,
      installedContentMatched: true,
      installedStrictIdentityStable: true,
      stagedStrictIdentityStable: true,
      runtimeStatusWritten: true,
    },
    simulator: {
      classVerified: true,
      authorizationScope: "simulated-only",
      identifierIncluded: false,
      rawRuntimeDataIncluded: false,
    },
    excludedClaims: {
      physicalDeviceReady: false,
      hardwareBackedCustodyReady: false,
      realBiometricReady: false,
      secureEnclaveReady: false,
      physicalCrossDeviceEncryptionReady: false,
      productionSigningReady: false,
      storeDistributionReady: false,
    },
    blockedClaims,
    privacy: {
      redacted: true,
      privatePathsIncluded: false,
      deviceIdentifiersIncluded: false,
      rawPrivateMaterialIncluded: false,
      rawRuntimeDataIncluded: false,
    },
    localSimulatorClosureReady: true,
    productionReleaseReady: false,
    releaseReducerEligible: false,
    ok: true,
  };
  validateReceipt(report);
  return report;
}

export function validateReceipt(report) {
  requireValue(report?.ok === true && report.localSimulatorClosureReady === true &&
    report.schemaVersion === "licomesh.client-mobile-simulator-closure.v2" &&
    report.productionReleaseReady === false && report.simulator?.classVerified === true &&
    report.releaseReducerEligible === false &&
    report.simulator?.identifierIncluded === false &&
    report.artifact?.sourceBound === true && report.artifact?.installedArtifactMatched === true &&
    /^sha256:[a-f0-9]{64}$/u.test(report.sourceStateDigest) &&
    /^sha256:[a-f0-9]{64}$/u.test(report.artifact?.digest || "") &&
    /^sha256:[a-f0-9]{64}$/u.test(report.artifact?.runtimeExecutableDigest || "") &&
    Object.values(report.closure || {}).every((value) => value === true) &&
    report.functionalHarness?.purpose ===
      "same-source-bridge-ffi-simulated-authorization" &&
    report.functionalHarness?.sourceBound === true &&
    report.functionalHarness?.exactReleaseArtifact === (report.platform !== "ios") &&
    report.functionalHarness?.bridgeReady === true &&
    report.functionalHarness?.nativeFfiReady === true &&
    report.functionalHarness?.runtimeStatusWritten === true &&
    report.functionalHarness?.simulatedAuthorizationReady === true &&
    report.functionalHarness?.simulatorOnlyAuthorization === true &&
    Object.values(report.exactReleaseArtifact || {}).every((value) => value === true) &&
    Object.keys(report.exactReleaseArtifact || {}).length === 8 &&
    Object.values(report.excludedClaims || {}).every((value) => value === false) &&
    Array.isArray(report.blockedClaims) && report.blockedClaims.length >= 5 &&
    Object.values(report.privacy || {}).every((value) => value === true || value === false) &&
    report.privacy.redacted === true && report.privacy.privatePathsIncluded === false &&
    report.privacy.deviceIdentifiersIncluded === false &&
    report.privacy.rawPrivateMaterialIncluded === false &&
    report.privacy.rawRuntimeDataIncluded === false,
  "simulator_receipt_policy_invalid");
  const encoded = JSON.stringify(report);
  requireValue(!/(?:\/Users\/|\/home\/)/u.test(encoded) &&
    !objectContainsForbiddenIdentityField(report),
    "simulator_receipt_privacy_invalid");
}

export function objectContainsForbiddenIdentityField(value) {
  if (Array.isArray(value)) {
    return value.some(objectContainsForbiddenIdentityField);
  }
  if (!value || typeof value !== "object") return false;
  const forbidden = new Set(["deviceId", "serialNumber", "udid", "androidId"]);
  return Object.entries(value).some(([key, child]) =>
    forbidden.has(key) || objectContainsForbiddenIdentityField(child));
}
