import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { androidRawJsonSecretOverridesSourceProof } from "../lib/android-mobile-relay-secret-override-source-proof.mjs";
import { assertAndroidApkFactsEqual } from "../lib/android-apk-facts.mjs";
import { stableHashFileSnapshot } from "../lib/client-release-artifact-digest.mjs";
import {
  releaseClosureChallengeDigest,
  releaseInvocationNonceDigest,
  requiredReleaseClosureChallenge,
  requiredReleaseClosureStartedAt,
  requiredReleaseInvocationNonce,
} from "../lib/release-closure-challenge.mjs";
import {
  atomicWriteReportJson,
  removeContainedReportIfExists,
} from "../lib/safe-report-io.mjs";
import { inspectApk, physicalReleaseApkReady } from "./apk/inspect.mjs";
import { parseArgs } from "./cli.mjs";
import { repoRoot, reportPath } from "./constants.mjs";
import { pickAdb } from "./device/adb.mjs";
import { pickDevice } from "./device/select.mjs";
import {
  installApk,
  inspectInstalledApk,
  isPackageInstalled,
} from "./operations/install.mjs";
import { launchApp, resolveLaunchComponent } from "./operations/launch.mjs";
import { assertNoLeak } from "./privacy/leak-scan.mjs";
import { writeBlockedReportIfPossible } from "./report/blocked.mjs";
import { buildInstallLaunchReport } from "./report/build.mjs";
import {
  readRuntimeStatus,
  removeRuntimeStatusFiles,
  validateRuntimeStatus,
  waitForRuntimeStatus,
} from "./runtime/status.mjs";
import { parseJson } from "./util/json.mjs";
import { clientProductVersion } from "./version.mjs";
import { runSelfTest } from "./self-test.mjs";

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
    const rawJsonSecretOverridesStaticSourceProof =
      androidRawJsonSecretOverridesSourceProof(repoRoot);

    const report = buildInstallLaunchReport({
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
    });
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

export async function run() {
  try {
    if (process.argv.slice(2).includes("--self-test")) {
      console.log(JSON.stringify(runSelfTest()));
      return;
    }
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
      jniSecretCallbackInProcessReady:
        report.summary.jniSecretCallbackInProcessReady,
      statusProbeSideEffectFree:
        report.summary.statusProbeSideEffectFree,
      freshOneShotAuthorizationPolicyReady:
        report.summary.freshOneShotAuthorizationPolicyReady,
      sourceBuildBound: report.summary.sourceBuildBound,
      apkSignatureReady: report.summary.apkSignatureReady,
      evidenceBindingReady: report.summary.evidenceBindingReady
    }, null, 2));
    if (!report.ok) {
      process.exitCode = 1;
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
      return;
    }
    throw error;
  }
}
