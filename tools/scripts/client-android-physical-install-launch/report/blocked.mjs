import path from "node:path";
import process from "node:process";
import { androidRawJsonSecretOverridesSourceProof } from "../../lib/android-mobile-relay-secret-override-source-proof.mjs";
import {
  releaseClosureChallengeDigest,
  releaseInvocationNonceDigest,
  requiredReleaseClosureChallenge,
  requiredReleaseInvocationNonce,
} from "../../lib/release-closure-challenge.mjs";
import { atomicWriteReportJson } from "../../lib/safe-report-io.mjs";
import { parseArgs } from "../cli.mjs";
import { repoRoot, reportPath, VERIFIER_PATH } from "../constants.mjs";
import {
  authorizedDeviceCountIfAvailable,
  pickAdbIfAvailable,
} from "../device/adb.mjs";
import {
  androidPhysicalDeviceProofMissingFields,
  androidPhysicalDeviceProofWeakProofFields,
} from "../device/classify.mjs";
import { assertNoLeak } from "../privacy/leak-scan.mjs";
import { sanitizeError } from "../privacy/sanitize.mjs";
import { stringList, stableUniquePaths } from "../util/paths.mjs";
import { clientProductVersion } from "../version.mjs";

export function writeBlockedReportIfPossible(error) {
  const reason = sanitizeError(error);
  if (!/adb is not available|adb devices failed|no authorized Android device is connected|configured Android device is not authorized|multiple Android devices are connected/u.test(reason)) {
    return null;
  }
  try {
    const options = parseArgs(process.argv.slice(2));
    const productVersion = clientProductVersion();
    const closureChallengeDigest = releaseClosureChallengeDigest(
      requiredReleaseClosureChallenge()
    );
    const invocationNonceDigest = releaseInvocationNonceDigest(
      requiredReleaseInvocationNonce()
    );
    const apk = {
      ok: false,
      mode: "unknown",
      byteSize: 0,
      sha256: "",
      hasNativeSecureMeshLibrary: false,
      nativeSecureMeshAbi: "",
      inspectedWithUnzip: false,
      sourceStateDigest: "",
      buildManifestDigest: "",
      sourceStateMatchesCurrent: false,
      manifestArtifactMatched: false,
      signingKind: "",
      signatureVerified: false,
      signerIdentityVerified: false,
      signingPolicySatisfied: false
    };
    const adb = reason === "adb is not available" ? "" : pickAdbIfAvailable();
    const authorizedDeviceCount = adb ? authorizedDeviceCountIfAvailable(adb) : 0;
    const androidPhysicalDeviceProof = {
      androidAdbTransportAuthorized: false,
      androidDeviceClass: "unknown",
      androidPhysicalDeviceProofReady: false,
      androidGetpropProbeReady: false,
      rawGetpropIncluded: false,
      rawDeviceIdentifiersIncluded: false,
      androidEmulatorSignalCategories: [],
      androidPhysicalSignalCategories: [],
      androidGetpropMissingFields: ["authorizedPhysicalDevice"],
      androidGetpropAmbiguousFields: ["blockedBeforeDeviceSelection"]
    };
    const androidMissingFields = stableUniquePaths([
      "authorizedPhysicalDevice",
      ...androidPhysicalDeviceProofMissingFields(androidPhysicalDeviceProof)
    ]);
    const androidWeakProofFields =
      androidPhysicalDeviceProofWeakProofFields(androidPhysicalDeviceProof);
    const rawJsonSecretOverridesStaticSourceProof =
      androidRawJsonSecretOverridesSourceProof(repoRoot);
    const report = {
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
      ok: false,
      closureChallengeDigest,
      invocationNonceDigest,
      targetId: "android-arm64",
      productVersion,
      buildNumber: 0,
      platform: "android",
      physicalDevice: false,
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
      sourceBuild: {
        sourceStateDigest: apk.sourceStateDigest,
        buildManifestDigest: apk.buildManifestDigest,
        sourceStateMatchesCurrent: apk.sourceStateMatchesCurrent === true,
        manifestArtifactMatched: apk.manifestArtifactMatched === true
      },
      signing: {
        signingKind: apk.signingKind,
        signatureVerified: apk.signatureVerified === true,
        signerIdentityVerified: apk.signerIdentityVerified === true,
        signingPolicySatisfied: apk.signingPolicySatisfied === true,
        singleSigner: false,
        signatureMatchedBuildManifest: false,
        localDebug: apk.mode === "debug"
      },
      evidenceBinding: {
        sourceStateDigest: apk.sourceStateDigest,
        buildManifestDigest: apk.buildManifestDigest,
        apkSha256: apk.sha256,
        signatureMatchedBuildManifest: false,
        capabilityReportSha256: "",
        ready: false
      },
      device: {
        authorizedDeviceCount,
        selectedPhysicalDevice: false,
        blockedBeforeDeviceSelection: true,
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
        attempted: false,
        installedViaVerifier: false,
        packagePresentAfterInstall: false
      },
      launch: {
        attempted: false,
        launchedViaVerifier: false,
        launchableActivityResolved: false,
        runtimeStatusFreshAfterLaunch: false
      },
      runtimeStatus: {
        mobileRelaySecretStore: {
          provider: "",
          ffiBoundary: "",
          secretTransport: "",
          secretStoreBackend: "",
          secretStoreContract: "",
          secretStoreAccountPrefix: "",
          secretStoreNamespace: "",
          sharedRustSecretStoreHandleContract: false,
          rawJsonSecretOverridesUsedPresent: true,
          rawJsonSecretOverridesUsed: false,
          rawJsonSecretOverridesProvenAbsent: false,
          rawJsonSecretOverridesStaticSourceProvenAbsent:
            rawJsonSecretOverridesStaticSourceProof.staticSourceProofReady === true,
          portableConfigAuthority: "",
          kotlinConfigReadWrite: false,
          statusProbeSideEffectFree: false,
          androidKeyMaterialExportedPresent: false,
          androidKeyMaterialExported: false,
          decryptedSecretCrossesJniInProcess: false,
          getNotFoundSeparatedFromFailure: false,
          applicationAuthorizationGrantRequired: false,
          custodyStrategy: "",
          restartSemantics: "",
          mandatoryFoundationComplete: false,
          enabledCapabilities: [],
          unavailableCapabilities: [],
          unverifiedCapabilities: [],
          userAuthenticationSelected: false,
          deviceCredentialAvailable: false,
          strongBiometricAvailable: false,
          securityLevel: "",
          capabilityReport: null,
          measurements: null
        }
      },
      summary: {
        apkReady: apk.ok === true && apk.hasNativeSecureMeshLibrary === true,
        installReady: false,
        launchReady: false,
        runtimeStatusReady: false,
        nativeRuntimeReady: false,
        authenticatedPairwiseV2RuntimeReady: false,
        runtimeStatusRedacted: true,
        androidCustodyReady: false,
        adaptiveAuthorizationReady: false,
        freshOneShotAuthorizationPolicyReady: false,
        jniSecretCallbackInProcessReady: false,
        statusProbeSideEffectFree: false,
        androidPhysicalDeviceProofReady: false,
        androidDeviceClass: "unknown",
        androidGetpropProbeReady: false,
        rawGetpropIncluded: false,
        rawDeviceIdentifiersIncluded: false,
        androidMissingFields,
        androidMissingFieldCount: androidMissingFields.length,
        androidMissingFieldsAbsent: false,
        androidWeakProofFields,
        androidWeakProofFieldCount: androidWeakProofFields.length,
        androidWeakProofFieldsAbsent: androidWeakProofFields.length === 0,
        mobileRelaySecretStoreContractReady: false,
        rawJsonSecretOverridesUsedPresent: false,
        rawJsonSecretOverridesUsed: false,
        rawJsonSecretOverridesProvenAbsent: false,
        rawJsonSecretOverridesStaticSourceProvenAbsent:
          rawJsonSecretOverridesStaticSourceProof.staticSourceProofReady === true,
        rawJsonSecretOverridesUnknown:
          rawJsonSecretOverridesStaticSourceProof.staticSourceProofReady !== true,
        androidKeyMaterialExportedPresent: false,
        androidKeyMaterialExported: false,
        androidKeyMaterialNotExported: false,
        custodyStrategy: "",
        restartSemantics: "",
        securityLevel: "",
        enabledCapabilities: [],
        sourceBuildBound: false,
        apkSignatureReady: false,
        capabilityReportBound: false,
        evidenceBindingReady: false,
        blockerReason: reason,
        currentReportIsFailClosedBlockedProbe: true
      },
      rawJsonSecretOverridesStaticSourceProof
    };
    assertNoLeak(report, "Android physical install/launch blocked report");
    atomicWriteReportJson(
      path.join(repoRoot, "build"),
      reportPath.replace(/^build\//u, ""),
      report
    );
    return report;
  } catch {
    return null;
  }
}
