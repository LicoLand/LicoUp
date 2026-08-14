#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readlinkSync,
  realpathSync,
  renameSync,
  rmSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { replaceInstalledAppWithRollback } from "./lib/macos-app-install.mjs";
import {
  inspectBoundedMacosCodePolicy,
  inspectMacosContainerSignature,
} from "./lib/macos-code-signature.mjs";
import { expectedMacosReleaseSignerFingerprint } from "./lib/macos-release-identity.mjs";
import { sha256File, stableReadFile } from "./lib/client-release-artifact-digest.mjs";
import { atomicWriteReportJson } from "./lib/safe-report-io.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const archivePath = path.join(repoRoot,
  "build/apps/desktop/distribution/macos/LicoUp-macos-arm64.dmg");
const checksumPath = `${archivePath}.sha256`;
const installedApp = "/Applications/LicoUp.app";
const bundleId = "land.lico.licoup";
const entitlementsPath = path.join(repoRoot,
  "build/apps/desktop/signing/macos/release/ProductionRelease.resolved.entitlements");
const reportRef = "reports/client-macos-release-artifact-preflight.json";
const maximumOutputBytes = 16 * 1024 * 1024;

class ArtifactError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

function reject(code) { throw new ArtifactError(code); }
function requireValue(value, code) { if (!value) reject(code); }

function run(command, args, code, timeout = 120_000) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout,
    maxBuffer: maximumOutputBytes,
  });
  if (result.error || result.status !== 0) reject(code);
  return String(result.stdout || "");
}

function pause(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

export function validateMacosDmgLayout(entries, applicationsLink) {
  const expectedEntries = [
    "Applications",
    "LicoUp License.txt",
    "LicoUp Open Source Notice.txt",
    "LicoUp Privacy Policy.html",
    "LicoUp.app",
    "Third-Party Notices.txt",
  ];
  requireValue(Array.isArray(entries) &&
    JSON.stringify(entries) === JSON.stringify(expectedEntries) &&
    applicationsLink === "/Applications", "audit_archive_layout_invalid");
  return true;
}

export function stableLaunchSnapshots(snapshots) {
  if (!Array.isArray(snapshots) || snapshots.length < 2 ||
    snapshots.some((snapshot) => !Array.isArray(snapshot) || snapshot.length === 0)) return false;
  let stable = new Set(snapshots[0]);
  for (const snapshot of snapshots.slice(1)) {
    const current = new Set(snapshot);
    stable = new Set([...stable].filter((pid) => current.has(pid)));
    if (stable.size === 0) return false;
  }
  return stable.size > 0;
}

function executablePids(executablePath) {
  const output = run("/bin/ps", ["-axo", "pid=,command="],
    "audit_launch_unstable", 10_000);
  return output.split(/\r?\n/u)
    .map((line) => /^(\s*\d+)\s+(.+)$/u.exec(line))
    .filter(Boolean)
    .filter((match) => match[2] === executablePath || match[2].startsWith(`${executablePath} `))
    .map((match) => Number(match[1]));
}

export function stopApp(executablePath) {
  spawnSync("/usr/bin/osascript", ["-e",
    `if application id "${bundleId}" is running then tell application id "${bundleId}" to quit`],
  { stdio: "ignore", timeout: 10_000 });
  for (const signal of ["SIGTERM", "SIGKILL"]) {
    if (executablePids(executablePath).length === 0) return;
    for (const pid of executablePids(executablePath)) {
      try { process.kill(pid, signal); } catch { /* exited concurrently */ }
    }
    pause(500);
  }
  requireValue(executablePids(executablePath).length === 0, "audit_launch_unstable");
}

export function launchStable(appPath, executableName) {
  const executablePath = path.join(realpathSync(appPath), "Contents/MacOS", executableName);
  try {
    return launchStableProcess(appPath, executableName) > 0;
  } finally {
    stopApp(executablePath);
  }
}

export function launchStableProcess(appPath, executableName) {
  const executablePath = path.join(realpathSync(appPath), "Contents/MacOS", executableName);
  stopApp(executablePath);
  run("/usr/bin/open", ["-n", appPath], "audit_launch_unstable");
  const snapshots = [];
  const deadline = Date.now() + 12_000;
  while (Date.now() < deadline) {
    pause(500);
    const pids = executablePids(executablePath);
    if (pids.length > 0) snapshots.push(pids);
    if (snapshots.length >= 8 && stableLaunchSnapshots(snapshots)) {
      const stable = snapshots.reduce((common, current) =>
        common.filter((pid) => current.includes(pid)), snapshots[0]);
      return stable[0] || 0;
    }
  }
  stopApp(executablePath);
  return 0;
}

function plistValue(appPath, key) {
  return run("/usr/libexec/PlistBuddy", ["-c", `Print :${key}`,
    path.join(appPath, "Contents/Info.plist")], "audit_archive_layout_invalid").trim();
}

export function identityReady(policy, expectedFingerprint, artifactDigest = "") {
  return policy?.signerIdentityUniform === true &&
    policy?.signature?.verified === true &&
    policy.signature.signatureKind === "local-identity-codesign" &&
    policy.signature.signerFingerprint === expectedFingerprint &&
    policy.signature.hardenedRuntime === true && policy.signature.entitlementsMatch === true &&
    (!artifactDigest || policy.artifactDigest === artifactDigest) &&
    policy.nestedSignatures?.length > 0 &&
    policy.nestedSignatures.every(({ signature }) => signature.verified === true &&
      signature.signatureKind === "local-identity-codesign" &&
      signature.signerFingerprint === expectedFingerprint &&
      signature.hardenedRuntime === true && signature.entitlementsEmpty === true);
}

function verifyChecksum() {
  const line = stableReadFile(checksumPath, { maxBytes: 4096 }).toString("utf8").trim();
  const match = /^([a-f0-9]{64})  LicoUp-macos-arm64\.dmg$/u.exec(line);
  requireValue(match, "audit_archive_digest_mismatch");
  const digest = sha256File(archivePath, { maxBytes: 8 * 1024 * 1024 * 1024 });
  requireValue(digest === `sha256:${match[1]}`, "audit_archive_digest_mismatch");
  return digest;
}

function selfTest() {
  const canonicalEntries = [
    "Applications",
    "LicoUp License.txt",
    "LicoUp Open Source Notice.txt",
    "LicoUp Privacy Policy.html",
    "LicoUp.app",
    "Third-Party Notices.txt",
  ];
  validateMacosDmgLayout(canonicalEntries, "/Applications");
  for (const [entries, link] of [
    [canonicalEntries.filter((entry) => entry !== "Third-Party Notices.txt"),
      "/Applications"],
    [[...canonicalEntries, "unexpected.txt"], "/Applications"],
    [canonicalEntries, "/fixture-root/Applications"],
  ]) {
    let rejected = false;
    try { validateMacosDmgLayout(entries, link); } catch { rejected = true; }
    requireValue(rejected, "artifact_self_test_failed");
  }
  requireValue(stableLaunchSnapshots([[1], [1], [1, 2]]) &&
    !stableLaunchSnapshots([[1], [2]]) && !stableLaunchSnapshots([[1], []]),
  "artifact_self_test_failed");
  process.stdout.write(`${JSON.stringify({ ok: true, caseCount: 7,
    realInstallExecuted: false, realLaunchExecuted: false, privateDataIncluded: false })}\n`);
}

function execute() {
  requireValue(process.platform === "darwin" && process.arch === "arm64",
    "audit_selected_target_build_failed");
  requireValue(existsSync(archivePath) && existsSync(checksumPath),
    "audit_archive_layout_invalid");
  const archiveDigest = verifyChecksum();
  const expectedFingerprint = expectedMacosReleaseSignerFingerprint();
  const temporaryRoot = mkdtempSync(path.join(os.tmpdir(), "licoup-release-artifact-"));
  const mountedRoot = path.join(temporaryRoot, "mounted");
  const mountedApp = path.join(mountedRoot, "LicoUp.app");
  const stagedApp = `/Applications/.LicoUp.release-preflight-${process.pid}.app`;
  const backupApp = `/Applications/.LicoUp.release-backup-${process.pid}.app`;
  mkdirSync(mountedRoot, { recursive: true, mode: 0o700 });
  rmSync(stagedApp, { recursive: true, force: true });
  let mounted = false;
  try {
    const containerSignature = inspectMacosContainerSignature(archivePath);
    requireValue(containerSignature.verified === true &&
      containerSignature.signerFingerprint === expectedFingerprint,
    "audit_nested_code_identity_mismatch");
    run("/usr/bin/hdiutil", ["attach", "-quiet", "-readonly", "-nobrowse",
      "-mountpoint", mountedRoot, archivePath], "audit_archive_layout_invalid", 300_000);
    mounted = true;
    const entries = readdirSync(mountedRoot).sort();
    const applicationsPath = path.join(mountedRoot, "Applications");
    requireValue(lstatSync(applicationsPath).isSymbolicLink() &&
      lstatSync(mountedApp).isDirectory(), "audit_archive_layout_invalid");
    validateMacosDmgLayout(entries, readlinkSync(applicationsPath));
    requireValue(existsSync(mountedApp),
      "audit_archive_layout_invalid");
    const executableName = plistValue(mountedApp, "CFBundleExecutable");
    const mountedPolicy = inspectBoundedMacosCodePolicy(
      mountedApp, executableName, entitlementsPath);
    requireValue(identityReady(mountedPolicy, expectedFingerprint),
      "audit_nested_code_identity_mismatch");
    run("/usr/bin/ditto", [mountedApp, stagedApp],
      "audit_installed_artifact_mismatch", 300_000);
    stopApp(path.join(installedApp, "Contents/MacOS", executableName));
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
            target, executableName, entitlementsPath);
          return identityReady(installedPolicy, expectedFingerprint,
            mountedPolicy.artifactDigest) && launchStable(target, executableName);
        },
      },
    });
    atomicWriteReportJson(path.join(repoRoot, "build"), reportRef, {
      schemaVersion: "licoup.client-macos-release-artifact-preflight.v1",
      target: "macos-arm64",
      archiveDigest,
      artifactDigest: archiveDigest,
      installedAppDigest: mountedPolicy.artifactDigest,
      archiveLayoutReady: true,
      archiveDigestVerified: true,
      stableReleaseIdentity: true,
      nestedCodeIdentityUniform: true,
      installedFromExactArtifact: true,
      launchStable: true,
      privacy: {
        redacted: true,
        absolutePathsIncluded: false,
        accountDataIncluded: false,
        credentialsIncluded: false,
        identityMaterialIncluded: false,
        rawOutputIncluded: false,
      },
    });
    process.stdout.write(`${JSON.stringify({ ok: true, target: "macos-arm64",
      archiveDigestVerified: true, installedFromExactArtifact: true,
      launchStable: true, privateDataIncluded: false })}\n`);
  } finally {
    rmSync(stagedApp, { recursive: true, force: true });
    if (mounted) {
      spawnSync("/usr/bin/hdiutil", ["detach", "-quiet", mountedRoot], {
        stdio: "ignore", timeout: 120_000,
      });
    }
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
}

function main() {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") return selfTest();
  requireValue(args.length === 0, "artifact_argument_invalid");
  execute();
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try { main(); } catch (error) {
    const code = error instanceof ArtifactError ? error.code :
      /^audit_[a-z0-9_]+$/u.test(String(error?.message || ""))
        ? error.message : "audit_installed_artifact_mismatch";
    process.stderr.write(`${JSON.stringify({ ok: false, code, privateDataIncluded: false })}\n`);
    process.exitCode = 1;
  }
}
