#!/usr/bin/env node

import { spawn, spawnSync } from "node:child_process";
import { createHash, randomInt } from "node:crypto";
import {
  chmodSync,
  cpSync,
  existsSync,
  linkSync,
  lstatSync,
  mkdtempSync,
  mkdirSync,
  readlinkSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  seedClientGradleHome,
  withClientToolchainEnv,
} from "./client-toolchain-env.mjs";
import {
  artifactTreeContentDigest,
  artifactTreeSnapshot,
  resolveContainedExistingPath,
  sha256File,
  stableReadFile,
} from "./lib/client-release-artifact-digest.mjs";
import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  clientSourceStateDigest,
} from "./lib/client-source-state-digest.mjs";
import {
  ANDROID_APK_RESOURCE_LIMITS,
  inspectAndroidApkFacts,
  findAndroidAdbTool,
} from "./lib/android-apk-facts.mjs";
import {
  androidReleaseAcceptanceAuthorizationBroadcastArgs,
  androidReleaseAcceptanceBroadcastAccepted,
} from "./lib/android-release-acceptance-binding.mjs";
import {
  createReleaseClosureChallenge,
  createReleaseInvocationNonce,
  releaseClosureChallengeDigest,
  releaseInvocationNonceDigest,
} from "./lib/release-closure-challenge.mjs";
import {
  atomicReplaceContainedFileSnapshot,
  atomicWriteReportJson,
  removeContainedReportIfExists,
} from "./lib/safe-report-io.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const flutterRoot = path.join(repoRoot, "apps", "desktop");
const buildRoot = path.join(repoRoot, "build");
const reportRefs = Object.freeze({
  android: "reports/android-simulator-build-closure.json",
  ios: "reports/ios-simulator-build-closure.json",
});
const androidSimulatorArtifactRef =
  "apps/desktop/android/simulator/app-debug.apk";
const sentinel = "LICO_MOBILE_SIMULATOR_CLOSURE_SUMMARY ";
const packageName = "com.liko.arc";
const iosBundleIdentifier = "app.licoarc";
const iosCoreSimulatorMachOModeNormalizationPaths = Object.freeze(new Set([
  "Frameworks/App.framework/App",
  "Frameworks/Flutter.framework/Flutter",
  "Frameworks/objective_c.framework/objective_c",
  "Runner.debug.dylib",
  "__preview.dylib",
]));
const maxFlutterOutputBytes = 64 * 1024 * 1024;

class ClosureError extends Error {
  constructor(category) {
    super(category);
    this.category = category;
  }
}

function requireValue(condition, category) {
  if (!condition) throw new ClosureError(category);
}

function runClosureStage(category, action) {
  try {
    return action();
  } catch (error) {
    if (error instanceof ClosureError) throw error;
    throw new ClosureError(category);
  }
}

function command(file, args, options = {}) {
  return spawnSync(file, args, {
    cwd: options.cwd || repoRoot,
    env: options.env || process.env,
    encoding: "utf8",
    stdio: "pipe",
    timeout: options.timeoutMs || 30_000,
    maxBuffer: options.maxBuffer || 32 * 1024 * 1024,
  });
}

function commandReady(result) {
  return result.status === 0 && result.error === undefined;
}

function parseArgs(argv = process.argv.slice(2)) {
  const options = { platform: "all", selfTest: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--self-test") {
      options.selfTest = true;
    } else if (arg === "--platform" && argv[index + 1]) {
      options.platform = String(argv[index + 1]).toLowerCase();
      index += 1;
    } else {
      throw new ClosureError("simulator_closure_arguments_invalid");
    }
  }
  requireValue(["android", "ios", "all"].includes(options.platform),
    "simulator_closure_platform_invalid");
  return options;
}

function selectedPlatforms(platform) {
  return platform === "all" ? ["android", "ios"] : [platform];
}

function prepareFlutterDependencies() {
  const result = command("flutter", ["pub", "get", "--enforce-lockfile", "--offline"], {
    cwd: flutterRoot,
    env: withClientToolchainEnv(),
    timeoutMs: 120_000,
  });
  requireValue(commandReady(result), "flutter_dependencies_unavailable");
}

function parseAdbDevices(output) {
  return String(output || "")
    .split(/\r?\n/u)
    .slice(1)
    .map((line) => line.trim().split(/\s+/u))
    .filter(([serial, state]) => serial && state === "device")
    .map(([serial]) => serial);
}

function androidSimulatorProof(adb, serial) {
  const readProp = (name) => {
    const result = command(adb, ["-s", serial, "shell", "getprop", name], {
      timeoutMs: 5_000,
    });
    return commandReady(result) ? String(result.stdout || "").trim().toLowerCase() : "";
  };
  const qemu = readProp("ro.kernel.qemu") === "1" || readProp("ro.boot.qemu") === "1";
  const hardware = `${readProp("ro.hardware")} ${readProp("ro.boot.hardware")}`;
  const characteristics = readProp("ro.build.characteristics");
  const architectureReady = readProp("ro.product.cpu.abi") === "arm64-v8a";
  const virtualized = qemu || /(?:goldfish|ranchu|qemu|cuttlefish)/u.test(hardware) ||
    characteristics.includes("emulator");
  return virtualized && architectureReady;
}

function selectAndroidSimulator() {
  let adb;
  try {
    adb = findAndroidAdbTool(repoRoot, { requireApprovedToolchain: false });
  } catch {
    throw new ClosureError("android_sdk_tools_unavailable");
  }
  const listed = command(adb, ["devices"], { timeoutMs: 10_000 });
  requireValue(commandReady(listed), "android_adb_unavailable");
  const devices = parseAdbDevices(listed.stdout);
  const configured = String(process.env.LICO_CLIENT_ANDROID_EMULATOR || "").trim();
  const candidates = configured
    ? devices.filter((serial) => serial === configured && androidSimulatorProof(adb, serial))
    : devices.filter((serial) => androidSimulatorProof(adb, serial));
  requireValue(candidates.length === 1, candidates.length === 0
    ? "android_emulator_unavailable"
    : "android_emulator_selection_ambiguous");
  return { adb, device: candidates[0] };
}

function parseBootedIosSimulators(output) {
  let payload;
  try {
    payload = JSON.parse(String(output || "{}"));
  } catch {
    return [];
  }
  return Object.values(payload.devices || {})
    .flatMap((devices) => Array.isArray(devices) ? devices : [])
    .filter((device) => device?.state === "Booted" && device?.isAvailable !== false)
    .map((device) => String(device.udid || "").trim())
    .filter(Boolean);
}

function iosSimulatorArm64Ready(output) {
  return String(output || "")
    .trim()
    .split(/\s+/u)
    .includes("arm64");
}

function selectIosSimulator() {
  requireValue(process.platform === "darwin", "ios_simulator_requires_macos");
  const listed = command("xcrun", ["simctl", "list", "devices", "booted", "--json"], {
    timeoutMs: 20_000,
  });
  requireValue(commandReady(listed), "ios_simctl_unavailable");
  const booted = parseBootedIosSimulators(listed.stdout);
  const configured = String(process.env.LICO_CLIENT_IOS_SIMULATOR || "").trim();
  const candidates = configured ? booted.filter((device) => device === configured) : booted;
  requireValue(candidates.length === 1, candidates.length === 0
    ? "ios_simulator_unavailable"
    : "ios_simulator_selection_ambiguous");
  const architecture = command("xcrun", [
    "simctl",
    "getenv",
    candidates[0],
    "SIMULATOR_ARCHS",
  ], {
    timeoutMs: 10_000,
  });
  requireValue(commandReady(architecture) &&
    iosSimulatorArm64Ready(architecture.stdout),
  "ios_simulator_architecture_unavailable");
  return { device: candidates[0] };
}

function configureAndroidSimulatedCredential(adb, device) {
  const pin = String(randomInt(100000, 999999));
  let inputFailed = false;
  let inputAttempts = 0;
  command(adb, ["-s", device, "shell", "input", "keyevent", "82"], { timeoutMs: 5_000 });
  const configured = command(adb, ["-s", device, "shell", "locksettings", "set-pin", pin], {
    timeoutMs: 10_000,
  });
  if (!commandReady(configured)) {
    const compensated = command(adb, [
      "-s",
      device,
      "shell",
      "locksettings",
      "clear",
      "--old",
      pin,
    ], { timeoutMs: 10_000 });
    requireValue(commandReady(compensated),
      "android_simulated_credential_setup_cleanup_failed");
    throw new ClosureError("android_simulated_credential_setup_failed");
  }
  return {
    tick() {
      if (inputAttempts >= 3) return;
      const windows = command(adb, ["-s", device, "shell", "dumpsys", "window", "windows"], {
        timeoutMs: 5_000,
      });
      if (!commandReady(windows) || !/(?:ConfirmDeviceCredential|ConfirmLockPassword|ConfirmLockPattern|ConfirmLockPatternPassword)/iu.test(
        String(windows.stdout || ""),
      )) return;
      inputAttempts += 1;
      const entered = command(adb, ["-s", device, "shell", "input", "text", pin], {
        timeoutMs: 5_000,
      });
      const submitted = command(adb, ["-s", device, "shell", "input", "keyevent", "66"], {
        timeoutMs: 5_000,
      });
      if (!commandReady(entered) || !commandReady(submitted)) inputFailed = true;
    },
    cleanup() {
      const cleared = command(adb, ["-s", device, "shell", "locksettings", "clear", "--old", pin], {
        timeoutMs: 10_000,
      });
      return commandReady(cleared);
    },
    healthy() {
      return inputFailed === false;
    },
  };
}

const iosBiometricEnrollmentNotification = "com.apple.BiometricKit.enrollmentChanged";
const iosBiometricMatchNotifications = [
  "com.apple.BiometricKit_Sim.pearl.match",
  "com.apple.BiometricKit_Sim.fingerTouch.match",
  "com.apple.BiometricKit_Sim.oyster.match",
];

function notifyCommandReady(result) {
  return commandReady(result) &&
    !/failed with code/iu.test(`${result.stdout || ""}\n${result.stderr || ""}`);
}

function parseNotifyState(output) {
  const match = String(output || "").trim().match(/(?:^|\s)([01])$/u);
  return match ? Number.parseInt(match[1], 10) : undefined;
}

function readIosSimulatorBiometricEnrollment() {
  const result = command("/usr/bin/notifyutil", [
    "-z",
    "0",
    "-g",
    iosBiometricEnrollmentNotification,
  ], { timeoutMs: 10_000 });
  return notifyCommandReady(result) ? parseNotifyState(result.stdout) : undefined;
}

function setIosSimulatorBiometricEnrollment(state) {
  const value = state === 1 ? "1" : "0";
  const updated = command("/usr/bin/notifyutil", [
    "-z",
    "0",
    "-s",
    iosBiometricEnrollmentNotification,
    value,
  ], { timeoutMs: 10_000 });
  const posted = command("/usr/bin/notifyutil", [
    "-z",
    "0",
    "-p",
    iosBiometricEnrollmentNotification,
  ], { timeoutMs: 10_000 });
  return notifyCommandReady(updated) && notifyCommandReady(posted);
}

function configureIosSimulatedBiometric(device) {
  const enrolled = command("xcrun", ["simctl", "biometric", device, "enroll"], {
    timeoutMs: 10_000,
  });
  if (commandReady(enrolled)) {
    return {
      tick() {
        command("xcrun", ["simctl", "biometric", device, "match", "face"], {
          timeoutMs: 5_000,
        });
        command("xcrun", ["simctl", "biometric", device, "match", "finger"], {
          timeoutMs: 5_000,
        });
      },
      cleanup() {
        const cleared = command("xcrun", ["simctl", "biometric", device, "unenroll"], {
          timeoutMs: 10_000,
        });
        return commandReady(cleared);
      },
      healthy() {
        return true;
      },
    };
  }

  const previousEnrollment = readIosSimulatorBiometricEnrollment() ?? 0;
  requireValue(setIosSimulatorBiometricEnrollment(1),
    "ios_simulated_biometric_setup_failed");
  let matchFailed = false;
  return {
    tick() {
      for (const notification of iosBiometricMatchNotifications) {
        const matched = command("/usr/bin/notifyutil", [
          "-z",
          "0",
          "-p",
          notification,
        ], { timeoutMs: 5_000 });
        if (!notifyCommandReady(matched)) matchFailed = true;
      }
    },
    cleanup() {
      return setIosSimulatorBiometricEnrollment(previousEnrollment);
    },
    healthy() {
      return matchFailed === false;
    },
  };
}

function runFlutterIntegration(platform, device, authenticator) {
  return new Promise((resolve, reject) => {
    const child = spawn("flutter", [
      "test",
      "integration_test/mobile_simulator_closure_test.dart",
      "-d",
      device,
      "--no-pub",
      "--no-uninstall",
    ], {
      cwd: flutterRoot,
      env: withClientToolchainEnv(),
      stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "";
    let outputExceeded = false;
    const collect = (chunk) => {
      if (outputExceeded) return;
      output += chunk.toString();
      if (Buffer.byteLength(output, "utf8") > maxFlutterOutputBytes) {
        outputExceeded = true;
        output = "";
        child.kill("SIGKILL");
      }
    };
    child.stdout.on("data", collect);
    child.stderr.on("data", collect);
    const tick = setInterval(() => authenticator.tick(), 800);
    const timeout = setTimeout(() => child.kill("SIGKILL"), 10 * 60 * 1000);
    child.on("error", () => {
      clearInterval(tick);
      clearTimeout(timeout);
      reject(new ClosureError(`${platform}_flutter_integration_start_failed`));
    });
    child.on("close", (code) => {
      clearInterval(tick);
      clearTimeout(timeout);
      if (outputExceeded) {
        reject(new ClosureError(`${platform}_flutter_output_limit_exceeded`));
        return;
      }
      if (code !== 0) {
        reject(new ClosureError(`${platform}_simulator_integration_failed`));
        return;
      }
      if (authenticator.healthy() !== true) {
        reject(new ClosureError(`${platform}_simulated_auth_automation_failed`));
        return;
      }
      try {
        resolve(parseIntegrationSummary(output, platform));
      } catch (error) {
        reject(error);
      }
    });
  });
}

function parseIntegrationSummary(output, expectedPlatform) {
  const encoded = String(output || "").match(
    new RegExp(`${sentinel}([A-Za-z0-9_-]+)`, "u"),
  )?.[1];
  requireValue(Boolean(encoded), `${expectedPlatform}_simulator_summary_missing`);
  let summary;
  try {
    summary = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8"));
  } catch {
    throw new ClosureError(`${expectedPlatform}_simulator_summary_invalid`);
  }
  const keys = [
    "ok",
    "platform",
    "bridgeReady",
    "nativeFfiReady",
    "runtimeStatusWritten",
    "simulatedAuthorizationReady",
    "simulatorOnlyAuthorization",
    "physicalDeviceClaimed",
    "hardwareBackedCustodyClaimed",
    "realBiometricClaimed",
    "productionReleaseClaimed",
    "rawDeviceIdentifierIncluded",
    "rawPrivateMaterialIncluded",
  ];
  requireValue(summary && typeof summary === "object" && !Array.isArray(summary) &&
    JSON.stringify(Object.keys(summary).sort()) === JSON.stringify([...keys].sort()),
  `${expectedPlatform}_simulator_summary_shape_invalid`);
  requireValue(summary.platform === expectedPlatform && summary.ok === true &&
    summary.bridgeReady === true && summary.nativeFfiReady === true &&
    summary.runtimeStatusWritten === true && summary.simulatedAuthorizationReady === true &&
    summary.simulatorOnlyAuthorization === true &&
    [
      summary.physicalDeviceClaimed,
      summary.hardwareBackedCustodyClaimed,
      summary.realBiometricClaimed,
      summary.productionReleaseClaimed,
      summary.rawDeviceIdentifierIncluded,
      summary.rawPrivateMaterialIncluded,
    ].every((value) => value === false),
  `${expectedPlatform}_simulator_summary_not_ready`);
  return summary;
}

function newestAndroidDebugApk() {
  const candidates = [
    path.join(flutterRoot, "build", "app", "outputs", "flutter-apk", "app-debug.apk"),
    path.join(flutterRoot, "build", "app", "outputs", "apk", "debug", "app-debug.apk"),
  ].filter(existsSync);
  requireValue(candidates.length > 0, "android_simulator_artifact_missing");
  return candidates.sort((left, right) => statSync(right).mtimeMs - statSync(left).mtimeMs)[0];
}

function stageAndroidSimulatorArtifact(apk, {
  allowedRoot = buildRoot,
  targetRef = androidSimulatorArtifactRef,
  beforePublish,
} = {}) {
  return runClosureStage("android_simulator_artifact_stage_failed", () =>
    atomicReplaceContainedFileSnapshot(allowedRoot, targetRef, apk, {
      maxBytes: ANDROID_APK_RESOURCE_LIMITS.maxApkBytes,
      beforePublish,
    }));
}

function inspectInstalledAndroidApk(adb, device, workRoot) {
  const packagePath = command(adb, ["-s", device, "shell", "pm", "path", packageName], {
    timeoutMs: 10_000,
  });
  requireValue(commandReady(packagePath), "android_installed_artifact_missing");
  const remote = String(packagePath.stdout || "")
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .find((line) => line.startsWith("package:") && line.endsWith("/base.apk"));
  requireValue(Boolean(remote), "android_installed_base_apk_missing");
  const local = path.join(workRoot, "installed-base.apk");
  const pulled = command(adb, ["-s", device, "pull", remote.slice("package:".length), local], {
    timeoutMs: 120_000,
  });
  requireValue(commandReady(pulled) && existsSync(local), "android_installed_apk_pull_failed");
  return local;
}

function parseAndroidLaunch(output, expectedComponent) {
  const text = String(output || "");
  const statusReady = /(?:^|\n)Status:\s*ok(?:\r?\n|$)/iu.test(text);
  const activity = text.match(/(?:^|\n)Activity:\s*([^\s]+)/iu)?.[1] || "";
  const [activityPackage, activityClass = ""] = activity.split("/", 2);
  const normalized = activityClass.startsWith(".")
    ? `${activityPackage}/${activityPackage}${activityClass}`
    : activity;
  return statusReady && normalized === expectedComponent;
}

function androidRuntimeStatusReady(
  status,
  expectedClosureChallengeDigest,
  expectedInvocationNonceDigest,
  launchedAtEpochMillis,
) {
  const nativeRuntime = status?.nativeRuntime || {};
  const bridge = status?.bridge || {};
  const runtimeStatusFile = status?.runtimeStatusFile || {};
  return status?.platform === "android" && status.ok === true &&
    status.closureChallengeDigest === expectedClosureChallengeDigest &&
    status.invocationNonceDigest === expectedInvocationNonceDigest &&
    runtimeStatusFile.closureChallengeDigest === expectedClosureChallengeDigest &&
    runtimeStatusFile.invocationNonceDigest === expectedInvocationNonceDigest &&
    Number(runtimeStatusFile.writtenAtEpochMillis || 0) >= launchedAtEpochMillis - 5_000 &&
    nativeRuntime.ffiBoundary === "jni" && nativeRuntime.loaded === true &&
    nativeRuntime.selfTestPassed === true && nativeRuntime.usesSharedRustCore === true &&
    bridge.statusMethod === true && bridge.writeRuntimeStatusMethod === true &&
    bridge.nativeJsonMethod === true;
}

async function waitForAndroidRuntimeStatus(
  adb,
  device,
  expectedClosureChallengeDigest,
  expectedInvocationNonceDigest,
  launchedAtEpochMillis,
) {
  const deadline = Date.now() + 30_000;
  while (Date.now() <= deadline) {
    const result = command(adb, [
      "-s", device, "shell", "run-as", packageName,
      "cat", "files/secure-mesh/android-runtime-status.json",
    ], { timeoutMs: 5_000 });
    if (commandReady(result)) {
      try {
        const status = JSON.parse(String(result.stdout || "{}"));
        if (androidRuntimeStatusReady(
          status,
          expectedClosureChallengeDigest,
          expectedInvocationNonceDigest,
          launchedAtEpochMillis,
        )) {
          return true;
        }
      } catch {
        // A prior partial write cannot satisfy this invocation.
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 750));
  }
  return false;
}

function androidProcessAlive(adb, device) {
  const result = command(adb, ["-s", device, "shell", "pidof", packageName], {
    timeoutMs: 5_000,
  });
  return commandReady(result) && String(result.stdout || "").trim()
    .split(/\s+/u)
    .some((value) => /^[1-9][0-9]*$/u.test(value));
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function androidBlockedClaims() {
  return [
    "physical_android_keystore_custody",
    "hardware_backed_key_attestation",
    "real_biometric_user_presence",
    "physical_cross_device_encryption",
    "production_signing_and_store_distribution",
  ];
}

function iosBlockedClaims() {
  return [
    "physical_ios_keychain_custody",
    "secure_enclave_key_protection",
    "real_biometric_user_presence",
    "physical_cross_device_encryption",
    "production_signing_and_store_distribution",
  ];
}

function buildReceipt({
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
    schemaVersion: "licolite.client-mobile-simulator-closure.v2",
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

function validateReceipt(report) {
  requireValue(report?.ok === true && report.localSimulatorClosureReady === true &&
    report.schemaVersion === "licolite.client-mobile-simulator-closure.v2" &&
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

function objectContainsForbiddenIdentityField(value) {
  if (Array.isArray(value)) {
    return value.some(objectContainsForbiddenIdentityField);
  }
  if (!value || typeof value !== "object") return false;
  const forbidden = new Set(["deviceId", "serialNumber", "udid", "androidId"]);
  return Object.entries(value).some(([key, child]) =>
    forbidden.has(key) || objectContainsForbiddenIdentityField(child));
}

async function verifyAndroid() {
  removeContainedReportIfExists(buildRoot, reportRefs.android);
  const { adb, device } = selectAndroidSimulator();
  seedClientGradleHome(withClientToolchainEnv());
  const sourceBefore = clientSourceStateDigest(repoRoot, CANONICAL_CLIENT_SOURCE_ROOTS);
  const authenticator = configureAndroidSimulatedCredential(adb, device);
  let summary;
  let integrationFailure;
  try {
    summary = await runFlutterIntegration("android", device, authenticator);
  } catch (error) {
    integrationFailure = error;
  } finally {
    if (authenticator.cleanup() !== true) {
      throw new ClosureError("android_simulated_credential_cleanup_failed");
    }
  }
  if (integrationFailure) throw integrationFailure;
  requireValue(clientSourceStateDigest(repoRoot, CANONICAL_CLIENT_SOURCE_ROOTS) === sourceBefore,
    "android_source_changed_during_build");

  const apk = runClosureStage("android_simulator_artifact_selection_failed", () =>
    newestAndroidDebugApk());
  const facts = runClosureStage("android_simulator_artifact_inspection_failed", () =>
    inspectAndroidApkFacts(repoRoot, apk, { requireApprovedToolchain: true }));
  requireValue(facts.packageName === packageName && facts.debuggable === true &&
    facts.nativeSecureMeshLibrary?.regular === true,
  "android_simulator_apk_facts_invalid");
  const staged = stageAndroidSimulatorArtifact(apk);
  const artifactDigest = runClosureStage("android_simulator_artifact_digest_failed", () =>
    sha256File(staged, { maxBytes: ANDROID_APK_RESOURCE_LIMITS.maxApkBytes }));
  requireValue(artifactDigest === facts.artifactDigest, "android_staged_artifact_mismatch");

  const tempRoot = mkdtempSync(path.join(os.tmpdir(), "lico-android-simulator-receipt-"));
  try {
    const testedApk = inspectInstalledAndroidApk(adb, device, tempRoot);
    requireValue(sha256File(testedApk) === artifactDigest,
      "android_tested_artifact_mismatch");
    const installed = command(adb, ["-s", device, "install", "-r", "-t", staged], {
      timeoutMs: 180_000,
    });
    requireValue(commandReady(installed) && /(?:^|\n)Success\s*(?:\r?\n|$)/u.test(
      String(installed.stdout || "")), "android_simulator_install_failed");
    const installedApk = inspectInstalledAndroidApk(adb, device, tempRoot);
    requireValue(sha256File(installedApk) === artifactDigest,
      "android_installed_artifact_mismatch");
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
  const stopped = command(adb, ["-s", device, "shell", "am", "force-stop", packageName], {
    timeoutMs: 5_000,
  });
  requireValue(commandReady(stopped), "android_simulator_force_stop_failed");
  const removed = command(adb, ["-s", device, "shell", "run-as", packageName, "rm", "-f",
    "files/secure-mesh/android-runtime-status.json"], { timeoutMs: 5_000 });
  requireValue(commandReady(removed), "android_runtime_status_cleanup_failed");
  const stale = command(adb, ["-s", device, "shell", "run-as", packageName, "cat",
    "files/secure-mesh/android-runtime-status.json"], { timeoutMs: 5_000 });
  requireValue(!commandReady(stale), "android_runtime_status_cleanup_unverified");
  const closureChallenge = createReleaseClosureChallenge();
  const invocationNonce = createReleaseInvocationNonce();
  const stagedAcceptance = command(adb, [
    "-s",
    device,
    ...androidReleaseAcceptanceAuthorizationBroadcastArgs({
      closureChallenge,
      invocationNonce,
    }),
  ], { timeoutMs: 5_000 });
  requireValue(commandReady(stagedAcceptance) &&
    androidReleaseAcceptanceBroadcastAccepted(stagedAcceptance.stdout),
  "android_runtime_challenge_stage_failed");
  const component = `${packageName}/${facts.launchableActivity}`;
  const launchedAtEpochMillis = Date.now();
  const launched = command(adb, ["-s", device, "shell", "am", "start", "-W",
    "-n", component], { timeoutMs: 60_000 });
  requireValue(commandReady(launched) && parseAndroidLaunch(launched.stdout, component),
    "android_simulator_launch_failed");
  requireValue(await waitForAndroidRuntimeStatus(
    adb,
    device,
    releaseClosureChallengeDigest(closureChallenge),
    releaseInvocationNonceDigest(invocationNonce),
    launchedAtEpochMillis,
  ),
    "android_simulator_native_runtime_status_failed");
  await sleep(1_500);
  requireValue(androidProcessAlive(adb, device), "android_simulator_process_not_alive");
  command(adb, ["-s", device, "shell", "input", "keyevent", "4"], { timeoutMs: 5_000 });
  requireValue(clientSourceStateDigest(repoRoot, CANONICAL_CLIENT_SOURCE_ROOTS) === sourceBefore,
    "android_source_changed_during_install_launch");

  const receipt = buildReceipt({
    platform: "android",
    targetId: "android-simulator-arm64",
    sourceStateDigest: sourceBefore,
    artifactKind: "android-debug-apk",
    artifactDigest,
    runtimeExecutableDigest: facts.nativeSecureMeshLibrary.contentDigest,
    integrationSummary: summary,
    blockedClaims: androidBlockedClaims(),
  });
  atomicWriteReportJson(buildRoot, reportRefs.android, receipt);
  return { platform: "android", ok: true, report: `build/${reportRefs.android}` };
}

function iosArtifactFactsWithin(containmentRoot, appPath, {
  allowExternalHardlinks = false,
} = {}) {
  const safeApp = resolveContainedExistingPath(
    containmentRoot,
    appPath,
    { expectedKind: "directory" },
  );
  const infoPlist = path.join(safeApp, "Info.plist");
  const executable = path.join(safeApp, "Runner");
  requireValue(existsSync(infoPlist) && existsSync(executable), "ios_simulator_bundle_invalid");
  const identifier = command("plutil", ["-extract", "CFBundleIdentifier", "raw", "-o", "-",
    infoPlist], { timeoutMs: 10_000 });
  requireValue(commandReady(identifier) && String(identifier.stdout || "").trim() ===
    iosBundleIdentifier, "ios_simulator_bundle_identifier_invalid");
  const architectures = command("lipo", ["-archs", executable], { timeoutMs: 10_000 });
  requireValue(commandReady(architectures) && /(?:^|\s)arm64(?:\s|$)/u.test(
    String(architectures.stdout || "")), "ios_simulator_architecture_invalid");
  const snapshot = artifactTreeSnapshot(safeApp, { allowExternalHardlinks });
  return {
    app: safeApp,
    snapshot,
    digest: snapshot.digest,
    installIdentityDigest: iosInstallIdentityDigest(snapshot),
    contentDigest: artifactTreeContentDigest(safeApp, { allowExternalHardlinks }),
    executableDigest: sha256File(executable),
  };
}

function iosArtifactFacts(appPath) {
  return iosArtifactFactsWithin(
    path.join(flutterRoot, "build", "ios", "iphonesimulator"),
    appPath,
  );
}

function iosInstallIdentityDigest(snapshot) {
  const records = snapshot.entries.map((entry) => ({
    kind: entry.kind,
    path: entry.path,
    mode: entry.mode,
    depth: entry.depth,
    childCount: entry.kind === "directory" ? entry.childCount : undefined,
    size: entry.kind === "file" ? entry.size : undefined,
    digest: entry.kind === "file" ? entry.digest : undefined,
    target: entry.kind === "symlink" ? entry.target : undefined,
  }));
  return `sha256:${createHash("sha256").update(JSON.stringify(records)).digest("hex")}`;
}

function iosInstalledArtifactFacts(appPath) {
  const executable = path.join(appPath, "Runner");
  requireValue(existsSync(executable), "ios_installed_simulator_bundle_invalid");
  const snapshot = artifactTreeSnapshot(appPath, {
    allowExternalHardlinks: true,
  });
  return {
    app: appPath,
    snapshot,
    digest: snapshot.digest,
    installIdentityDigest: iosInstallIdentityDigest(snapshot),
    contentDigest: artifactTreeContentDigest(appPath, {
      allowExternalHardlinks: true,
    }),
    executableDigest: sha256File(executable),
  };
}

function iosArtifactSnapshotMatches(expected, actual) {
  return expected?.digest === actual?.digest &&
    expected?.installIdentityDigest === actual?.installIdentityDigest &&
    expected?.contentDigest === actual?.contentDigest &&
    expected?.executableDigest === actual?.executableDigest;
}

function iosInstallManifestMatches(stagedEntries, installedEntries, machOReady) {
  if (!Array.isArray(stagedEntries) || !Array.isArray(installedEntries) ||
    stagedEntries.length !== installedEntries.length) return false;
  const installedByPath = new Map(installedEntries.map((entry) => [entry.path, entry]));
  if (installedByPath.size !== installedEntries.length) return false;
  for (const staged of stagedEntries) {
    const installed = installedByPath.get(staged.path);
    if (!installed || staged.kind !== installed.kind || staged.depth !== installed.depth ||
      staged.childCount !== installed.childCount || staged.size !== installed.size ||
      staged.digest !== installed.digest || staged.target !== installed.target) return false;
    if (staged.mode === installed.mode) continue;
    if (staged.path === "Runner" || staged.kind !== "file" || installed.kind !== "file" ||
      staged.mode !== "0755" || installed.mode !== "0644" ||
      !iosCoreSimulatorMachOModeNormalizationPaths.has(staged.path) ||
      machOReady(staged.path) !== true) return false;
  }
  return true;
}

function iosEmbeddedMachOReady(staged, installed, relativePath) {
  for (const artifact of [staged, installed]) {
    const inspected = command("lipo", ["-archs", path.join(artifact.app, relativePath)], {
      timeoutMs: 10_000,
    });
    if (!commandReady(inspected) || !String(inspected.stdout || "").trim()) return false;
  }
  return true;
}

function iosCoreSimulatorInstalledArtifactMatchesStaged(installed, staged, {
  machOReady = (relativePath) => iosEmbeddedMachOReady(staged, installed, relativePath),
} = {}) {
  return iosArtifactContentMatches(staged, installed) &&
    iosInstallManifestMatches(staged?.snapshot?.entries, installed?.snapshot?.entries, machOReady);
}

function iosArtifactContentMatches(expected, actual) {
  return expected?.contentDigest === actual?.contentDigest &&
    expected?.executableDigest === actual?.executableDigest;
}

function visitIosStagingTree(entryPath, visitor) {
  const info = lstatSync(entryPath, { bigint: true });
  if (info.isDirectory() && !info.isSymbolicLink()) {
    for (const name of readdirSync(entryPath).sort()) {
      visitIosStagingTree(path.join(entryPath, name), visitor);
    }
  }
  visitor(entryPath, info);
}

function makeIosStagingTreeOwnerWritable(entryPath) {
  if (!existsSync(entryPath)) return;
  const info = lstatSync(entryPath, { bigint: true });
  if (info.isSymbolicLink()) return;
  if (info.isDirectory()) {
    chmodSync(entryPath, Number(info.mode & 0o777n) | 0o700);
    for (const name of readdirSync(entryPath).sort()) {
      makeIosStagingTreeOwnerWritable(path.join(entryPath, name));
    }
    return;
  }
  chmodSync(entryPath, Number(info.mode & 0o777n) | 0o200);
}

function makeIosStagingTreeInstallCompatible(entryPath) {
  visitIosStagingTree(entryPath, (current, info) => {
    if (info.isSymbolicLink()) return;
    requireValue(info.isDirectory() || info.isFile(),
      "ios_staging_unsupported_filesystem_entry");
    chmodSync(current, normalizedIosStagingMode(info));
  });
}

function normalizedIosStagingMode(info) {
  if (info.isDirectory()) return 0o755;
  requireValue(info.isFile(), "ios_staging_unsupported_filesystem_entry");
  return Number(info.mode & 0o111n) === 0 ? 0o644 : 0o755;
}

function iosStagedArtifactFacts(stageRoot, appPath) {
  return iosArtifactFactsWithin(stageRoot, appPath);
}

function existingLstat(entryPath) {
  try {
    return lstatSync(entryPath, { bigint: true });
  } catch (error) {
    if (error?.code === "ENOENT") return undefined;
    throw error;
  }
}

function requireLexicallyContained(root, candidate, category) {
  const relative = path.relative(root, candidate);
  requireValue(relative !== "" && relative !== ".." &&
    !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative), category);
}

function requireExistingDirectoryChain(boundaryRoot, target, category) {
  const boundaryInfo = existingLstat(boundaryRoot);
  requireValue(boundaryInfo?.isDirectory() === true &&
    boundaryInfo.isSymbolicLink() === false, category);
  const relative = path.relative(boundaryRoot, target);
  requireValue(relative === "" || (relative !== ".." &&
    !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative)), category);
  let current = boundaryRoot;
  for (const segment of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, segment);
    const info = existingLstat(current);
    requireValue(info?.isDirectory() === true && info.isSymbolicLink() === false, category);
  }
}

function ensureControlledIosStagingDirectory(generatedParent, target) {
  requireLexicallyContained(generatedParent, target,
    "ios_staging_parent_outside_generated_root");
  const relative = path.relative(generatedParent, target);
  let current = generatedParent;
  for (const segment of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, segment);
    const existing = existingLstat(current);
    if (existing === undefined) mkdirSync(current, { mode: 0o755 });
    const info = existingLstat(current);
    requireValue(info?.isDirectory() === true && info.isSymbolicLink() === false,
      "ios_staging_parent_unsafe");
    chmodSync(current, 0o755);
  }
}

function prepareIosStagingDirectories(boundaryRoot, generatedParent) {
  requireExistingDirectoryChain(boundaryRoot, generatedParent,
    "ios_staging_generated_parent_unsafe");
  const iosRoot = path.join(generatedParent, "ios");
  const stageParent = path.join(iosRoot, "mobile-simulator-closure-staging");
  const stageRoot = path.join(stageParent, "release");
  ensureControlledIosStagingDirectory(generatedParent, stageParent);
  const previousStage = existingLstat(stageRoot);
  if (previousStage !== undefined) {
    requireValue(previousStage.isDirectory() && !previousStage.isSymbolicLink(),
      "ios_staging_root_unsafe");
    makeIosStagingTreeOwnerWritable(stageRoot);
    rmSync(stageRoot, { recursive: true, force: true });
  }
  ensureControlledIosStagingDirectory(generatedParent, stageRoot);
  return { iosRoot, stageParent, stageRoot };
}

function stageStableIosReleaseArtifact(artifact) {
  const generatedParent = path.join(buildRoot, "apps", "desktop");
  const { stageRoot } = prepareIosStagingDirectories(buildRoot, generatedParent);
  const stagedApp = path.join(stageRoot, "Runner.app");
  const sourceBeforeCopy = iosArtifactFacts(artifact.app);
  cpSync(artifact.app, stagedApp, {
    recursive: true,
    dereference: false,
    errorOnExist: true,
    force: false,
    preserveTimestamps: true,
    verbatimSymlinks: true,
  });
  const sourceAfterCopy = iosArtifactFacts(artifact.app);
  requireValue(iosArtifactSnapshotMatches(sourceBeforeCopy, sourceAfterCopy),
    "ios_release_artifact_changed_during_staging");
  const stagedBeforeNormalization = iosStagedArtifactFacts(stageRoot, stagedApp);
  requireValue(iosArtifactContentMatches(artifact, stagedBeforeNormalization),
    "ios_staged_release_artifact_content_mismatch");
  makeIosStagingTreeInstallCompatible(stageRoot);
  const staged = iosStagedArtifactFacts(stageRoot, stagedApp);
  requireValue(iosArtifactContentMatches(artifact, staged),
    "ios_staged_release_artifact_normalization_mismatch");
  return { ...staged, stageRoot };
}

function requireStableIosStaging(staged, category) {
  const actual = iosStagedArtifactFacts(staged.stageRoot, staged.app);
  requireValue(iosArtifactSnapshotMatches(staged, actual), category);
  return actual;
}

function buildIosSimulatorArtifact() {
  const built = command("flutter", [
    "build",
    "ios",
    "--simulator",
    "--debug",
    "--no-pub",
  ], {
    cwd: flutterRoot,
    env: withClientToolchainEnv(),
    timeoutMs: 10 * 60 * 1000,
    maxBuffer: maxFlutterOutputBytes,
  });
  requireValue(commandReady(built), "ios_simulator_prelaunch_build_failed");
  return runClosureStage("ios_simulator_prelaunch_artifact_inspection_failed", () =>
    iosArtifactFacts(path.join(
      flutterRoot, "build", "ios", "iphonesimulator", "Runner.app",
    )));
}

function installIosArtifact(device, appPath, category) {
  const installed = command("xcrun", ["simctl", "install", device, appPath], {
    timeoutMs: 120_000,
  });
  requireValue(commandReady(installed), category);
  return runClosureStage("ios_installed_artifact_inspection_failed", () =>
    iosInstalledArtifactFacts(installedIosAppPath(device)));
}

function installedIosAppPath(device) {
  const result = command("xcrun", ["simctl", "get_app_container", device,
    iosBundleIdentifier, "app"], { timeoutMs: 20_000 });
  requireValue(commandReady(result), "ios_installed_artifact_missing");
  const appPath = String(result.stdout || "").trim();
  requireValue(appPath && path.isAbsolute(appPath), "ios_installed_artifact_path_invalid");
  return appPath;
}

function installedIosDataPath(device) {
  const result = command("xcrun", ["simctl", "get_app_container", device,
    iosBundleIdentifier, "data"], { timeoutMs: 20_000 });
  requireValue(commandReady(result), "ios_installed_data_container_missing");
  const dataPath = String(result.stdout || "").trim();
  requireValue(dataPath && path.isAbsolute(dataPath), "ios_data_container_path_invalid");
  return dataPath;
}

function removeExistingIosInstallation(device) {
  const installed = command("xcrun", [
    "simctl",
    "get_app_container",
    device,
    iosBundleIdentifier,
    "app",
  ], { timeoutMs: 20_000 });
  if (!commandReady(installed)) return;
  const uninstalled = command("xcrun", [
    "simctl",
    "uninstall",
    device,
    iosBundleIdentifier,
  ], { timeoutMs: 60_000 });
  requireValue(commandReady(uninstalled), "ios_simulator_pretest_uninstall_failed");
}

function iosRuntimeStatusReady(status, launchedAtEpochMillis) {
  const nativeRuntime = status?.nativeRuntime || {};
  const bridge = status?.bridge || {};
  const runtimeStatusFile = status?.runtimeStatusFile || {};
  return status?.platform === "ios" && status.ok === true &&
    status.statusKind === "launch-runtime" &&
    status.credentialStoreEvaluated === false &&
    status.localAuthenticationEvaluated === false &&
    runtimeStatusFile.writtenByAppProcess === true &&
    Number(runtimeStatusFile.writtenAtEpochMillis || 0) >= launchedAtEpochMillis - 5_000 &&
    nativeRuntime.ffiBoundary === "c-abi" && nativeRuntime.loaded === true &&
    nativeRuntime.selfTestPassed === true && nativeRuntime.usesSharedRustCore === true &&
    bridge.statusMethod === true && bridge.writeRuntimeStatusMethod === true &&
    bridge.nativeJsonMethod === true;
}

async function waitForIosRuntimeStatus(device, launchedAtEpochMillis) {
  const deadline = Date.now() + 30_000;
  while (Date.now() <= deadline) {
    try {
      const dataRoot = installedIosDataPath(device);
      const runtimePath = path.join(
        dataRoot,
        "Library",
        "Application Support",
        "LicoArc",
        "secure-mesh",
        "ios-runtime-status.json",
      );
      const safeRuntime = resolveContainedExistingPath(dataRoot, runtimePath, {
        expectedKind: "file",
      });
      const status = JSON.parse(stableReadFile(safeRuntime, {
        maxBytes: 2 * 1024 * 1024,
      }).toString("utf8"));
      if (iosRuntimeStatusReady(status, launchedAtEpochMillis)) {
        return true;
      }
    } catch {
      // The fresh app container may not exist until launch initialization completes.
    }
    await sleep(750);
  }
  return false;
}

function iosLaunchPid(output) {
  const match = String(output || "").match(/:\s*([1-9][0-9]*)\s*$/u);
  return match ? Number(match[1]) : 0;
}

function iosProcessAlive(device, pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  const result = command("xcrun", [
    "simctl",
    "spawn",
    device,
    "/bin/kill",
    "-0",
    String(pid),
  ], { timeoutMs: 10_000 });
  return commandReady(result);
}

async function verifyIos() {
  removeContainedReportIfExists(buildRoot, reportRefs.ios);
  const { device } = selectIosSimulator();
  removeExistingIosInstallation(device);
  const sourceBefore = clientSourceStateDigest(repoRoot, CANONICAL_CLIENT_SOURCE_ROOTS);
  // The release simulator bundle is snapshot-bound before the functional harness runs.
  // Flutter's integration runner may rebuild its own same-source app in the
  // ordinary build directory, so it is never represented as the exact staged
  // release artifact.
  const artifact = buildIosSimulatorArtifact();
  const staged = runClosureStage("ios_release_artifact_staging_failed", () =>
    stageStableIosReleaseArtifact(artifact));
  requireStableIosStaging(staged, "ios_release_staging_initial_snapshot_mutated");
  const authenticator = configureIosSimulatedBiometric(device);
  let summary;
  let integrationFailure;
  try {
    summary = await runFlutterIntegration("ios", device, authenticator);
  } catch (error) {
    integrationFailure = error;
  } finally {
    if (authenticator.cleanup() !== true) {
      throw new ClosureError("ios_simulated_biometric_cleanup_failed");
    }
  }
  if (integrationFailure) throw integrationFailure;
  requireValue(clientSourceStateDigest(repoRoot, CANONICAL_CLIENT_SOURCE_ROOTS) === sourceBefore,
    "ios_source_changed_during_build");
  requireStableIosStaging(staged, "ios_release_staging_mutated_by_functional_harness");
  command("xcrun", ["simctl", "terminate", device, iosBundleIdentifier], {
    timeoutMs: 20_000,
  });
  const uninstalled = command("xcrun", ["simctl", "uninstall", device,
    iosBundleIdentifier], { timeoutMs: 60_000 });
  requireValue(commandReady(uninstalled), "ios_simulator_uninstall_failed");
  requireStableIosStaging(staged, "ios_release_staging_mutated_before_install");
  const installedBeforeLaunch = installIosArtifact(
    device,
    staged.app,
    "ios_simulator_install_failed",
  );
  requireValue(iosArtifactContentMatches(staged, installedBeforeLaunch),
    "ios_installed_release_artifact_content_mismatch");
  requireValue(iosCoreSimulatorInstalledArtifactMatchesStaged(installedBeforeLaunch, staged),
    "ios_installed_release_artifact_identity_mismatch");
  requireStableIosStaging(staged, "ios_release_staging_mutated_during_install");
  const launchedAtEpochMillis = Date.now();
  const launched = command("xcrun", ["simctl", "launch", "--terminate-running-process",
    device, iosBundleIdentifier], { timeoutMs: 60_000 });
  const launchedPid = iosLaunchPid(`${launched.stdout || ""}\n${launched.stderr || ""}`);
  requireValue(commandReady(launched) && launchedPid > 0, "ios_simulator_launch_failed");
  requireValue(await waitForIosRuntimeStatus(device, launchedAtEpochMillis),
    "ios_simulator_native_runtime_status_failed");
  await sleep(1_500);
  requireValue(iosProcessAlive(device, launchedPid), "ios_simulator_process_not_alive");
  requireStableIosStaging(staged, "ios_release_staging_mutated_during_launch");
  const installedAfterLaunch = runClosureStage(
    "ios_release_artifact_post_launch_inspection_failed",
    () => iosInstalledArtifactFacts(installedIosAppPath(device)),
  );
  requireValue(iosArtifactSnapshotMatches(
    installedBeforeLaunch,
    installedAfterLaunch,
  ), "ios_installed_release_artifact_mutated_during_launch");
  requireValue(iosArtifactContentMatches(staged, installedAfterLaunch),
    "ios_launched_release_artifact_content_mismatch");
  requireValue(iosCoreSimulatorInstalledArtifactMatchesStaged(installedAfterLaunch, staged),
    "ios_launched_release_artifact_identity_mismatch");
  requireValue(clientSourceStateDigest(repoRoot, CANONICAL_CLIENT_SOURCE_ROOTS) === sourceBefore,
    "ios_source_changed_during_install_launch");
  requireStableIosStaging(staged, "ios_release_staging_mutated_before_receipt");

  const receipt = buildReceipt({
    platform: "ios",
    targetId: "ios-simulator-arm64",
    sourceStateDigest: sourceBefore,
    artifactKind: "ios-simulator-app",
    artifactDigest: staged.digest,
    runtimeExecutableDigest: staged.executableDigest,
    integrationSummary: summary,
    blockedClaims: iosBlockedClaims(),
    functionalHarnessExactArtifact: false,
  });
  runClosureStage("ios_simulator_receipt_write_failed", () =>
    atomicWriteReportJson(buildRoot, reportRefs.ios, receipt));
  return { platform: "ios", ok: true, report: `build/${reportRefs.ios}` };
}

function androidArtifactStageRejected(action) {
  try {
    action();
    return false;
  } catch (error) {
    return error instanceof ClosureError &&
      error.category === "android_simulator_artifact_stage_failed";
  }
}

function runAndroidArtifactStageSelfTests() {
  const root = mkdtempSync(path.join(os.tmpdir(), "lico-android-stage-self-test-"));
  const outside = mkdtempSync(path.join(os.tmpdir(), "lico-android-stage-outside-"));
  const targetRef = "generated/android/app-debug.apk";
  const target = path.join(root, ...targetRef.split("/"));
  const sourceA = path.join(root, "source-a.apk");
  const sourceB = path.join(root, "source-b.apk");
  const outsideFile = path.join(outside, "outside.apk");
  try {
    writeFileSync(sourceA, "android-stage-source-a", { mode: 0o600 });
    writeFileSync(sourceB, "android-stage-source-b", { mode: 0o600 });
    writeFileSync(outsideFile, "outside-sentinel", { mode: 0o600 });

    stageAndroidSimulatorArtifact(sourceA, { allowedRoot: root, targetRef });
    stageAndroidSimulatorArtifact(sourceB, { allowedRoot: root, targetRef });
    requireValue(sha256File(target) === sha256File(sourceB),
      "android artifact repeated replacement self-test failed");

    const hardlink = path.join(root, "staged-hardlink.apk");
    linkSync(target, hardlink);
    requireValue(androidArtifactStageRejected(() =>
      stageAndroidSimulatorArtifact(sourceA, { allowedRoot: root, targetRef })),
    "android artifact hardlink rejection self-test failed");
    rmSync(hardlink, { force: true });

    const displaced = path.join(root, "displaced.apk");
    requireValue(androidArtifactStageRejected(() =>
      stageAndroidSimulatorArtifact(sourceA, {
        allowedRoot: root,
        targetRef,
        beforePublish({ target: publicationTarget }) {
          renameSync(publicationTarget, displaced);
          writeFileSync(publicationTarget, "racing-target", { mode: 0o600 });
        },
      })), "android artifact race rejection self-test failed");

    requireValue(androidArtifactStageRejected(() =>
      stageAndroidSimulatorArtifact(sourceA, {
        allowedRoot: root,
        targetRef: "../escaped.apk",
      })), "android artifact traversal rejection self-test failed");

    let symlinkRejected = true;
    let symlinkParentRejected = true;
    if (process.platform !== "win32") {
      rmSync(path.dirname(target), { recursive: true, force: true });
      mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
      symlinkSync(outsideFile, target);
      symlinkRejected = androidArtifactStageRejected(() =>
        stageAndroidSimulatorArtifact(sourceA, { allowedRoot: root, targetRef }));

      const linkedParent = path.join(root, "linked-parent");
      symlinkSync(outside, linkedParent);
      symlinkParentRejected = androidArtifactStageRejected(() =>
        stageAndroidSimulatorArtifact(sourceA, {
          allowedRoot: root,
          targetRef: "linked-parent/app-debug.apk",
        }));
    }
    requireValue(symlinkRejected,
      "android artifact symlink rejection self-test failed");
    requireValue(symlinkParentRejected,
      "android artifact symlink parent rejection self-test failed");

    const generatedParent = path.join(root, "generated", "android");
    const temporaryAbsent = !existsSync(generatedParent) ||
      readdirSync(generatedParent).every((name) => !name.endsWith(".tmp"));
    requireValue(temporaryAbsent,
      "android artifact temporary cleanup self-test failed");
    return {
      repeatedReplacementReady: true,
      hardlinkRejected: true,
      raceRejected: true,
      traversalRejected: true,
      symlinkRejected: true,
      symlinkParentRejected: true,
      temporaryCleanupReady: true,
    };
  } finally {
    rmSync(root, { recursive: true, force: true });
    rmSync(outside, { recursive: true, force: true });
  }
}

function runSelfTest() {
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

async function main() {
  const options = parseArgs();
  if (options.selfTest) {
    console.log(JSON.stringify(runSelfTest()));
    return;
  }
  prepareFlutterDependencies();
  const results = [];
  for (const platform of selectedPlatforms(options.platform)) {
    results.push(platform === "android" ? await verifyAndroid() : await verifyIos());
  }
  console.log(JSON.stringify({
    ok: results.every((result) => result.ok === true),
    results,
    physicalDeviceClaimsReady: false,
    productionReleaseReady: false,
    privatePathsIncluded: false,
    deviceIdentifiersIncluded: false,
  }));
}

try {
  await main();
} catch (error) {
  const category = error instanceof ClosureError
    ? error.category
    : "mobile_simulator_closure_failed";
  console.error(JSON.stringify({
    ok: false,
    reason: category,
    physicalDeviceClaimsReady: false,
    productionReleaseReady: false,
    privatePathsIncluded: false,
    deviceIdentifiersIncluded: false,
  }));
  process.exitCode = 1;
}
