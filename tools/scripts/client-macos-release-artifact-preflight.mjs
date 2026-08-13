#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  sha256File,
  stableReadFile,
} from "./lib/client-release-artifact-digest.mjs";
import { replaceInstalledAppWithRollback } from "./lib/macos-app-install.mjs";
import { inspectBoundedMacosCodePolicy } from "./lib/macos-code-signature.mjs";
import { normalizedMacosReleaseSignerFingerprint } from "./lib/macos-release-identity.mjs";
import { atomicWriteReportJson } from "./lib/safe-report-io.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const archivePath = path.join(
  repoRoot,
  "build/apps/desktop/distribution/macos/LicoUp-macos-arm64.zip",
);
const checksumPath = `${archivePath}.sha256`;
const installedApp = "/Applications/LicoUp.app";
const bundleId = "land.lico.licoup";
const releaseEntitlementsPath = path.join(
  repoRoot,
  "apps/desktop/macos/Runner/Release.entitlements",
);
const reportRef = "build/reports/client-macos-release-artifact-preflight.json";
const maximumArchiveEntries = 20_000;
const maximumOutputBytes = 16 * 1024 * 1024;

class MacosReleaseArtifactError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

function reject(code) {
  throw new MacosReleaseArtifactError(code);
}

function requireValue(condition, code) {
  if (!condition) reject(code);
}

function run(command, args, code, { timeout = 120_000, input } = {}) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: [input === undefined ? "ignore" : "pipe", "pipe", "pipe"],
    input,
    timeout,
    maxBuffer: maximumOutputBytes,
  });
  if (result.error || result.status !== 0) reject(code);
  return String(result.stdout || "");
}

function sleep(milliseconds) {
  Atomics.wait(
    new Int32Array(new SharedArrayBuffer(4)),
    0,
    0,
    milliseconds,
  );
}

export function validateMacosReleaseArchiveEntries(entries) {
  requireValue(Array.isArray(entries) && entries.length > 0,
    "macos_release_archive_empty");
  requireValue(entries.length <= maximumArchiveEntries,
    "macos_release_archive_entry_limit_exceeded");
  let infoPlistPresent = false;
  let executableDirectoryPresent = false;
  for (const entry of entries) {
    requireValue(typeof entry === "string" && entry.length > 0 &&
      entry.length <= 4096 && !entry.includes("\\") && !entry.includes("\0") &&
      !entry.startsWith("/"), "macos_release_archive_entry_invalid");
    const segments = entry.split("/").filter(Boolean);
    requireValue(segments.length > 0 && segments[0] === "LicoUp.app" &&
      !segments.some((segment) => segment === "." || segment === ".."),
    "macos_release_archive_layout_invalid");
    if (entry === "LicoUp.app/Contents/Info.plist") infoPlistPresent = true;
    if (entry.startsWith("LicoUp.app/Contents/MacOS/")) executableDirectoryPresent = true;
  }
  requireValue(infoPlistPresent && executableDirectoryPresent,
    "macos_release_archive_bundle_incomplete");
  return true;
}

function archiveEntries() {
  const output = run(
    "/usr/bin/unzip",
    ["-Z1", archivePath],
    "macos_release_archive_inventory_failed",
  );
  return output.split(/\r?\n/u).filter(Boolean);
}

function assertArchiveChecksum() {
  const line = stableReadFile(checksumPath, { maxBytes: 4096 }).toString("utf8").trim();
  const match = /^([a-f0-9]{64})  LicoUp-macos-arm64\.zip$/u.exec(line);
  requireValue(Boolean(match), "macos_release_archive_checksum_invalid");
  const actual = sha256File(archivePath, {
    chunkBytes: 1024 * 1024,
    maxBytes: 8 * 1024 * 1024 * 1024,
  });
  requireValue(actual === `sha256:${match[1]}`,
    "macos_release_archive_checksum_mismatch");
  return actual;
}

function plistValue(appPath, key) {
  return run(
    "/usr/libexec/PlistBuddy",
    ["-c", `Print :${key}`, path.join(appPath, "Contents/Info.plist")],
    "macos_release_archive_plist_invalid",
  ).trim();
}

function releaseIdentityReady(policy, expectedFingerprint, expectedArtifactDigest = "") {
  const main = policy?.signature || {};
  return policy?.signerIdentityUniform === true &&
    policy?.nestedSignatures?.length > 0 &&
    main.verified === true &&
    main.signatureKind === "local-identity-codesign" &&
    main.signerFingerprint === expectedFingerprint &&
    main.hardenedRuntime === true &&
    main.entitlementsMatch === true &&
    (!expectedArtifactDigest || policy.artifactDigest === expectedArtifactDigest) &&
    policy.nestedSignatures.every(({ signature }) =>
      signature.verified === true &&
      signature.signatureKind === "local-identity-codesign" &&
      signature.signerFingerprint === expectedFingerprint &&
      signature.hardenedRuntime === true &&
      signature.entitlementsEmpty === true);
}

function runningExecutablePids(executablePath) {
  const result = spawnSync("/bin/ps", ["-axo", "pid=,command="], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 10_000,
    maxBuffer: maximumOutputBytes,
  });
  if (result.status !== 0 || result.error) return [];
  return String(result.stdout || "")
    .split(/\r?\n/u)
    .map((line) => /^(\s*\d+)\s+(.+)$/u.exec(line))
    .filter(Boolean)
    .filter((match) => match[2] === executablePath || match[2].startsWith(`${executablePath} `))
    .map((match) => Number(match[1]));
}

function waitForNoProcess(executablePath, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (runningExecutablePids(executablePath).length === 0) return true;
    sleep(200);
  }
  return runningExecutablePids(executablePath).length === 0;
}

function stopInstalledApp(executablePath) {
  spawnSync("/usr/bin/osascript", [
    "-e",
    `if application id "${bundleId}" is running then tell application id "${bundleId}" to quit`,
  ], { stdio: "ignore", timeout: 10_000 });
  if (waitForNoProcess(executablePath, 5_000)) return;
  for (const signal of ["SIGTERM", "SIGKILL"]) {
    for (const pid of runningExecutablePids(executablePath)) {
      try {
        process.kill(pid, signal);
      } catch {
        // The process can exit between inventory and signal delivery.
      }
    }
    if (waitForNoProcess(executablePath, 3_000)) return;
  }
  reject("macos_release_installed_process_stuck");
}

export function stableLaunchSnapshots(snapshots) {
  if (!Array.isArray(snapshots) || snapshots.length < 2 ||
    snapshots.some((snapshot) => !Array.isArray(snapshot) || snapshot.length === 0)) {
    return false;
  }
  let stable = new Set(snapshots[0]);
  for (const snapshot of snapshots.slice(1)) {
    const current = new Set(snapshot);
    stable = new Set([...stable].filter((pid) => current.has(pid)));
    if (stable.size === 0) return false;
  }
  return stable.size > 0;
}

function launchAndObserve(appPath, executableName) {
  const executablePath = path.join(appPath, "Contents/MacOS", executableName);
  stopInstalledApp(executablePath);
  try {
    run("/usr/bin/open", ["-n", appPath], "macos_release_installed_launch_failed");
    const launchDeadline = Date.now() + 20_000;
    let initial = [];
    while (Date.now() < launchDeadline && initial.length === 0) {
      initial = runningExecutablePids(executablePath);
      if (initial.length === 0) sleep(200);
    }
    requireValue(initial.length > 0, "macos_release_installed_process_missing");
    const snapshots = [initial];
    const stabilityDeadline = Date.now() + 10_000;
    while (Date.now() < stabilityDeadline) {
      sleep(250);
      snapshots.push(runningExecutablePids(executablePath));
      requireValue(stableLaunchSnapshots(snapshots),
        "macos_release_installed_process_unstable");
    }
    return true;
  } finally {
    stopInstalledApp(executablePath);
  }
}

function selfTest() {
  validateMacosReleaseArchiveEntries([
    "LicoUp.app/",
    "LicoUp.app/Contents/Info.plist",
    "LicoUp.app/Contents/MacOS/licoup",
  ]);
  for (const entries of [
    ["wrapper/LicoUp.app/Contents/Info.plist"],
    ["../LicoUp.app/Contents/Info.plist"],
    ["LicoUp.app/Contents/Info.plist", "unexpected.txt"],
  ]) {
    let rejected = false;
    try {
      validateMacosReleaseArchiveEntries(entries);
    } catch {
      rejected = true;
    }
    requireValue(rejected, "macos_release_archive_self_test_failed");
  }
  requireValue(stableLaunchSnapshots([[41], [41], [41, 42]]) &&
    !stableLaunchSnapshots([[41], [42]]) &&
    !stableLaunchSnapshots([[41], []]),
  "macos_release_launch_observation_self_test_failed");
  const fingerprint = `sha256:${"a".repeat(64)}`;
  requireValue(normalizedMacosReleaseSignerFingerprint({
    LICO_MACOS_RELEASE_SIGNER_SHA256: fingerprint,
  }) === fingerprint, "macos_release_signer_fingerprint_self_test_failed");
  process.stdout.write(JSON.stringify({
    ok: true,
    caseCount: 8,
    realInstallExecuted: false,
    realLaunchExecuted: false,
    privatePathsIncluded: false,
  }) + "\n");
}

function main() {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") {
    selfTest();
    return;
  }
  requireValue(args.length === 0, "macos_release_artifact_argument_invalid");
  requireValue(process.platform === "darwin" && process.arch === "arm64",
    "macos_release_artifact_host_invalid");
  requireValue(existsSync(archivePath) && existsSync(checksumPath),
    "macos_release_archive_missing");
  const expectedFingerprint = normalizedMacosReleaseSignerFingerprint();
  validateMacosReleaseArchiveEntries(archiveEntries());
  const archiveDigest = assertArchiveChecksum();
  const temporaryRoot = mkdtempSync(path.join(os.tmpdir(), "licoup-release-artifact-"));
  const extractedRoot = path.join(temporaryRoot, "extracted");
  const extractedApp = path.join(extractedRoot, "LicoUp.app");
  const stagedApp = `/Applications/.LicoUp.release-preflight-${process.pid}.app`;
  const backupApp = `/Applications/.LicoUp.release-backup-${process.pid}.app`;
  mkdirSync(extractedRoot, { recursive: true, mode: 0o700 });
  rmSync(stagedApp, { recursive: true, force: true });
  requireValue(!existsSync(backupApp), "macos_release_install_backup_collision");
  try {
    run("/usr/bin/ditto", ["-x", "-k", archivePath, extractedRoot],
      "macos_release_archive_extract_failed", { timeout: 300_000 });
    requireValue(readdirSync(extractedRoot).length === 1 && existsSync(extractedApp),
      "macos_release_archive_extract_layout_invalid");
    const executableName = plistValue(extractedApp, "CFBundleExecutable");
    requireValue(executableName === "licoup", "macos_release_executable_invalid");
    const extractedPolicy = inspectBoundedMacosCodePolicy(
      extractedApp,
      executableName,
      releaseEntitlementsPath,
    );
    requireValue(releaseIdentityReady(extractedPolicy, expectedFingerprint),
      "macos_release_archive_identity_invalid");
    run("/usr/bin/ditto", [extractedApp, stagedApp],
      "macos_release_install_stage_failed", { timeout: 300_000 });
    stopInstalledApp(path.join(installedApp, "Contents/MacOS", executableName));
    replaceInstalledAppWithRollback({
      stagedPath: stagedApp,
      installedPath: installedApp,
      backupPath: backupApp,
      operations: {
        exists: existsSync,
        remove: (target) => rmSync(target, { recursive: true, force: true }),
        rename: renameSync,
        verify: (target) => {
          const installedPolicy = inspectBoundedMacosCodePolicy(
            target,
            executableName,
            releaseEntitlementsPath,
          );
          return releaseIdentityReady(
            installedPolicy,
            expectedFingerprint,
            extractedPolicy.artifactDigest,
          ) && launchAndObserve(target, executableName);
        },
      },
    });
    const report = {
      schemaVersion: "licoup.client-macos-release-artifact-preflight.v1",
      generatedAt: new Date().toISOString(),
      ok: true,
      targetId: "macos-arm64",
      archiveDigest,
      artifactDigest: extractedPolicy.artifactDigest,
      signerFingerprint: expectedFingerprint,
      signerIdentityUniform: true,
      installedFromExactArchive: true,
      launchStable: true,
      privacy: {
        redacted: true,
        absolutePathsIncluded: false,
        signingIdentityNameIncluded: false,
        keyMaterialIncluded: false,
        rawLogsIncluded: false,
      },
    };
    atomicWriteReportJson(
      path.join(repoRoot, "build"),
      reportRef.replace(/^build\//u, ""),
      report,
    );
    process.stdout.write(JSON.stringify({
      ok: true,
      targetId: "macos-arm64",
      installedFromExactArchive: true,
      signerIdentityUniform: true,
      launchStable: true,
      report: reportRef,
      privatePathsIncluded: false,
    }) + "\n");
  } finally {
    rmSync(stagedApp, { recursive: true, force: true });
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
}

try {
  main();
} catch (error) {
  const code = error instanceof MacosReleaseArtifactError
    ? error.code
    : error instanceof Error && /^macos_[a-z0-9_]+$/u.test(error.message)
      ? error.message
      : "macos_release_artifact_preflight_failed";
  process.stderr.write(JSON.stringify({
    ok: false,
    stage: code,
    privatePathsIncluded: false,
  }) + "\n");
  process.exitCode = 1;
}
