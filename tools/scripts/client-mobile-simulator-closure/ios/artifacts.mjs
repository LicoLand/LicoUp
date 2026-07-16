import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, cpSync, existsSync, lstatSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import path from "node:path";
import { withClientToolchainEnv } from "../../client-toolchain-env.mjs";
import { artifactTreeContentDigest, artifactTreeSnapshot, resolveContainedExistingPath, sha256File, stableReadFile } from "../../lib/client-release-artifact-digest.mjs";
import { buildRoot, flutterRoot, iosBundleIdentifier, iosCoreSimulatorMachOModeNormalizationPaths, maxFlutterOutputBytes } from "../constants.mjs";
import { requireValue, runClosureStage } from "../errors.mjs";
import { command, commandReady, sleep } from "../process.mjs";

export function iosBlockedClaims() {
  return [
    "physical_ios_keychain_custody",
    "secure_enclave_key_protection",
    "real_biometric_user_presence",
    "physical_cross_device_encryption",
    "production_signing_and_store_distribution",
  ];
}

export function iosArtifactFactsWithin(containmentRoot, appPath, {
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

export function iosArtifactFacts(appPath) {
  return iosArtifactFactsWithin(
    path.join(flutterRoot, "build", "ios", "iphonesimulator"),
    appPath,
  );
}

export function iosInstallIdentityDigest(snapshot) {
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

export function iosInstalledArtifactFacts(appPath) {
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

export function iosArtifactSnapshotMatches(expected, actual) {
  return expected?.digest === actual?.digest &&
    expected?.installIdentityDigest === actual?.installIdentityDigest &&
    expected?.contentDigest === actual?.contentDigest &&
    expected?.executableDigest === actual?.executableDigest;
}

export function iosInstallManifestMatches(stagedEntries, installedEntries, machOReady) {
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

export function iosEmbeddedMachOReady(staged, installed, relativePath) {
  for (const artifact of [staged, installed]) {
    const inspected = command("lipo", ["-archs", path.join(artifact.app, relativePath)], {
      timeoutMs: 10_000,
    });
    if (!commandReady(inspected) || !String(inspected.stdout || "").trim()) return false;
  }
  return true;
}

export function iosCoreSimulatorInstalledArtifactMatchesStaged(installed, staged, {
  machOReady = (relativePath) => iosEmbeddedMachOReady(staged, installed, relativePath),
} = {}) {
  return iosArtifactContentMatches(staged, installed) &&
    iosInstallManifestMatches(staged?.snapshot?.entries, installed?.snapshot?.entries, machOReady);
}

export function iosArtifactContentMatches(expected, actual) {
  return expected?.contentDigest === actual?.contentDigest &&
    expected?.executableDigest === actual?.executableDigest;
}

export function visitIosStagingTree(entryPath, visitor) {
  const info = lstatSync(entryPath, { bigint: true });
  if (info.isDirectory() && !info.isSymbolicLink()) {
    for (const name of readdirSync(entryPath).sort()) {
      visitIosStagingTree(path.join(entryPath, name), visitor);
    }
  }
  visitor(entryPath, info);
}

export function makeIosStagingTreeOwnerWritable(entryPath) {
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

export function makeIosStagingTreeInstallCompatible(entryPath) {
  visitIosStagingTree(entryPath, (current, info) => {
    if (info.isSymbolicLink()) return;
    requireValue(info.isDirectory() || info.isFile(),
      "ios_staging_unsupported_filesystem_entry");
    chmodSync(current, normalizedIosStagingMode(info));
  });
}

export function normalizedIosStagingMode(info) {
  if (info.isDirectory()) return 0o755;
  requireValue(info.isFile(), "ios_staging_unsupported_filesystem_entry");
  return Number(info.mode & 0o111n) === 0 ? 0o644 : 0o755;
}

export function iosStagedArtifactFacts(stageRoot, appPath) {
  return iosArtifactFactsWithin(stageRoot, appPath);
}

export function existingLstat(entryPath) {
  try {
    return lstatSync(entryPath, { bigint: true });
  } catch (error) {
    if (error?.code === "ENOENT") return undefined;
    throw error;
  }
}

export function requireLexicallyContained(root, candidate, category) {
  const relative = path.relative(root, candidate);
  requireValue(relative !== "" && relative !== ".." &&
    !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative), category);
}

export function requireExistingDirectoryChain(boundaryRoot, target, category) {
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

export function ensureControlledIosStagingDirectory(generatedParent, target) {
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

export function prepareIosStagingDirectories(boundaryRoot, generatedParent) {
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

export function stageStableIosReleaseArtifact(artifact) {
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

export function requireStableIosStaging(staged, category) {
  const actual = iosStagedArtifactFacts(staged.stageRoot, staged.app);
  requireValue(iosArtifactSnapshotMatches(staged, actual), category);
  return actual;
}

export function buildIosSimulatorArtifact() {
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

export function installIosArtifact(device, appPath, category) {
  const installed = command("xcrun", ["simctl", "install", device, appPath], {
    timeoutMs: 120_000,
  });
  requireValue(commandReady(installed), category);
  return runClosureStage("ios_installed_artifact_inspection_failed", () =>
    iosInstalledArtifactFacts(installedIosAppPath(device)));
}

export function installedIosAppPath(device) {
  const result = command("xcrun", ["simctl", "get_app_container", device,
    iosBundleIdentifier, "app"], { timeoutMs: 20_000 });
  requireValue(commandReady(result), "ios_installed_artifact_missing");
  const appPath = String(result.stdout || "").trim();
  requireValue(appPath && path.isAbsolute(appPath), "ios_installed_artifact_path_invalid");
  return appPath;
}

export function installedIosDataPath(device) {
  const result = command("xcrun", ["simctl", "get_app_container", device,
    iosBundleIdentifier, "data"], { timeoutMs: 20_000 });
  requireValue(commandReady(result), "ios_installed_data_container_missing");
  const dataPath = String(result.stdout || "").trim();
  requireValue(dataPath && path.isAbsolute(dataPath), "ios_data_container_path_invalid");
  return dataPath;
}

export function removeExistingIosInstallation(device) {
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

export function iosRuntimeStatusReady(status, launchedAtEpochMillis) {
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

export async function waitForIosRuntimeStatus(device, launchedAtEpochMillis) {
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

export function iosLaunchPid(output) {
  const match = String(output || "").match(/:\s*([1-9][0-9]*)\s*$/u);
  return match ? Number(match[1]) : 0;
}

export function iosProcessAlive(device, pid) {
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
