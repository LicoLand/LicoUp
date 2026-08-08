import process from "node:process";
import { CANONICAL_CLIENT_SOURCE_ROOTS, clientSourceStateDigest } from "../../lib/client-source-state-digest.mjs";
import { atomicWriteReportJson, removeContainedReportIfExists } from "../../lib/safe-report-io.mjs";
import { buildRoot, iosBundleIdentifier, repoRoot, reportRefs } from "../constants.mjs";
import { ClosureError, requireValue, runClosureStage } from "../errors.mjs";
import { runFlutterIntegration } from "../flutter.mjs";
import { buildIosSimulatorArtifact, installIosArtifact, installedIosAppPath, iosArtifactContentMatches, iosArtifactSnapshotMatches, iosBlockedClaims, iosCoreSimulatorInstalledArtifactMatchesStaged, iosInstalledArtifactFacts, iosLaunchPid, iosProcessAlive, removeExistingIosInstallation, requireStableIosStaging, stageStableIosReleaseArtifact, waitForIosRuntimeStatus } from "./artifacts.mjs";
import { configureIosSimulatedBiometric, selectIosSimulator } from "./device.mjs";
import { command, commandReady, sleep } from "../process.mjs";
import { buildReceipt } from "../receipt.mjs";

export async function verifyIos() {
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
