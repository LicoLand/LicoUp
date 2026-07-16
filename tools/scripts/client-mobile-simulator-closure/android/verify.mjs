import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { seedClientGradleHome, withClientToolchainEnv } from "../../client-toolchain-env.mjs";
import { sha256File } from "../../lib/client-release-artifact-digest.mjs";
import { CANONICAL_CLIENT_SOURCE_ROOTS, clientSourceStateDigest } from "../../lib/client-source-state-digest.mjs";
import { ANDROID_APK_RESOURCE_LIMITS, inspectAndroidApkFacts } from "../../lib/android-apk-facts.mjs";
import { androidReleaseAcceptanceAuthorizationBroadcastArgs, androidReleaseAcceptanceBroadcastAccepted } from "../../lib/android-release-acceptance-binding.mjs";
import { createReleaseClosureChallenge, createReleaseInvocationNonce, releaseClosureChallengeDigest, releaseInvocationNonceDigest } from "../../lib/release-closure-challenge.mjs";
import { atomicWriteReportJson, removeContainedReportIfExists } from "../../lib/safe-report-io.mjs";
import { androidBlockedClaims, androidProcessAlive, inspectInstalledAndroidApk, newestAndroidDebugApk, parseAndroidLaunch, stageAndroidSimulatorArtifact, waitForAndroidRuntimeStatus } from "./artifacts.mjs";
import { configureAndroidSimulatedCredential, selectAndroidSimulator } from "./device.mjs";
import { buildRoot, packageName, repoRoot, reportRefs } from "../constants.mjs";
import { ClosureError, requireValue, runClosureStage } from "../errors.mjs";
import { runFlutterIntegration } from "../flutter.mjs";
import { command, commandReady, sleep } from "../process.mjs";
import { buildReceipt } from "../receipt.mjs";

export async function verifyAndroid() {
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
