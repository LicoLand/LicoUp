#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { artifactTreeSnapshot } from "./lib/client-release-artifact-digest.mjs";
import { inspectBoundedMacosCodePolicy } from "./lib/macos-code-signature.mjs";
import { expectedMacosReleaseSignerFingerprint } from "./lib/macos-release-identity.mjs";
import {
  identityReady,
  launchStable,
  launchStableProcess,
  stopApp,
} from "./client-macos-release-artifact-preflight.mjs";
import { atomicWriteReportJson } from "./lib/safe-report-io.mjs";
import { updateSigningKeyEnvironment } from "./lib/update-signing-keychain.mjs";
import { sanitizeError } from "./lib/sanitize-error.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const archivePath = path.join(repoRoot,
  "build/apps/desktop/distribution/macos/LicoUp-macos-arm64-update.zip");
const reportRef = "reports/client-macos-update-preflight.json";
const entitlementsPath = path.join(repoRoot,
  "apps/desktop/macos/Runner/Release.entitlements");
let lastFailureDetail = "";

function requireValue(value, code) { if (!value) throw new Error(code); }

function run(command, args, code, timeout = 300_000, env = process.env) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout,
    maxBuffer: 16 * 1024 * 1024,
    env,
  });
  if (result.error || result.status !== 0) {
    lastFailureDetail = sanitizeError(String(result.stderr || result.error?.message || ""))
      .replace(/\s+/gu, " ").trim().slice(0, 512);
    requireValue(false, code);
  }
  return String(result.stdout || "");
}

export function updateCommandArgs(action, {
  manifestPath,
  publicKeysPath,
  stagingRoot,
  installRoot,
  currentVersion,
  sourcePath,
  guiPid,
}) {
  requireValue(["download", "verify", "apply", "rollback"].includes(action),
    "audit_update_path_missing");
  const args = [
    "update", action,
    "--channel", "stable",
    "--manifest-path", manifestPath,
    "--public-keys-path", publicKeysPath,
    "--staging-root", stagingRoot,
    "--install-root", installRoot,
    "--current-version", currentVersion,
  ];
  if (action === "download") args.push("--source-path", sourcePath);
  if (action === "apply" || action === "rollback") {
    requireValue(Number.isSafeInteger(guiPid) && guiPid > 0, "audit_update_path_missing");
    args.push("--gui-pid", String(guiPid),
      "--execute", "true", "--wait-for-script", "true");
  }
  return args;
}

function selfTest() {
  const options = {
    manifestPath: "/synthetic/manifest.json",
    publicKeysPath: "/synthetic/keys.json",
    stagingRoot: "/synthetic/staging",
    installRoot: "/synthetic/install",
    currentVersion: "0.0.1",
    sourcePath: "/synthetic/LicoUp.zip",
    guiPid: 7,
  };
  const download = updateCommandArgs("download", options);
  const apply = updateCommandArgs("apply", options);
  requireValue(download.includes("--source-path") && !apply.includes("--source-path") &&
    apply.includes("--wait-for-script"), "update_preflight_self_test_failed");
  process.stdout.write(`${JSON.stringify({ ok: true, caseCount: 3,
    realUpdateExecuted: false, privateDataIncluded: false })}\n`);
}

function execute() {
  requireValue(process.platform === "darwin" && process.arch === "arm64",
    "audit_update_path_missing");
  const baselineAppInput = String(process.env.LICO_RELEASE_BASELINE_APP || "").trim();
  const baselineApp = path.resolve(baselineAppInput || ".");
  const baselineVersion = String(process.env.LICO_RELEASE_BASELINE_VERSION || "").trim();
  const baselineKind = String(process.env.LICO_RELEASE_BASELINE_KIND || "").trim();
  requireValue(baselineAppInput.length > 0 && path.isAbsolute(baselineAppInput) &&
    baselineApp.endsWith(".app") && baselineApp !== "/" &&
    existsSync(baselineApp) && /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(baselineVersion) &&
    ["bootstrap", "published-stable"].includes(baselineKind),
  "audit_update_baseline_invalid");
  const cliPath = path.join(baselineApp, "Contents/MacOS/licoup-cli");
  requireValue(existsSync(archivePath) && existsSync(cliPath),
    "audit_update_path_missing");
  const baselineExecutable = run("/usr/libexec/PlistBuddy", ["-c",
    "Print :CFBundleExecutable", path.join(baselineApp, "Contents/Info.plist")],
  "audit_update_baseline_invalid").trim();
  const baselineProductVersion = run("/usr/libexec/PlistBuddy", ["-c",
    "Print :CFBundleShortVersionString", path.join(baselineApp, "Contents/Info.plist")],
  "audit_update_baseline_invalid").trim();
  const baselinePolicy = inspectBoundedMacosCodePolicy(
    baselineApp, baselineExecutable, entitlementsPath);
  requireValue(baselineProductVersion === baselineVersion &&
    identityReady(baselinePolicy, expectedMacosReleaseSignerFingerprint()) &&
    launchStable(baselineApp, baselineExecutable), "audit_update_baseline_identity_invalid");

  const temporaryRoot = mkdtempSync(path.join(os.tmpdir(), "licoup-update-preflight-"));
  const installRoot = path.join(temporaryRoot, "Applications");
  const installedApp = path.join(installRoot, "LicoUp.app");
  const assetsRoot = path.join(repoRoot, "build/tmp/release-pre-pr-update-assets");
  const stagingRoot = path.join(temporaryRoot, "staging");
  const manifestPath = path.join(assetsRoot, "LicoUp-update-manifest.json");
  const publicKeysPath = path.join(assetsRoot, "LicoUp-update-public-keys.json");
  rmSync(assetsRoot, { recursive: true, force: true });
  mkdirSync(assetsRoot, { recursive: true, mode: 0o700 });
  mkdirSync(installRoot, { recursive: true, mode: 0o700 });
  try {
    run("/usr/bin/ditto", [baselineApp, installedApp],
      "audit_update_path_missing");
    const baselineDigest = artifactTreeSnapshot(installedApp).digest;
    const guiPid = launchStableProcess(installedApp, baselineExecutable);
    requireValue(guiPid > 0, "audit_update_baseline_process_missing");
    copyFileSync(archivePath, path.join(assetsRoot, "LicoUp-macos-arm64-update.zip"));
    const checksumSource = `${archivePath}.sha256`;
    copyFileSync(checksumSource,
      path.join(assetsRoot, "LicoUp-macos-arm64-update.zip.sha256"));
    const versionAuthority = JSON.parse(readFileSync(
      path.join(repoRoot, "tools/client-version.json"), "utf8"));
    const currentVersion = versionAuthority.productVersion;
    if (currentVersion === "0.1.0" && versionAuthority.buildNumber === 2) {
      requireValue(baselineKind === "bootstrap", "audit_update_path_missing");
    }
    run(process.execPath, [
      "tools/scripts/client-update-manifest.mjs",
      "--assets", assetsRoot,
      "--output", manifestPath,
      "--public-keys-output", publicKeysPath,
      "--tag", `v${currentVersion}`,
      "--repo", "LicoLand/LicoUp",
      "--targets", "macos-arm64=true,linux-glibc-arm64=false,android-arm64=false",
      "--minimum-supported-version", baselineVersion,
    ], "audit_update_manifest_invalid", 300_000, updateSigningKeyEnvironment());
    const options = { manifestPath, publicKeysPath, stagingRoot, installRoot,
      currentVersion: baselineVersion, sourcePath: archivePath, guiPid };
    for (const action of ["download", "verify", "apply"]) {
      run(cliPath, updateCommandArgs(action, options),
        `audit_update_${action}_failed`, 600_000);
    }
    const candidateDigest = artifactTreeSnapshot(installedApp).digest;
    requireValue(candidateDigest !== baselineDigest, "audit_update_apply_failed");
    run(cliPath, updateCommandArgs("rollback", options),
      "audit_update_rollback_failed", 600_000);
    requireValue(artifactTreeSnapshot(installedApp).digest === baselineDigest,
      "audit_update_rollback_failed");
    atomicWriteReportJson(path.join(repoRoot, "build"), reportRef, {
      schemaVersion: "licoup.client-macos-update-preflight.v1",
      target: "macos-arm64",
      updaterExecuted: true,
      candidateApplied: true,
      failureRecoveryVerified: true,
      baselineKind,
      publishedStableClaimed: baselineKind === "published-stable",
      baselineIdentityVerified: true,
      baselineLaunchVerified: true,
      baselineRestored: true,
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
      updatePathVerified: true, failureRecoveryVerified: true,
      privateDataIncluded: false })}\n`);
  } finally {
    if (existsSync(installedApp)) {
      stopApp(path.join(installedApp, "Contents/MacOS", baselineExecutable));
    }
    rmSync(temporaryRoot, { recursive: true, force: true });
    rmSync(assetsRoot, { recursive: true, force: true });
  }
}

function main() {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") return selfTest();
  requireValue(args.length === 0, "audit_update_path_missing");
  execute();
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try { main(); } catch (error) {
    const code = /^audit_[a-z0-9_]+$/u.test(String(error?.message || ""))
      ? error.message : "audit_update_path_missing";
    process.stderr.write(`${JSON.stringify({ ok: false,
      code, detail: lastFailureDetail || undefined, privateDataIncluded: false })}\n`);
    process.exitCode = 1;
  }
}
