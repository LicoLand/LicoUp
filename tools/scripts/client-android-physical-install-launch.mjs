#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { androidRawJsonSecretOverridesSourceProof } from "./lib/android-mobile-relay-secret-override-source-proof.mjs";
import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  clientSourceStateDigest,
} from "./lib/client-source-state-digest.mjs";
import { androidReleaseBuildParametersReady } from "./lib/android-release-build-policy.mjs";
import {
  summarizeAndroidCapabilityStore,
  validateAndroidCapabilityMeasurements,
  validateAndroidCapabilityProbe
} from "./lib/secure-mesh-android-capabilities.mjs";
import { loadSecureMeshPhysicalEvidenceConfig } from "./lib/secure-mesh-physical-evidence-config.mjs";
import {
  assertAndroidApkFactsEqual,
  ANDROID_APK_RESOURCE_LIMITS,
  findAndroidAdbTool,
  inspectAndroidApkFacts
} from "./lib/android-apk-facts.mjs";
import {
  releaseClosureChallengeDigest,
  releaseInvocationNonceDigest,
  requiredReleaseClosureChallenge,
  requiredReleaseClosureStartedAt,
  requiredReleaseInvocationNonce
} from "./lib/release-closure-challenge.mjs";
import {
  resolveContainedExistingPath,
  sha256File as stableSha256File,
  stableHashFileSnapshot,
  stableSnapshotFile,
  stableReadFile
} from "./lib/client-release-artifact-digest.mjs";
import {
  atomicWriteReportJson,
  removeContainedReportIfExists,
} from "./lib/safe-report-io.mjs";
import { minimalReleaseToolEnvironment } from "./lib/release-tool-environment.mjs";
import {
  androidReleaseAcceptanceAuthorizationBroadcastArgs,
  androidReleaseAcceptanceBroadcastAccepted,
} from "./lib/android-release-acceptance-binding.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const physicalEvidenceConfig = await loadSecureMeshPhysicalEvidenceConfig();
const physicalReportRefs = physicalEvidenceConfig.linkedReports;
const reportPath = physicalReportRefs.androidInstallLaunch;
const defaultPackageName = "com.liko.arc";
const runtimeStatusRelativePath = "files/secure-mesh/android-runtime-status.json";
const ANDROID_AUTHENTICATED_PAIRWISE_RUNTIME_STATUS =
  "authenticated_pairwise_runtime_bound_to_selected_custody";
const SHA256_DIGEST = /^sha256:[a-f0-9]{64}$/u;
const clientSourceRoots = CANONICAL_CLIENT_SOURCE_ROOTS;

try {
  if (process.argv.slice(2).includes("--self-test")) {
    console.log(JSON.stringify(runSelfTest()));
  } else {
  removeContainedReportIfExists(
    path.join(repoRoot, "build"),
    reportPath.replace(/^build\//u, ""),
  );
  const report = await main();
  console.log(JSON.stringify({
    ok: report.ok,
    report: report.report,
    platform: report.platform,
    physicalDevice: report.physicalDevice,
    installReady: report.summary.installReady,
    launchReady: report.summary.launchReady,
    runtimeStatusReady: report.summary.runtimeStatusReady,
    nativeRuntimeReady: report.summary.nativeRuntimeReady,
    authenticatedPairwiseV2RuntimeReady:
      report.summary.authenticatedPairwiseV2RuntimeReady,
    runtimeStatusRedacted: report.summary.runtimeStatusRedacted,
    androidCustodyReady: report.summary.androidCustodyReady,
    sourceBuildBound: report.summary.sourceBuildBound,
    apkSignatureReady: report.summary.apkSignatureReady,
    evidenceBindingReady: report.summary.evidenceBindingReady
  }, null, 2));
  if (!report.ok) {
    process.exitCode = 1;
  }
  }
} catch (error) {
  const blockedReport = writeBlockedReportIfPossible(error);
  if (blockedReport) {
    console.error(JSON.stringify({
      ok: false,
      report: blockedReport.report,
      platform: blockedReport.platform,
      physicalDevice: blockedReport.physicalDevice,
      apkReady: blockedReport.summary.apkReady,
      blockerReason: blockedReport.summary.blockerReason,
      authorizedDeviceCount: blockedReport.device.authorizedDeviceCount
    }, null, 2));
    process.exitCode = 1;
  } else {
  console.error(JSON.stringify({
    ok: false,
    reason: "android_physical_install_launch_failed",
    privatePathsIncluded: false
  }));
  process.exitCode = 1;
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const closureChallenge = requiredReleaseClosureChallenge();
  const invocationNonce = requiredReleaseInvocationNonce();
  const closureStartedAt = requiredReleaseClosureStartedAt();
  const closureChallengeDigest = releaseClosureChallengeDigest(closureChallenge);
  const invocationNonceDigest = releaseInvocationNonceDigest(invocationNonce);
  const productVersion = clientProductVersion();
  const workRoot = mkdtempSync(path.join(os.tmpdir(), "lico-android-install-receipt-"));
  try {
  const apk = inspectApk(options.apk, workRoot);
  if (!physicalReleaseApkReady(apk)) {
    throw new Error("Android physical release receipt rejects debug or non-release APKs");
  }
  if (options.packageName !== apk.packageName) {
    throw new Error("Android package option does not match the APK binary manifest");
  }
  const adb = pickAdb();
  const adbBefore = stableHashFileSnapshot(adb, {
    maxBytes: 1024 * 1024 * 1024,
  });
  const device = pickDevice(adb, options);
  const androidPhysicalDeviceProof = device.physicalProof;
  const install = options.install
    ? installApk(adb, device.serial, apk, options)
    : { attempted: false, installedViaVerifier: false, ok: true };
  const packageInstalled = isPackageInstalled(adb, device.serial, options.packageName);
  const launchComponent = packageInstalled
    ? resolveLaunchComponent(adb, device.serial, options.packageName)
    : "";
  const launchable = launchComponent ===
    `${options.packageName}/${apk.launchableActivity}`;

  if (options.launch) {
    removeRuntimeStatusFiles(adb, device.serial, options.packageName);
  }
  const installedApk = options.install && packageInstalled
    ? inspectInstalledApk(adb, device.serial, options.packageName, workRoot)
    : { ready: false };
  const installedArtifactMatched = installedApk.ready === true &&
    assertAndroidApkFactsEqual(apk.facts, installedApk.facts);
  const launch = options.launch && packageInstalled && launchable && installedArtifactMatched
    ? launchApp(
        adb,
        device.serial,
        options.packageName,
        launchComponent,
        closureChallenge,
        invocationNonce,
        options.launchTimeoutMs
      )
    : {
        attempted: options.launch,
        launchedViaVerifier: false,
        ok: !options.launch,
        skippedReason: packageInstalled ? "package_not_launchable" : "package_not_installed"
      };
  const runtimeRead = options.launch && launch.ok
    ? await waitForRuntimeStatus(
        adb,
        device.serial,
        options.packageName,
        closureChallengeDigest,
        invocationNonceDigest,
        options.runtimeTimeoutMs
      )
    : readRuntimeStatus(adb, device.serial, options.packageName);
  const runtimeValidation = runtimeRead.ok
    ? validateRuntimeStatus(
        parseJson(runtimeRead.stdout),
        closureChallengeDigest,
        invocationNonceDigest
      )
    : { ok: false, missing: ["runtimeStatusFile"] };
  const runtimeSummary = runtimeValidation.summary || {};
  const runtimeMobileRelaySecretStore = runtimeSummary.mobileRelaySecretStore || {};
  const capabilityReportDigest = runtimeMobileRelaySecretStore.capabilityReport
    ? sha256Canonical(runtimeMobileRelaySecretStore.capabilityReport)
    : "";
  const rawJsonSecretOverridesStaticSourceProof =
    androidRawJsonSecretOverridesSourceProof(repoRoot);

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
      runtimeMobileRelaySecretStore.sharedRustSecretStoreHandleContract === true,
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
    summary.evidenceBindingReady,
    summary.androidMissingFieldsAbsent,
    summary.androidWeakProofFieldsAbsent
  ].every((value) => value === true);
  const report = {
    schemaVersion: "licolite.secure-mesh.android-physical-install-launch-report.v3",
    verifier: "tools/scripts/client-android-physical-install-launch.mjs",
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
    nonBlockingDistributionGuidance: {
      blocking: false,
      storeListingStatus: "not-configured",
      platformSigningStatus: "not-configured"
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
  const adbAfter = stableHashFileSnapshot(adb, {
    maxBytes: 1024 * 1024 * 1024,
  });
  if (adbBefore.digest !== adbAfter.digest ||
    adbBefore.device !== adbAfter.device || adbBefore.inode !== adbAfter.inode) {
    throw new Error("Android adb tool changed during the physical release closure");
  }
  assertNoLeak(report, "Android physical install/launch report");
  atomicWriteReportJson(path.join(repoRoot, "build"), reportPath.replace(/^build\//u, ""), report);
  return report;
  } finally {
    rmSync(workRoot, { recursive: true, force: true });
  }
}

function parseArgs(argv) {
  const options = {
    apk: "",
    packageName: process.env.LICO_ANDROID_PACKAGE_ID || defaultPackageName,
    serial: process.env.ANDROID_SERIAL ||
      process.env.LICO_CLIENT_ANDROID_DEVICE ||
      process.env.LICO_CLIENT_MOBILE_DEVICE ||
      "",
    install: false,
    launch: false,
    installTimeoutMs: positiveInt(process.env.LICO_ANDROID_ADB_INSTALL_TIMEOUT_MS, 360_000),
    launchTimeoutMs: positiveInt(process.env.LICO_ANDROID_LAUNCH_TIMEOUT_MS, 30_000),
    runtimeTimeoutMs: positiveInt(process.env.LICO_ANDROID_RUNTIME_STATUS_TIMEOUT_MS, 45_000)
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];
    if (arg === "--apk" && next) {
      options.apk = next;
      index += 1;
    } else if (arg.startsWith("--apk=")) {
      options.apk = arg.slice("--apk=".length);
    } else if (arg === "--package" && next) {
      options.packageName = next;
      index += 1;
    } else if (arg.startsWith("--package=")) {
      options.packageName = arg.slice("--package=".length);
    } else if (arg === "--serial" && next) {
      options.serial = next;
      index += 1;
    } else if (arg.startsWith("--serial=")) {
      options.serial = arg.slice("--serial=".length);
    } else if (arg === "--install") {
      options.install = true;
    } else if (arg === "--launch") {
      options.launch = true;
    } else if (arg === "--install-timeout-ms" && next) {
      options.installTimeoutMs = positiveInt(next, options.installTimeoutMs);
      index += 1;
    } else if (arg.startsWith("--install-timeout-ms=")) {
      options.installTimeoutMs = positiveInt(
        arg.slice("--install-timeout-ms=".length),
        options.installTimeoutMs
      );
    } else if (arg === "--launch-timeout-ms" && next) {
      options.launchTimeoutMs = positiveInt(next, options.launchTimeoutMs);
      index += 1;
    } else if (arg.startsWith("--launch-timeout-ms=")) {
      options.launchTimeoutMs = positiveInt(
        arg.slice("--launch-timeout-ms=".length),
        options.launchTimeoutMs
      );
    } else if (arg === "--runtime-timeout-ms" && next) {
      options.runtimeTimeoutMs = positiveInt(next, options.runtimeTimeoutMs);
      index += 1;
    } else if (arg.startsWith("--runtime-timeout-ms=")) {
      options.runtimeTimeoutMs = positiveInt(
        arg.slice("--runtime-timeout-ms=".length),
        options.runtimeTimeoutMs
      );
    } else {
      throw new Error(`Unknown Android physical install/launch option: ${arg}`);
    }
  }
  return options;
}

function positiveInt(value, fallback) {
  const parsed = Number.parseInt(String(value || ""), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function physicalReleaseApkReady(apk) {
  return apk?.mode === "release" && apk?.debuggable === false &&
    apk?.signingKind === "local-install-keystore";
}

function clientProductVersion() {
  const manifest = clientVersionManifest();
  const productVersion = String(manifest.productVersion || "").trim();
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(productVersion)) {
    throw new Error("Client product version is invalid");
  }
  return productVersion;
}

function clientVersionManifest() {
  const manifest = parseJson(stableReadFile(
    path.join(repoRoot, "tools", "client-version.json"),
  ).toString("utf8"));
  if (!Number.isInteger(manifest.buildNumber) || manifest.buildNumber <= 0) {
    throw new Error("Client build number is invalid");
  }
  return manifest;
}

function canonicalJson(value) {
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJson).join(",")}]`;
  }
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function sha256(value) {
  return `sha256:${createHash("sha256").update(value).digest("hex")}`;
}

function sha256Canonical(value) {
  return sha256(Buffer.from(canonicalJson(value), "utf8"));
}

function inspectApk(configuredApk, workRoot) {
  const artifactRoot = path.join(repoRoot, "build/apps/desktop/android");
  const requestedPath = configuredApk
    ? path.resolve(repoRoot, configuredApk)
    : findDefaultApk();
  const apkPath = resolveContainedExistingPath(artifactRoot, requestedPath, {
    expectedKind: "file"
  });
  const snapshotPath = stableSnapshotFile(apkPath, workRoot, "source.apk", {
    maxBytes: ANDROID_APK_RESOURCE_LIMITS.maxApkBytes,
  });
  const facts = inspectAndroidApkFacts(repoRoot, snapshotPath, {
    requireApprovedToolchain: true,
  });
  const manifestPath = resolveContainedExistingPath(
    path.dirname(apkPath),
    path.join(path.dirname(apkPath), "build-manifest.json"),
    { expectedKind: "file" }
  );
  const manifest = parseJson(stableReadFile(manifestPath).toString("utf8"));
  const currentSourceStateDigest = clientSourceStateDigest(repoRoot, clientSourceRoots);
  const currentVersion = clientVersionManifest();
  const expectedMode = facts.debuggable ? "debug" : "release";
  const expectedSigningKind = facts.debuggable
    ? "local-debug"
    : "local-install-keystore";
  if (
    manifest.schemaVersion !== "licolite.client-android.apk-build-manifest.v3" ||
    manifest.mode !== expectedMode ||
    manifest.targetId !== "android-arm64" ||
    (expectedMode === "release" &&
      !androidReleaseBuildParametersReady(manifest.buildParameters)) ||
    manifest.sourceStateDigest !== currentSourceStateDigest ||
    manifest.productVersion !== currentVersion.productVersion ||
    manifest.buildNumber !== currentVersion.buildNumber ||
    manifest.packageName !== facts.packageName ||
    manifest.versionCode !== facts.versionCode ||
    manifest.versionName !== facts.versionName ||
    manifest.debuggable !== facts.debuggable ||
    JSON.stringify(manifest.abis) !== JSON.stringify(facts.abis) ||
    manifest.launchableActivity !== facts.launchableActivity ||
    manifest.signerCount !== facts.signerCount ||
    JSON.stringify(manifest.signatureSchemes) !== JSON.stringify(facts.signatureSchemes) ||
    manifest.zipAligned !== facts.zipAligned ||
    manifest.signerIdentityVerified !== true ||
    manifest.signingPolicySatisfied !== true ||
    JSON.stringify(manifest.nativeSecureMeshLibrary) !==
      JSON.stringify(facts.nativeSecureMeshLibrary) ||
    manifest.signingKind !== expectedSigningKind ||
    manifest.artifact?.file !== path.basename(apkPath) ||
    manifest.artifact?.digest !== facts.artifactDigest ||
    manifest.nonBlockingDistributionGuidance?.blocking !== false
  ) {
    throw new Error("Android APK build manifest is not bound to binary facts");
  }
  return {
    ok: true,
    mode: expectedMode,
    byteSize: statSync(snapshotPath).size,
    sha256: facts.artifactDigest,
    path: snapshotPath,
    hasNativeSecureMeshLibrary:
      facts.nativeSecureMeshLibrary?.path ===
        "lib/arm64-v8a/liblico_client_native.so" &&
      facts.nativeSecureMeshLibrary?.regular === true &&
      facts.nativeSecureMeshLibrary?.unique === true &&
      facts.nativeSecureMeshLibrary?.size > 0,
    nativeSecureMeshAbi: facts.abis.length === 1 ? facts.abis[0] : "",
    inspectedWithUnzip: false,
    binaryManifestInspected: true,
    sourceStateDigest: manifest.sourceStateDigest,
    productVersion: manifest.productVersion,
    buildNumber: manifest.buildNumber,
    buildManifestDigest: stableSha256File(manifestPath, {
      maxBytes: 16 * 1024 * 1024,
    }),
    sourceStateMatchesCurrent: true,
    manifestArtifactMatched: true,
    signingKind: manifest.signingKind,
    signatureVerified: true,
    signerIdentityVerified: true,
    signingPolicySatisfied: true,
    packageName: facts.packageName,
    versionCode: facts.versionCode,
    versionName: facts.versionName,
    debuggable: facts.debuggable,
    abis: facts.abis,
    launchableActivity: facts.launchableActivity,
    facts
  };
}

function findDefaultApk() {
  return path.join(repoRoot, "build/apps/desktop/android/release/app-release.apk");
}

function pickAdb() {
  if (String(process.env.ADB || "").trim()) {
    throw new Error("custom adb override is not allowed in a release closure");
  }
  const adb = findAndroidAdbTool(repoRoot, { requireApprovedToolchain: true });
  const result = spawnSync(adb, ["version"], {
    encoding: "utf8",
    env: minimalReleaseToolEnvironment(),
  });
  if (result.status !== 0) {
    throw new Error("adb is not available");
  }
  return adb;
}

function pickDevice(adb, options) {
  const result = run(adb, ["devices"]);
  if (!result.ok) {
    throw new Error("adb devices failed");
  }
  const devices = result.stdout
    .split(/\r?\n/)
    .slice(1)
    .map((line) => line.trim().split(/\s+/))
    .filter(([serial, state]) => serial && state === "device")
    .map(([serial]) => serial);
  if (devices.length === 0) {
    throw new Error("no authorized Android device is connected");
  }
  if (options.serial) {
    if (!devices.includes(options.serial)) {
      throw new Error("configured Android device is not authorized");
    }
    return {
      serial: options.serial,
      authorizedDeviceCount: devices.length,
      physicalProof: classifyAndroidAdbPhysicalDevice(adb, options.serial)
    };
  }
  if (devices.length > 1) {
    throw new Error("multiple Android devices are connected; configure a device id");
  }
  return {
    serial: devices[0],
    authorizedDeviceCount: devices.length,
    physicalProof: classifyAndroidAdbPhysicalDevice(adb, devices[0])
  };
}

function classifyAndroidAdbPhysicalDevice(adb, serial) {
  const props = {};
  const names = [
    "ro.kernel.qemu",
    "ro.boot.qemu",
    "ro.build.characteristics",
    "ro.hardware",
    "ro.boot.hardware",
    "ro.product.manufacturer",
    "ro.product.brand",
    "ro.product.model",
    "ro.product.name",
    "ro.product.device",
    "ro.build.fingerprint"
  ];
  for (const name of names) {
    const result = runAdb(adb, serial, ["shell", "getprop", name], { timeoutMs: 5_000 });
    props[name] = result.ok ? String(result.stdout || "").trim() : "";
  }
  return classifyAndroidGetpropPhysicalDevice(props);
}

function classifyAndroidGetpropPhysicalDevice(props = {}) {
  const missing = [];
  const ambiguous = [];
  const emulatorSignals = new Set();
  const physicalSignals = new Set();
  const value = (name) => String(props[name] || "").trim().toLowerCase();
  // QEMU flags are often unset on physical devices; treat empty as absent, not incomplete.
  const requiredIdentityProps = [
    "ro.build.characteristics",
    "ro.hardware",
    "ro.boot.hardware",
    "ro.product.manufacturer",
    "ro.product.brand",
    "ro.product.model",
    "ro.product.name",
    "ro.product.device",
    "ro.build.fingerprint"
  ];
  for (const name of requiredIdentityProps) {
    if (!value(name)) {
      missing.push(name);
    }
  }
  if (value("ro.kernel.qemu") === "1" || value("ro.boot.qemu") === "1") {
    emulatorSignals.add("qemu_flag");
  } else {
    physicalSignals.add("qemu_absent");
  }
  if (value("ro.build.characteristics").includes("emulator")) {
    emulatorSignals.add("emulator_characteristics");
  } else if (value("ro.build.characteristics")) {
    physicalSignals.add("non_emulator_characteristics");
  }
  if (/(?:goldfish|ranchu|qemu|vbox|emulator|cuttlefish)/u.test([
    value("ro.hardware"),
    value("ro.boot.hardware")
  ].join(" "))) {
    emulatorSignals.add("virtual_hardware");
  } else if (value("ro.hardware") || value("ro.boot.hardware")) {
    physicalSignals.add("non_virtual_hardware");
  }
  if (/(?:generic|sdk|emulator|aosp|cuttlefish|vbox)/u.test([
    value("ro.product.manufacturer"),
    value("ro.product.brand"),
    value("ro.product.model"),
    value("ro.product.name"),
    value("ro.product.device")
  ].join(" "))) {
    emulatorSignals.add("generic_sdk_product");
  }
  if (/(?:generic|sdk|emulator|aosp|cuttlefish|vbox|test-keys)/u.test(value("ro.build.fingerprint"))) {
    emulatorSignals.add("emulator_fingerprint");
  }
  const androidDeviceClass = emulatorSignals.size > 0
    ? "emulator"
    : missing.length > 0
      ? "unknown"
      : "physical";
  if (androidDeviceClass === "unknown") {
    ambiguous.push("getprop_incomplete");
  }
  return {
    androidAdbTransportAuthorized: true,
    androidDeviceClass,
    androidPhysicalDeviceProofReady: androidDeviceClass === "physical",
    androidGetpropProbeReady: missing.length === 0,
    rawGetpropIncluded: false,
    rawDeviceIdentifiersIncluded: false,
    androidEmulatorSignalCategories: [...emulatorSignals].sort(),
    androidPhysicalSignalCategories: [...physicalSignals].sort(),
    androidGetpropMissingFields: missing.sort(),
    androidGetpropAmbiguousFields: ambiguous.sort()
  };
}

function androidPhysicalDeviceProofMissingFields(proof = {}, prefix = "device") {
  return missingFieldPaths([
    [`${prefix}.androidAdbTransportAuthorized`, proof.androidAdbTransportAuthorized === true],
    [`${prefix}.androidDeviceClass`, proof.androidDeviceClass === "physical"],
    [`${prefix}.androidPhysicalDeviceProofReady`, proof.androidPhysicalDeviceProofReady === true],
    [`${prefix}.androidGetpropProbeReady`, proof.androidGetpropProbeReady === true],
    [`${prefix}.rawGetpropIncluded`, proof.rawGetpropIncluded === false],
    [`${prefix}.rawDeviceIdentifiersIncluded`, proof.rawDeviceIdentifiersIncluded === false]
  ]);
}

function androidPhysicalDeviceProofWeakProofFields(proof = {}, prefix = "device") {
  const fields = [];
  if (proof.rawGetpropIncluded === true) {
    fields.push(`${prefix}.rawGetpropIncluded`);
  }
  if (proof.rawDeviceIdentifiersIncluded === true) {
    fields.push(`${prefix}.rawDeviceIdentifiersIncluded`);
  }
  if (proof.androidDeviceClass === "emulator") {
    fields.push(`${prefix}.androidDeviceClass`);
  }
  if (Array.isArray(proof.androidEmulatorSignalCategories) &&
    proof.androidEmulatorSignalCategories.length > 0) {
    fields.push(`${prefix}.androidEmulatorSignalCategories`);
  }
  return stableUniquePaths(fields);
}

function stringList(value) {
  return Array.isArray(value)
    ? value.map((item) => String(item || "").trim()).filter(Boolean).sort()
    : [];
}

function writeBlockedReportIfPossible(error) {
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
    let apk = {
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
      verifier: "tools/scripts/client-android-physical-install-launch.mjs",
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
      nonBlockingDistributionGuidance: {
        blocking: false,
        storeListingStatus: "not-configured",
        platformSigningStatus: "not-configured"
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
          keyMaterialExportedPresent: true,
          keyMaterialExported: false,
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
        rawJsonSecretOverridesUsedPresent: true,
        rawJsonSecretOverridesUsed: false,
        rawJsonSecretOverridesProvenAbsent: false,
        rawJsonSecretOverridesStaticSourceProvenAbsent:
          rawJsonSecretOverridesStaticSourceProof.staticSourceProofReady === true,
        rawJsonSecretOverridesUnknown:
          rawJsonSecretOverridesStaticSourceProof.staticSourceProofReady !== true,
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

function pickAdbIfAvailable() {
  try {
    return pickAdb();
  } catch {
    return "";
  }
}

function authorizedDeviceCountIfAvailable(adb) {
  const result = run(adb, ["devices"]);
  if (!result.ok) {
    return 0;
  }
  return result.stdout
    .split(/\r?\n/)
    .slice(1)
    .map((line) => line.trim().split(/\s+/))
    .filter(([serial, state]) => serial && state === "device")
    .length;
}

function installApk(adb, serial, apk, options) {
  const streamed = runAdb(adb, serial, ["install", "-r", apk.path], {
    timeoutMs: options.installTimeoutMs
  });
  const streamedReady = successfulAdbInstall(streamed);
  const fallback = streamedReady
    ? null
    : runAdb(adb, serial, ["install", "--no-streaming", "-r", apk.path], {
        timeoutMs: options.installTimeoutMs
      });
  const fallbackReady = successfulAdbInstall(fallback);
  return {
    attempted: true,
    installedViaVerifier: streamedReady || fallbackReady,
    ok: streamedReady || fallbackReady,
    fallbackUsed: streamedReady ? false : fallback !== null
  };
}

function successfulAdbInstall(result) {
  return result?.ok === true &&
    /(?:^|\n)Success(?:\r?\n|$)/u.test(String(result.stdout || ""));
}

function isPackageInstalled(adb, serial, packageName) {
  const result = runAdb(adb, serial, ["shell", "pm", "path", packageName]);
  return result.ok && String(result.stdout || "")
    .split(/\r?\n/u)
    .some((line) => line.trim().startsWith("package:") &&
      line.trim().slice("package:".length).startsWith("/"));
}

function resolveLaunchComponent(adb, serial, packageName) {
  const result = runAdb(adb, serial, [
    "shell",
    "cmd",
    "package",
    "resolve-activity",
    "--brief",
    packageName
  ]);
  if (!result.ok) return "";
  const component = String(result.stdout || "")
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .find((line) => line.startsWith(`${packageName}/`)) || "";
  return normalizeLaunchComponent(component);
}

function normalizeLaunchComponent(component) {
  if (!component || !component.includes("/")) return "";
  const [componentPackage, activity] = component.split("/", 2);
  return `${componentPackage}/${activity.startsWith(".") ? `${componentPackage}${activity}` : activity}`;
}

function launchApp(
  adb,
  serial,
  packageName,
  launchComponent,
  closureChallenge,
  invocationNonce,
  timeoutMs
) {
  runAdb(adb, serial, ["shell", "am", "force-stop", packageName], { timeoutMs: 5_000 });
  const staged = runAdb(adb, serial, [
    ...androidReleaseAcceptanceAuthorizationBroadcastArgs({
      closureChallenge,
      invocationNonce,
    }),
  ], { timeoutMs: 5_000 });
  if (!staged.ok || !androidReleaseAcceptanceBroadcastAccepted(staged.stdout)) {
    return { attempted: true, launchedViaVerifier: false, ok: false };
  }
  const result = runAdb(adb, serial, [
    "shell",
    "am",
    "start",
    "-S",
    "-W",
    "-n",
    launchComponent,
  ], { timeoutMs });
  const parsed = parseAmStartResult(result.stdout, launchComponent);
  return {
    attempted: true,
    launchedViaVerifier: result.ok && parsed.ready,
    ok: result.ok && parsed.ready
  };
}

function parseAmStartResult(output, expectedComponent) {
  const source = String(output || "");
  const statusReady = /(?:^|\n)Status:\s*ok(?:\r?\n|$)/iu.test(source);
  const activity = source.match(/(?:^|\n)Activity:\s*([^\s]+)/iu)?.[1] || "";
  const activityReady = normalizeLaunchComponent(activity) === expectedComponent;
  return { ready: statusReady && activityReady };
}

function installedBaseApkDevicePath(adb, serial, packageName) {
  const result = runAdb(adb, serial, ["shell", "pm", "path", packageName], {
    timeoutMs: 10_000
  });
  if (!result.ok) return "";
  const candidates = String(result.stdout || "")
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .filter((line) => line.startsWith("package:"))
    .map((line) => line.slice("package:".length));
  return candidates.find((candidate) => /(?:^|\/)base\.apk$/u.test(candidate)) ||
    (candidates.length === 1 ? candidates[0] : "");
}

function inspectInstalledApk(adb, serial, packageName, workRoot) {
  const devicePath = installedBaseApkDevicePath(adb, serial, packageName);
  if (!devicePath) return { ready: false };
  const installedPath = path.join(workRoot, "installed-base.apk");
  const pulled = spawnSync(adb, [
    "-s",
    serial,
    "pull",
    devicePath,
    installedPath,
  ], {
    cwd: repoRoot,
    stdio: "ignore",
    timeout: 120_000,
    env: minimalReleaseToolEnvironment(),
  });
  if (pulled.status !== 0 || !existsSync(installedPath)) {
    return { ready: false };
  }
  const safeInstalledPath = resolveContainedExistingPath(workRoot, installedPath, {
    expectedKind: "file",
  });
  const facts = inspectAndroidApkFacts(repoRoot, safeInstalledPath, {
    requireApprovedToolchain: true,
  });
  if (facts.packageName !== packageName) return { ready: false };
  return { ready: true, facts };
}

function removeRuntimeStatusFiles(adb, serial, packageName) {
  runAdb(adb, serial, ["shell", "rm", "-f", externalRuntimeStatusPath(packageName)], { timeoutMs: 5_000 });
  runAdb(adb, serial, [
    "shell",
    "run-as",
    packageName,
    "rm",
    "-f",
    runtimeStatusRelativePath
  ], { timeoutMs: 5_000 });
}

async function waitForRuntimeStatus(
  adb,
  serial,
  packageName,
  expectedClosureChallengeDigest,
  expectedInvocationNonceDigest,
  timeoutMs
) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() <= deadline) {
    const result = readRuntimeStatus(adb, serial, packageName);
    if (result.ok) {
      try {
        const status = parseJson(result.stdout);
        if (status.closureChallengeDigest === expectedClosureChallengeDigest &&
          status.invocationNonceDigest === expectedInvocationNonceDigest &&
          status.runtimeStatusFile?.closureChallengeDigest ===
            expectedClosureChallengeDigest &&
          status.runtimeStatusFile?.invocationNonceDigest ===
            expectedInvocationNonceDigest) {
          return { ...result, freshAfterLaunch: true };
        }
      } catch {
        // Continue polling until this invocation's challenged status appears.
      }
    }
    await sleep(1000);
  }
  return { ok: false, stdout: "", source: "", freshAfterLaunch: false };
}

function readRuntimeStatus(adb, serial, packageName) {
  const external = runAdb(adb, serial, ["shell", "cat", externalRuntimeStatusPath(packageName)], {
    timeoutMs: 5_000
  });
  const privateFile = runAdb(adb, serial, [
    "shell",
    "run-as",
    packageName,
    "cat",
    runtimeStatusRelativePath
  ], { timeoutMs: 5_000 });
  const externalText = external.ok ? String(external.stdout || "").trim() : "";
  const privateText = privateFile.ok ? String(privateFile.stdout || "").trim() : "";
  return selectRuntimeStatusOutput(externalText, privateText);
}

function selectRuntimeStatusOutput(externalText, privateText) {
  if (externalText && privateText && externalText !== privateText) {
    return { ok: false, stdout: "", source: "conflicting-runtime-status" };
  }
  if (externalText) {
    return { ok: true, stdout: externalText, source: "external-app-specific" };
  }
  if (privateText) {
    return { ok: true, stdout: privateText, source: "app-private-run-as" };
  }
  return { ok: false, stdout: "", source: "" };
}

function runSelfTest() {
  const releaseApk = {
    mode: "release",
    debuggable: false,
    signingKind: "local-install-keystore",
  };
  if (!physicalReleaseApkReady(releaseApk) ||
    physicalReleaseApkReady({ ...releaseApk, debuggable: true }) ||
    physicalReleaseApkReady({ ...releaseApk, signingKind: "local-debug" })) {
    throw new Error("android_release_apk_policy_self_test_failed");
  }
  if (!successfulAdbInstall({ ok: true, stdout: "Success\n" }) ||
    successfulAdbInstall({ ok: true, stdout: "Failure [test]\n" }) ||
    successfulAdbInstall({ ok: false, stdout: "Success\n" })) {
    throw new Error("android_install_result_self_test_failed");
  }
  const component = "com.liko.arc/com.liko.arc.MainActivity";
  if (!parseAmStartResult(`Status: ok\nActivity: ${component}\n`, component).ready ||
    parseAmStartResult(`Status: ok\nActivity: com.liko.arc/.Other\n`, component).ready ||
    parseAmStartResult(`Status: timeout\nActivity: ${component}\n`, component).ready) {
    throw new Error("android_launch_result_self_test_failed");
  }
  const same = selectRuntimeStatusOutput("{\"ok\":true}", "{\"ok\":true}");
  const conflict = selectRuntimeStatusOutput("{\"ok\":true}", "{\"ok\":false}");
  if (!same.ok || conflict.ok || conflict.source !== "conflicting-runtime-status") {
    throw new Error("android_runtime_status_conflict_self_test_failed");
  }
  if (normalizeLaunchComponent("com.liko.arc/.MainActivity") !== component ||
    normalizeLaunchComponent("com.other/.MainActivity") === component) {
    throw new Error("android_launch_component_self_test_failed");
  }
  let stableIdentityRejected = false;
  try {
    const hostileCertificateDigestKey = ["certificate", "Identity", "Digest"].join("");
    assertNoLeak(
      { [hostileCertificateDigestKey]: `sha256:${"a".repeat(64)}` },
      "Android privacy self-test",
    );
  } catch {
    stableIdentityRejected = true;
  }
  if (!stableIdentityRejected) {
    throw new Error("android_stable_signing_identity_privacy_self_test_failed");
  }
  return { ok: true, mode: "self-test", caseCount: 12, privatePathsIncluded: false };
}

function externalRuntimeStatusPath(packageName) {
  return `/sdcard/Android/data/${packageName}/files/secure-mesh/android-runtime-status.json`;
}

function validateRuntimeStatus(
  status,
  expectedClosureChallengeDigest,
  expectedInvocationNonceDigest
) {
  const secureStore = status.secureStore || {};
  const mobileRelaySecretStore = status.mobileRelaySecretStore || {};
  const nativeRuntime = status.nativeRuntime || {};
  const runtimeStatusFile = status.runtimeStatusFile || {};
  const bridge = status.bridge || {};
  let secureCapabilityReport = null;
  let secureMeasurements = null;
  let mobileSummary = null;
  try {
    secureCapabilityReport = validateAndroidCapabilityProbe(
      secureStore.capabilityProbe,
    );
    secureMeasurements = validateAndroidCapabilityMeasurements(
      secureStore.measurements,
    );
    mobileSummary = summarizeAndroidCapabilityStore(mobileRelaySecretStore);
  } catch {
    secureCapabilityReport = null;
    secureMeasurements = null;
    mobileSummary = null;
  }

  const secureCustodyConsistent = secureCapabilityReport !== null &&
    secureMeasurements !== null &&
    secureCapabilityReport.custody?.strategy === secureMeasurements.custodyStrategy &&
    secureCapabilityReport.custody?.restartSemantics ===
      secureMeasurements.restartSemantics;
  const mobileCustodyConsistent = mobileSummary !== null &&
    mobileSummary.custodyStrategy === secureMeasurements?.custodyStrategy &&
    mobileSummary.restartSemantics === secureMeasurements?.restartSemantics &&
    ["enabled", "available", "unavailable", "unverified", "missingMandatory"]
      .every((field) => JSON.stringify(mobileSummary.capabilityReport?.[field]) ===
        JSON.stringify(secureCapabilityReport?.[field]));
  const mobileRelaySecretStoreContractReady = mobileSummary !== null &&
    mobileSummary.ffiBoundary === "jni" &&
    mobileSummary.secretTransport ===
      "platform_keyring_to_rust_ffi_memory_override" &&
    mobileSummary.secretStoreContract ===
      "rust_secure_mesh_secret_store_handle_v1" &&
    mobileSummary.secretStoreAccountPrefix === "mobileRelayE2ee" &&
    mobileSummary.secretStoreNamespace === "mobileRelayRuntime" &&
    mobileSummary.sharedRustSecretStoreHandleContract === true;
  const adaptiveAuthorizationReady = mobileSummary !== null &&
    mobileSummary.applicationAuthorizationGrantRequired ===
      mobileSummary.userAuthenticationSelected;
  const nativeRuntimeReady =
    nativeRuntime.provider === "lico-client-native" &&
    nativeRuntime.library === "liblico_client_native.so" &&
    nativeRuntime.ffiBoundary === "jni" &&
    nativeRuntime.loaded === true &&
    nativeRuntime.selfTestPassed === true &&
    nativeRuntime.featureFlagsComplete === true &&
    nativeRuntime.usesSharedRustCore === true &&
    nativeRuntime.secretsPassedThroughFfi === false;
  const runtimeStatusRedacted = !objectContainsAnyKeyOrValue(
    status,
    new Set([
      "contentKeyBase64url",
      "includeBodyBase64url",
      "serial",
      "manufacturer",
      "model",
      "deviceId",
      "androidId",
      "keyAlias",
      "attestationChain"
    ])
  ) && nativeRuntime.secretsPassedThroughFfi === false;
  const checks = {
    statusOk: status.ok === true,
    protocolVersion: status.protocolVersion === "licolite.secure-mesh.v1",
    endpointKind: status.endpointKind === "mobile",
    platform: status.platform === "android",
    bridgeChannel: bridge.methodChannel === "licolite.secure_mesh.android",
    bridgeMethods: bridge.statusMethod === true &&
      bridge.writeRuntimeStatusMethod === true &&
      bridge.nativeJsonMethod === true &&
      !hasOwn(bridge, "proofMethod"),
    secureCapabilityReport: secureCustodyConsistent &&
      secureCapabilityReport.mandatoryFoundationComplete === true,
    mobileCapabilityReport: mobileCustodyConsistent &&
      mobileSummary.mandatoryFoundationComplete === true,
    mobileRelaySecretStore: mobileRelaySecretStoreContractReady &&
      mobileSummary.rawJsonSecretOverridesUsed === false &&
      mobileSummary.rawJsonSecretOverridesProvenAbsent === true &&
      mobileSummary.portableConfigRedacted === true &&
      mobileSummary.keyMaterialExported === false,
    adaptiveAuthorization: adaptiveAuthorizationReady,
    nativeRuntime: nativeRuntimeReady,
    authenticatedPairwiseRuntime:
      status.pairwiseRuntimeStatus ===
        ANDROID_AUTHENTICATED_PAIRWISE_RUNTIME_STATUS,
    runtimeStatusRedacted,
    runtimeStatusFile:
      runtimeStatusFile.relativePath === runtimeStatusRelativePath &&
      runtimeStatusFile.writtenByAppProcess === true &&
      runtimeStatusFile.closureChallengeDigest === expectedClosureChallengeDigest &&
      runtimeStatusFile.invocationNonceDigest === expectedInvocationNonceDigest,
    closureChallenge:
      status.closureChallengeDigest === expectedClosureChallengeDigest &&
      status.invocationNonceDigest === expectedInvocationNonceDigest,
    productionBlocked: status.productionReady === false,
    noCanaryPlaintext: !String(status.canaryPlaintext || "").trim()
  };
  const missing = Object.entries(checks)
    .filter(([, ok]) => ok !== true)
    .map(([key]) => key);
  const capabilitySummary = mobileSummary || {
    provider: "",
    ffiBoundary: "",
    secretTransport: "",
    secretStoreBackend: "",
    secretStoreContract: "",
    secretStoreAccountPrefix: "",
    secretStoreNamespace: "",
    sharedRustSecretStoreHandleContract: false,
    rawJsonSecretOverridesUsed: false,
    rawJsonSecretOverridesProvenAbsent: false,
    portableConfigRedacted: false,
    keyMaterialExported: false,
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
  };
  return {
    ok: missing.length === 0,
    missing,
    nativeRuntimeReady,
    authenticatedPairwiseV2RuntimeReady:
      checks.authenticatedPairwiseRuntime,
    runtimeStatusRedacted,
    androidCustodyReady:
      checks.secureCapabilityReport && checks.mobileCapabilityReport,
    adaptiveAuthorizationReady,
    summary: {
      ok: missing.length === 0,
      protocolVersion: checks.protocolVersion,
      bridgeMethodChannelReady: checks.bridgeChannel && checks.bridgeMethods,
      androidCustodyReady:
        checks.secureCapabilityReport && checks.mobileCapabilityReport,
      adaptiveAuthorizationReady,
      privateMaterialExported:
        secureStore.privateMaterialExported === true ||
        capabilitySummary.keyMaterialExported === true,
      nativeRuntimeProvider: nativeRuntime.provider || "",
      nativeRuntimeLoaded: nativeRuntime.loaded === true,
      nativeRuntimeSelfTestPassed: nativeRuntime.selfTestPassed === true,
      nativeRuntimeFeatureFlagsComplete:
        nativeRuntime.featureFlagsComplete === true,
      nativeRuntimeUsesSharedRustCore:
        nativeRuntime.usesSharedRustCore === true,
      secretsPassedThroughFfi: nativeRuntime.secretsPassedThroughFfi === true,
      authenticatedPairwiseV2RuntimeReady:
        checks.authenticatedPairwiseRuntime,
      runtimeStatusRedacted,
      rawPayloadExportSurfaceAbsent:
        checks.bridgeMethods && runtimeStatusRedacted,
      rawRuntimeStatusIncluded: false,
      rawDeviceIdentifiersIncluded: false,
      mobileRelaySecretStoreContractReady,
      mobileRelaySecretStore: {
        provider: capabilitySummary.provider,
        ffiBoundary: capabilitySummary.ffiBoundary,
        secretTransport: capabilitySummary.secretTransport,
        secretStoreBackend: capabilitySummary.secretStoreBackend,
        secretStoreContract: capabilitySummary.secretStoreContract,
        secretStoreAccountPrefix:
          capabilitySummary.secretStoreAccountPrefix,
        secretStoreNamespace: capabilitySummary.secretStoreNamespace,
        sharedRustSecretStoreHandleContract:
          capabilitySummary.sharedRustSecretStoreHandleContract,
        rawJsonSecretOverridesUsedPresent:
          hasOwn(mobileRelaySecretStore, "rawJsonSecretOverridesUsed"),
        rawJsonSecretOverridesUsed:
          capabilitySummary.rawJsonSecretOverridesUsed,
        rawJsonSecretOverridesProvenAbsent:
          capabilitySummary.rawJsonSecretOverridesProvenAbsent,
        rawJsonSecretOverridesStaticSourceProvenAbsent: false,
        portableConfigRedacted:
          capabilitySummary.portableConfigRedacted,
        keyMaterialExported: capabilitySummary.keyMaterialExported,
        keyMaterialExportedPresent:
          hasOwn(mobileRelaySecretStore, "keyMaterialExported"),
        applicationAuthorizationGrantRequired:
          capabilitySummary.applicationAuthorizationGrantRequired,
        custodyStrategy: capabilitySummary.custodyStrategy,
        restartSemantics: capabilitySummary.restartSemantics,
        mandatoryFoundationComplete:
          capabilitySummary.mandatoryFoundationComplete,
        enabledCapabilities: capabilitySummary.enabledCapabilities,
        unavailableCapabilities:
          capabilitySummary.unavailableCapabilities,
        unverifiedCapabilities: capabilitySummary.unverifiedCapabilities,
        userAuthenticationSelected:
          capabilitySummary.userAuthenticationSelected,
        deviceCredentialAvailable:
          capabilitySummary.deviceCredentialAvailable,
        strongBiometricAvailable:
          capabilitySummary.strongBiometricAvailable,
        securityLevel: capabilitySummary.securityLevel,
        capabilityReport: capabilitySummary.capabilityReport,
        measurements: capabilitySummary.measurements,
        missingFields: missing,
        weakProofFields: [],
        missingFieldCount: missing.length,
        weakProofFieldCount: 0,
        implementationStatus:
          String(mobileRelaySecretStore.implementationStatus || "")
      },
      runtimeStatusWrittenByAppProcess:
        runtimeStatusFile.writtenByAppProcess === true,
      closureChallengeBound: checks.closureChallenge && checks.runtimeStatusFile,
      invocationNonceBound: checks.closureChallenge && checks.runtimeStatusFile,
      productionReady: status.productionReady === true,
      missing,
      androidMissingFields: missing,
      androidMissingFieldCount: missing.length,
      androidMissingFieldsAbsent: missing.length === 0,
      androidWeakProofFields: [],
      androidWeakProofFieldCount: 0,
      androidWeakProofFieldsAbsent: true
    }
  };
}

function parseJson(source) {
  try {
    return JSON.parse(String(source || ""));
  } catch {
    throw new Error("Android runtime status JSON is invalid");
  }
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    encoding: "utf8",
    timeout: options.timeoutMs || 30_000,
    maxBuffer: 64 * 1024 * 1024,
    stdio: "pipe",
    env: minimalReleaseToolEnvironment(),
  });
  return {
    ok: result.status === 0,
    status: result.status,
    stdout: String(result.stdout || ""),
    stderr: String(result.stderr || "")
  };
}

function runAdb(adb, serial, args, options = {}) {
  return run(adb, ["-s", serial, ...args], options);
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function stableUniquePaths(paths) {
  return Array.from(new Set(paths.map((item) => String(item || "")).filter(Boolean))).sort();
}

function missingFieldPaths(checks) {
  return stableUniquePaths(
    checks
      .filter(([, ready]) => ready !== true)
      .map(([field]) => field),
  );
}

function hasOwn(object, field) {
  return Object.prototype.hasOwnProperty.call(object, field);
}

function objectContainsAnyKeyOrValue(value, forbidden) {
  if (Array.isArray(value)) {
    return value.some((item) => objectContainsAnyKeyOrValue(item, forbidden));
  }
  if (value && typeof value === "object") {
    return Object.entries(value).some(([key, item]) =>
      forbidden.has(key) || objectContainsAnyKeyOrValue(item, forbidden)
    );
  }
  return forbidden.has(String(value || ""));
}

function assertNoLeak(value, label) {
  if (containsForbiddenStableIdentityKey(value)) {
    throw new Error(`${label} contains sensitive data: stable_signing_identity`);
  }
  const text = JSON.stringify(value);
  const patterns = [
    ["local_path", /\/Users\/|\/private\/|\/var\/folders\/|[A-Za-z]:\\/u],
    ["android_external_path", /\/sdcard\/|\/storage\/emulated\/|\/data\/data\//u],
    ["bearer", /Bearer\s+(?!\[redacted\])\S+/u],
    ["token", /\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]{8,}\b/u],
    ["raw_secret_value", /"(?:privateKeyBase64url|signingKeyBase64url|signedPrekeyPrivateKeyBase64url|oneTimePrekeyPrivateKeyBase64url|pairingSecretBase64url|sessionKey|rootKey|chainKey|messageKey|mobileToken|pcToken|pairingCode)"\s*:\s*"[^"]{8,}"/u],
    ["plaintext_canary", /android-physical-plaintext-canary-/u],
    ["lifecycle_service_action_canary", /android-lifecycle-private-/u],
    ["encoded_plaintext_canary", /(?:YW5kcm9pZC1waHlzaWNhbC1wbGFpbnRleHQtY2FuYXJ5|616e64726f69642d706879736963616c2d706c61696e746578742d63616e617279|\\u0061\\u006e\\u0064\\u0072\\u006f\\u0069\\u0064\\u002d\\u0070\\u0068\\u0079\\u0073\\u0069\\u0063\\u0061\\u006c\\u002d\\u0070\\u006c\\u0061\\u0069\\u006e\\u0074\\u0065\\u0078\\u0074\\u002d\\u0063\\u0061\\u006e\\u0061\\u0072\\u0079)/iu],
    ["device_serial", /"(?:serial|adbSerial)"\s*:/u],
    ["device_model", /"model"\s*:/u]
  ];
  for (const [kind, pattern] of patterns) {
    if (pattern.test(text)) {
      throw new Error(`${label} contains sensitive data: ${kind}`);
    }
  }
}

function containsForbiddenStableIdentityKey(value) {
  if (Array.isArray(value)) {
    return value.some(containsForbiddenStableIdentityKey);
  }
  if (!value || typeof value !== "object") return false;
  return Object.entries(value).some(([key, nested]) => {
    const stableIdentityDigest =
      /(?:(?:signer|certificate|team).*(?:digest|sha(?:256)?|fingerprint)|(?:digest|sha(?:256)?|fingerprint).*(?:signer|certificate|team))/iu;
    return stableIdentityDigest.test(key) ||
      ["signingIdentity", "certificateSubject", "teamIdentifier"].includes(key) ||
      containsForbiddenStableIdentityKey(nested);
  });
}

function sanitizeError(error) {
  return String(error instanceof Error ? error.message : error)
    .replace(/adb\s+-s\s+\S+/gu, "adb -s [redacted]")
    .replace(/\/Users\/[^/\s"]+/gu, "<user-home>")
    .replace(/\/private\/var\/folders\/[^\s"]+/gu, "<local-temp>")
    .replace(/\/sdcard\/[^\s"]+/gu, "<android-external-path>")
    .replace(/\/data\/data\/[^\s"]+/gu, "<android-private-path>")
    .replace(/[A-Za-z]:\\[^\s"]+/gu, "<local-path>")
    .replace(/Bearer\s+\S+/gu, "Bearer [redacted]")
    .replace(/\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]+\b/gu, "[redacted]")
    .replace(/android-physical-plaintext-canary-[0-9a-fA-F-]+/gu, "android-physical-plaintext-canary-[redacted]")
    .replace(/android-lifecycle-private-[0-9a-fA-F-]+/gu, "android-lifecycle-private-[redacted]")
    .replace(/YW5kcm9pZC1waHlzaWNhbC1wbGFpbnRleHQtY2FuYXJ5[A-Za-z0-9+/_=-]*/gu, "android-physical-plaintext-canary:[redacted]")
    .replace(/616e64726f69642d706879736963616c2d706c61696e746578742d63616e617279[0-9a-fA-F]*/gu, "android-physical-plaintext-canary:[redacted]")
    .slice(0, 1200);
}
