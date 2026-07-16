import { existsSync, linkSync, mkdtempSync, mkdirSync, readdirSync, renameSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { sha256File } from "../../lib/client-release-artifact-digest.mjs";
import { ANDROID_APK_RESOURCE_LIMITS } from "../../lib/android-apk-facts.mjs";
import { atomicReplaceContainedFileSnapshot } from "../../lib/safe-report-io.mjs";
import { androidSimulatorArtifactRef, buildRoot, flutterRoot, packageName, sentinel } from "../constants.mjs";
import { ClosureError, requireValue, runClosureStage } from "../errors.mjs";
import { command, commandReady } from "../process.mjs";

export function newestAndroidDebugApk() {
  const candidates = [
    path.join(flutterRoot, "build", "app", "outputs", "flutter-apk", "app-debug.apk"),
    path.join(flutterRoot, "build", "app", "outputs", "apk", "debug", "app-debug.apk"),
  ].filter(existsSync);
  requireValue(candidates.length > 0, "android_simulator_artifact_missing");
  return candidates.sort((left, right) => statSync(right).mtimeMs - statSync(left).mtimeMs)[0];
}

export function stageAndroidSimulatorArtifact(apk, {
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

export function inspectInstalledAndroidApk(adb, device, workRoot) {
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

export function parseAndroidLaunch(output, expectedComponent) {
  const text = String(output || "");
  const statusReady = /(?:^|\n)Status:\s*ok(?:\r?\n|$)/iu.test(text);
  const activity = text.match(/(?:^|\n)Activity:\s*([^\s]+)/iu)?.[1] || "";
  const [activityPackage, activityClass = ""] = activity.split("/", 2);
  const normalized = activityClass.startsWith(".")
    ? `${activityPackage}/${activityPackage}${activityClass}`
    : activity;
  return statusReady && normalized === expectedComponent;
}

export function androidRuntimeStatusReady(
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

export async function waitForAndroidRuntimeStatus(
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

export function androidProcessAlive(adb, device) {
  const result = command(adb, ["-s", device, "shell", "pidof", packageName], {
    timeoutMs: 5_000,
  });
  return commandReady(result) && String(result.stdout || "").trim()
    .split(/\s+/u)
    .some((value) => /^[1-9][0-9]*$/u.test(value));
}

export function androidBlockedClaims() {
  return [
    "physical_android_keystore_custody",
    "hardware_backed_key_attestation",
    "real_biometric_user_presence",
    "physical_cross_device_encryption",
    "production_signing_and_store_distribution",
  ];
}

export function androidArtifactStageRejected(action) {
  try {
    action();
    return false;
  } catch (error) {
    return error instanceof ClosureError &&
      error.category === "android_simulator_artifact_stage_failed";
  }
}

export function runAndroidArtifactStageSelfTests() {
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
