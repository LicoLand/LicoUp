import { chmodSync, lstatSync, mkdtempSync, mkdirSync, readlinkSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { artifactTreeSnapshot } from "../lib/client-release-artifact-digest.mjs";
import { androidBlockedClaims, androidRuntimeStatusReady, parseAndroidLaunch, runAndroidArtifactStageSelfTests } from "./android/artifacts.mjs";
import { parseAdbDevices } from "./android/device.mjs";
import { iosBiometricEnrollmentNotification, iosBundleIdentifier, iosCoreSimulatorMachOModeNormalizationPaths, packageName, sentinel } from "./constants.mjs";
import { requireValue } from "./errors.mjs";
import { parseIntegrationSummary } from "./flutter.mjs";
import { ensureControlledIosStagingDirectory, iosArtifactContentMatches, iosArtifactSnapshotMatches, iosBlockedClaims, iosCoreSimulatorInstalledArtifactMatchesStaged, iosInstallIdentityDigest, iosInstallManifestMatches, iosLaunchPid, iosRuntimeStatusReady, makeIosStagingTreeInstallCompatible, makeIosStagingTreeOwnerWritable, prepareIosStagingDirectories, visitIosStagingTree } from "./ios/artifacts.mjs";
import { iosSimulatorArm64Ready, parseBootedIosSimulators, parseNotifyState } from "./ios/device.mjs";
import { buildReceipt, validateReceipt } from "./receipt.mjs";

export function runSelfTest() {
  const androidArtifactStage = runAndroidArtifactStageSelfTests();
  const base = {
    ok: true,
    platform: "android",
    bridgeReady: true,
    nativeFfiReady: true,
    runtimeStatusWritten: true,
    simulatedAuthorizationReady: true,
    simulatorOnlyAuthorization: true,
    physicalDeviceClaimed: false,
    hardwareBackedCustodyClaimed: false,
    realBiometricClaimed: false,
    productionReleaseClaimed: false,
    rawDeviceIdentifierIncluded: false,
    rawPrivateMaterialIncluded: false,
  };
  const encoded = Buffer.from(JSON.stringify(base), "utf8").toString("base64url");
  parseIntegrationSummary(`${sentinel}${encoded}`, "android");
  let overclaimRejected = false;
  try {
    const overclaim = { ...base, physicalDeviceClaimed: true };
    parseIntegrationSummary(
      `${sentinel}${Buffer.from(JSON.stringify(overclaim)).toString("base64url")}`,
      "android",
    );
  } catch {
    overclaimRejected = true;
  }
  requireValue(overclaimRejected, "simulator_summary_overclaim_self_test_failed");
  requireValue(parseAdbDevices("List of devices attached\nemulator-redacted\tdevice\n").length === 1,
    "simulator_adb_parser_self_test_failed");
  requireValue(parseBootedIosSimulators(JSON.stringify({ devices: {
    runtime: [{ udid: "identifier-redacted", state: "Booted", isAvailable: true }],
  }})).length === 1, "simulator_ios_parser_self_test_failed");
  requireValue(iosSimulatorArm64Ready("arm64 x86_64") &&
    !iosSimulatorArm64Ready("x86_64"), "simulator_ios_architecture_self_test_failed");
  requireValue(parseNotifyState(`${iosBiometricEnrollmentNotification} 1`) === 1 &&
    parseNotifyState("notification-state-unavailable") === undefined,
  "simulator_ios_biometric_state_self_test_failed");
  const component = `${packageName}/com.liko.arc.MainActivity`;
  requireValue(parseAndroidLaunch(`Status: ok\nActivity: ${packageName}/.MainActivity\n`, component),
    "simulator_android_launch_self_test_failed");
  const digest = `sha256:${"a".repeat(64)}`;
  const launchedAtEpochMillis = 100_000;
  const bridge = {
    statusMethod: true,
    writeRuntimeStatusMethod: true,
    nativeJsonMethod: true,
  };
  const androidStatus = {
    ok: true,
    platform: "android",
    closureChallengeDigest: digest,
    invocationNonceDigest: digest,
    bridge,
    nativeRuntime: {
      ffiBoundary: "jni",
      loaded: true,
      selfTestPassed: true,
      usesSharedRustCore: true,
    },
    runtimeStatusFile: {
      closureChallengeDigest: digest,
      invocationNonceDigest: digest,
      writtenAtEpochMillis: launchedAtEpochMillis,
    },
  };
  requireValue(androidRuntimeStatusReady(
    androidStatus,
    digest,
    digest,
    launchedAtEpochMillis,
  ) && !androidRuntimeStatusReady(
    { ...androidStatus, closureChallengeDigest: `sha256:${"b".repeat(64)}` },
    digest,
    digest,
    launchedAtEpochMillis,
  ) && !androidRuntimeStatusReady(
    {
      ...androidStatus,
      runtimeStatusFile: {
        ...androidStatus.runtimeStatusFile,
        writtenAtEpochMillis: launchedAtEpochMillis - 5_001,
      },
    },
    digest,
    digest,
    launchedAtEpochMillis,
  ), "simulator_android_runtime_freshness_self_test_failed");
  const iosStatus = {
    ok: true,
    platform: "ios",
    statusKind: "launch-runtime",
    credentialStoreEvaluated: false,
    localAuthenticationEvaluated: false,
    bridge,
    nativeRuntime: {
      ffiBoundary: "c-abi",
      loaded: true,
      selfTestPassed: true,
      usesSharedRustCore: true,
    },
    runtimeStatusFile: {
      writtenByAppProcess: true,
      writtenAtEpochMillis: launchedAtEpochMillis,
    },
  };
  requireValue(iosRuntimeStatusReady(iosStatus, launchedAtEpochMillis) &&
    !iosRuntimeStatusReady({
      ...iosStatus,
      runtimeStatusFile: {
        ...iosStatus.runtimeStatusFile,
        writtenAtEpochMillis: launchedAtEpochMillis - 5_001,
      },
    }, launchedAtEpochMillis), "simulator_ios_runtime_freshness_self_test_failed");
  requireValue(iosLaunchPid(`${iosBundleIdentifier}: 1234\n`) === 1234,
    "simulator_ios_launch_pid_self_test_failed");
  const iosArtifactBaseline = {
    digest,
    installIdentityDigest: `sha256:${"e".repeat(64)}`,
    contentDigest: `sha256:${"b".repeat(64)}`,
    executableDigest: `sha256:${"c".repeat(64)}`,
  };
  requireValue(iosArtifactSnapshotMatches(
    iosArtifactBaseline,
    { ...iosArtifactBaseline },
  ), "simulator_ios_artifact_stability_self_test_failed");
  requireValue(iosArtifactContentMatches(
    iosArtifactBaseline,
    { ...iosArtifactBaseline },
  ) && !iosArtifactContentMatches(iosArtifactBaseline, {
    ...iosArtifactBaseline,
    contentDigest: `sha256:${"d".repeat(64)}`,
  }) && !iosArtifactContentMatches(iosArtifactBaseline, {
    ...iosArtifactBaseline,
    executableDigest: `sha256:${"d".repeat(64)}`,
  }), "simulator_ios_artifact_content_identity_self_test_failed");
  for (const field of [
    "digest",
    "installIdentityDigest",
    "contentDigest",
    "executableDigest",
  ]) {
    requireValue(!iosArtifactSnapshotMatches(iosArtifactBaseline, {
      ...iosArtifactBaseline,
      [field]: `sha256:${"d".repeat(64)}`,
    }), `simulator_ios_artifact_${field}_mutation_self_test_failed`);
  }
  const manifestFile = (entryPath, mode = "0755") => ({
    kind: "file",
    path: entryPath,
    mode,
    depth: entryPath.split("/").length,
    size: 128,
    digest,
  });
  const stagedInstallEntries = [
    { kind: "directory", path: "", mode: "0755", depth: 0, childCount: 9 },
    manifestFile("Runner"),
    ...[...iosCoreSimulatorMachOModeNormalizationPaths].map((entryPath) =>
      manifestFile(entryPath)),
    manifestFile("Frameworks/Other.framework/Other"),
    manifestFile("Assets/config.json", "0644"),
    { kind: "symlink", path: "Frameworks/Safe", mode: "0755", depth: 2,
      target: "App.framework" },
  ];
  const installedNormalizedEntries = stagedInstallEntries.map((entry) =>
    iosCoreSimulatorMachOModeNormalizationPaths.has(entry.path)
      ? { ...entry, mode: "0644" }
      : { ...entry });
  const manifestMutation = (entries, entryPath, changes) => entries.map((entry) =>
    entry.path === entryPath ? { ...entry, ...changes } : { ...entry });
  const machOWhitelistReady = (entryPath) =>
    iosCoreSimulatorMachOModeNormalizationPaths.has(entryPath);
  requireValue(iosInstallManifestMatches(
    stagedInstallEntries,
    installedNormalizedEntries,
    machOWhitelistReady,
  ), "simulator_ios_install_mode_normalization_self_test_failed");
  const syntheticStagedArtifact = {
    contentDigest: digest,
    executableDigest: digest,
    snapshot: { entries: stagedInstallEntries },
  };
  const syntheticInstalledArtifact = {
    contentDigest: digest,
    executableDigest: digest,
    snapshot: { entries: installedNormalizedEntries },
  };
  requireValue(iosCoreSimulatorInstalledArtifactMatchesStaged(
    syntheticInstalledArtifact,
    syntheticStagedArtifact,
    { machOReady: machOWhitelistReady },
  ), "simulator_ios_install_artifact_normalization_self_test_failed");
  const rejectedInstallManifests = [
    manifestMutation(installedNormalizedEntries, "Runner", { mode: "0644" }),
    manifestMutation(installedNormalizedEntries, "Frameworks/Other.framework/Other",
      { mode: "0644" }),
    manifestMutation(installedNormalizedEntries, "Runner.debug.dylib", { mode: "0444" }),
    [...installedNormalizedEntries, manifestFile("unexpected")],
    installedNormalizedEntries.filter((entry) => entry.path !== "Runner.debug.dylib"),
    manifestMutation(installedNormalizedEntries, "Runner.debug.dylib", { kind: "directory" }),
    manifestMutation(installedNormalizedEntries, "Runner.debug.dylib", { size: 129 }),
    manifestMutation(installedNormalizedEntries, "Runner.debug.dylib",
      { digest: `sha256:${"f".repeat(64)}` }),
    manifestMutation(installedNormalizedEntries, "Frameworks/Safe", { target: "Other.framework" }),
  ];
  requireValue(rejectedInstallManifests.every((entries) => !iosInstallManifestMatches(
    stagedInstallEntries,
    entries,
    machOWhitelistReady,
  )), "simulator_ios_install_manifest_hostile_self_test_failed");
  requireValue(!iosInstallManifestMatches(
    stagedInstallEntries,
    installedNormalizedEntries,
    () => false,
  ), "simulator_ios_install_macho_proof_self_test_failed");
  requireValue(!iosCoreSimulatorInstalledArtifactMatchesStaged({
    ...syntheticInstalledArtifact,
    contentDigest: `sha256:${"f".repeat(64)}`,
  }, syntheticStagedArtifact, { machOReady: machOWhitelistReady }) &&
    !iosCoreSimulatorInstalledArtifactMatchesStaged({
      ...syntheticInstalledArtifact,
      executableDigest: `sha256:${"f".repeat(64)}`,
    }, syntheticStagedArtifact, { machOReady: machOWhitelistReady }),
  "simulator_ios_install_content_hostile_self_test_failed");
  const stagingModeRoot = mkdtempSync(path.join(os.tmpdir(),
    "lico-ios-staging-mode-self-test-"));
  try {
    const safeRoot = path.join(stagingModeRoot, "safe");
    mkdirSync(safeRoot, { mode: 0o700 });
    const executable0700 = path.join(safeRoot, "executable-0700");
    const executable0755 = path.join(safeRoot, "executable-0755");
    const regular0644 = path.join(safeRoot, "regular-0644");
    writeFileSync(executable0700, "mode-self-test", { mode: 0o700 });
    writeFileSync(executable0755, "mode-self-test", { mode: 0o755 });
    writeFileSync(regular0644, "mode-self-test", { mode: 0o644 });
    const safeLink = path.join(safeRoot, "safe-link");
    symlinkSync("regular-0644", safeLink);
    const safeLinkTarget = readlinkSync(safeLink);
    makeIosStagingTreeInstallCompatible(safeRoot);
    requireValue((statSync(safeRoot).mode & 0o777) === 0o755 &&
      (statSync(executable0700).mode & 0o777) === 0o755 &&
      (statSync(executable0755).mode & 0o777) === 0o755 &&
      (statSync(regular0644).mode & 0o777) === 0o644,
    "simulator_ios_staging_mode_normalization_self_test_failed");
    requireValue(lstatSync(safeLink).isSymbolicLink() &&
      readlinkSync(safeLink) === safeLinkTarget,
    "simulator_ios_staging_symlink_nofollow_self_test_failed");
    let installTraversalReady = true;
    visitIosStagingTree(safeRoot, (_current, info) => {
      if (info.isSymbolicLink()) return;
      const mode = Number(info.mode & 0o777n);
      installTraversalReady &&= info.isDirectory()
        ? (mode & 0o755) === 0o755
        : (mode & 0o644) === 0o644;
    });
    requireValue(installTraversalReady,
      "simulator_ios_staging_install_traversal_self_test_failed");
    const normalizedSnapshot = artifactTreeSnapshot(safeRoot);
    const normalizedIdentity = iosInstallIdentityDigest(normalizedSnapshot);
    const changedModeSnapshot = {
      ...normalizedSnapshot,
      entries: normalizedSnapshot.entries.map((entry) => entry.path === "regular-0644"
        ? { ...entry, mode: "0500" }
        : entry),
    };
    requireValue(normalizedIdentity !== iosInstallIdentityDigest(changedModeSnapshot),
      "simulator_ios_staging_normalized_identity_self_test_failed");
    writeFileSync(regular0644, "staged-source-mutation");
    const mutatedSnapshot = artifactTreeSnapshot(safeRoot);
    requireValue(normalizedSnapshot.digest !== mutatedSnapshot.digest &&
      normalizedIdentity !== iosInstallIdentityDigest(mutatedSnapshot),
    "simulator_ios_staging_mutation_detection_self_test_failed");

    const unsafeRoot = path.join(stagingModeRoot, "unsafe");
    mkdirSync(unsafeRoot, { mode: 0o700 });
    const outsideTarget = path.join(stagingModeRoot, "outside-target");
    writeFileSync(outsideTarget, "mode-self-test", { mode: 0o600 });
    symlinkSync("../outside-target", path.join(unsafeRoot, "outside-link"));
    let unsafeSymlinkRejected = false;
    try {
      artifactTreeSnapshot(unsafeRoot);
    } catch {
      unsafeSymlinkRejected = true;
    }
    requireValue(unsafeSymlinkRejected,
      "simulator_ios_staging_unsafe_symlink_self_test_failed");
  } finally {
    makeIosStagingTreeOwnerWritable(stagingModeRoot);
    rmSync(stagingModeRoot, { recursive: true, force: true });
  }
  const stagingAncestorRoot = mkdtempSync(path.join(os.tmpdir(),
    "lico-ios-staging-ancestor-self-test-"));
  try {
    const generatedParent = path.join(stagingAncestorRoot, "generated-parent");
    mkdirSync(generatedParent, { mode: 0o711 });
    const unrelatedModeBefore = statSync(generatedParent).mode & 0o777;
    const iosRoot = path.join(generatedParent, "ios");
    const stageParent = path.join(iosRoot, "mobile-simulator-closure-staging");
    mkdirSync(stageParent, { recursive: true, mode: 0o700 });
    chmodSync(iosRoot, 0o700);
    chmodSync(stageParent, 0o700);
    const prepared = prepareIosStagingDirectories(stagingAncestorRoot, generatedParent);
    requireValue((statSync(prepared.iosRoot).mode & 0o777) === 0o755 &&
      (statSync(prepared.stageParent).mode & 0o777) === 0o755 &&
      (statSync(prepared.stageRoot).mode & 0o777) === 0o755,
    "simulator_ios_staging_ancestor_repair_self_test_failed");
    requireValue((statSync(generatedParent).mode & 0o777) === unrelatedModeBefore,
      "simulator_ios_staging_unrelated_parent_self_test_failed");

    const symlinkGeneratedParent = path.join(stagingAncestorRoot, "symlink-parent");
    const symlinkTarget = path.join(stagingAncestorRoot, "symlink-target");
    mkdirSync(symlinkGeneratedParent, { mode: 0o755 });
    mkdirSync(symlinkTarget, { mode: 0o755 });
    symlinkSync(symlinkTarget, path.join(symlinkGeneratedParent, "ios"));
    let symlinkAncestorRejected = false;
    try {
      prepareIosStagingDirectories(stagingAncestorRoot, symlinkGeneratedParent);
    } catch {
      symlinkAncestorRejected = true;
    }
    requireValue(symlinkAncestorRejected,
      "simulator_ios_staging_symlink_ancestor_self_test_failed");

    let escapedTargetRejected = false;
    try {
      ensureControlledIosStagingDirectory(generatedParent,
        path.join(generatedParent, "..", "escaped"));
    } catch {
      escapedTargetRejected = true;
    }
    requireValue(escapedTargetRejected,
      "simulator_ios_staging_escape_self_test_failed");
  } finally {
    makeIosStagingTreeOwnerWritable(stagingAncestorRoot);
    rmSync(stagingAncestorRoot, { recursive: true, force: true });
  }
  const report = buildReceipt({
    platform: "android",
    targetId: "android-simulator-arm64",
    sourceStateDigest: digest,
    artifactKind: "android-debug-apk",
    artifactDigest: digest,
    runtimeExecutableDigest: digest,
    integrationSummary: base,
    blockedClaims: androidBlockedClaims(),
  });
  validateReceipt(report);
  const iosReport = buildReceipt({
    platform: "ios",
    targetId: "ios-simulator-arm64",
    sourceStateDigest: digest,
    artifactKind: "ios-simulator-app",
    artifactDigest: digest,
    runtimeExecutableDigest: digest,
    integrationSummary: { ...base, platform: "ios" },
    blockedClaims: iosBlockedClaims(),
    functionalHarnessExactArtifact: false,
  });
  validateReceipt(iosReport);
  let harnessOverclaimRejected = false;
  try {
    validateReceipt({
      ...iosReport,
      functionalHarness: {
        ...iosReport.functionalHarness,
        exactReleaseArtifact: true,
      },
    });
  } catch {
    harnessOverclaimRejected = true;
  }
  requireValue(harnessOverclaimRejected,
    "simulator_ios_functional_harness_overclaim_self_test_failed");
  let exactArtifactMutationRejected = true;
  for (const field of Object.keys(iosReport.exactReleaseArtifact)) {
    let fieldMutationRejected = false;
    try {
      validateReceipt({
        ...iosReport,
        exactReleaseArtifact: {
          ...iosReport.exactReleaseArtifact,
          [field]: false,
        },
      });
    } catch {
      fieldMutationRejected = true;
    }
    exactArtifactMutationRejected &&= fieldMutationRejected;
  }
  requireValue(exactArtifactMutationRejected,
    "simulator_ios_exact_artifact_mutation_self_test_failed");
  let identityLeakRejected = false;
  try {
    validateReceipt({
      ...report,
      simulator: { ...report.simulator, udid: "identifier-must-not-appear" },
    });
  } catch {
    identityLeakRejected = true;
  }
  requireValue(identityLeakRejected, "simulator_receipt_identity_self_test_failed");
  let receiptOverclaimRejected = false;
  try {
    validateReceipt({
      ...report,
      excludedClaims: { ...report.excludedClaims, physicalDeviceReady: true },
    });
  } catch {
    receiptOverclaimRejected = true;
  }
  requireValue(receiptOverclaimRejected, "simulator_receipt_overclaim_self_test_failed");
  return {
    ok: true,
    mode: "self-test",
    caseCount: 68,
    androidArtifactStage,
    simulatorOverclaimRejected: true,
    functionalHarnessOverclaimRejected: true,
    exactArtifactMutationRejected: true,
    receiptOverclaimRejected: true,
    identityLeakRejected: true,
    deviceIdentifiersIncluded: false,
    privatePathsIncluded: false,
  };
}
