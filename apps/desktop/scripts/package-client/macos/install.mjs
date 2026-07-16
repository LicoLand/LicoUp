import { existsSync, mkdirSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";

import {
  packageClientRuntime,
  packageFailure,
} from "../cli-policy.mjs";
import {
  bestEffortPackageCapture,
  bestEffortPackageProcess,
  runPackageProcess,
} from "../process-runner.mjs";
import { copyTree, isMacosBuildArtifactCandidate } from "../source-staging.mjs";
import { readMacosBundleIdentifier } from "./metadata.mjs";

export function installRunnableClient(runnable, options) {
  if (!options.install) return null;
  if (options.platform !== "macos") {
    packageFailure("install_platform_unsupported");
  }
  const installDir = macosInstallDir(options);
  const installedAppPath = path.join(
    installDir,
    packageClientRuntime.appName,
  );
  quitRunningMacosClient();
  mkdirSync(installDir, { recursive: true });
  rmSync(installedAppPath, { recursive: true, force: true });
  copyTree(runnable.appPath, installedAppPath);
  registerMacosApp(installedAppPath);
  return installedAppPath;
}

function macosInstallDir(options) {
  const explicit = explicitMacosInstallDir(options);
  if (explicit) return explicit;
  const existingApp = findInstalledLicoClientApp();
  return existingApp ? path.dirname(existingApp) : "/Applications";
}

function explicitMacosInstallDir(options) {
  if (options.installDir) return path.resolve(options.installDir);
  if (process.env.LICO_CLIENT_INSTALL_DIR) {
    return path.resolve(process.env.LICO_CLIENT_INSTALL_DIR);
  }
  return "";
}

function findInstalledLicoClientApp() {
  const seen = new Set();
  for (const candidate of [
    ...runningMacosInstallCandidates(),
    path.join("/Applications", packageClientRuntime.appName),
    path.join(os.homedir(), "Applications", packageClientRuntime.appName),
    ...spotlightMacosInstallCandidates(),
  ]) {
    const normalized = path.resolve(candidate);
    if (seen.has(normalized)) continue;
    seen.add(normalized);
    if (isMacosBuildArtifactCandidate(normalized)) continue;
    if (
      existsSync(normalized) &&
      readMacosBundleIdentifier(normalized) === packageClientRuntime.bundleId
    ) {
      return normalized;
    }
  }
  return "";
}

function runningMacosInstallCandidates() {
  const marker = `${packageClientRuntime.appName}/Contents/MacOS/`;
  return bestEffortPackageCapture("ps", ["-axo", "command="])
    .split(/\r?\n/u)
    .map((item) => {
      const markerIndex = item.indexOf(marker);
      return markerIndex < 0
        ? ""
        : item
            .slice(0, markerIndex + packageClientRuntime.appName.length)
            .trim();
    })
    .filter(Boolean);
}

function spotlightMacosInstallCandidates() {
  return bestEffortPackageCapture("mdfind", [
    `kMDItemCFBundleIdentifier == "${packageClientRuntime.bundleId}"`,
  ])
    .split(/\r?\n/u)
    .map((item) => item.trim())
    .filter(
      (item) => path.basename(item) === packageClientRuntime.appName,
    );
}

function quitRunningMacosClient() {
  bestEffortPackageProcess(
    "osascript",
    [
      "-e",
      `if application id "${packageClientRuntime.bundleId}" is running then tell application id "${packageClientRuntime.bundleId}" to quit`,
    ],
    { stdio: ["ignore", "ignore", "ignore"] },
  );
}

function registerMacosApp(appPath) {
  const lsregister =
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
  if (existsSync(lsregister)) {
    runPackageProcess(lsregister, ["-f", appPath], {
      failureCode: "macos_app_registration_failed",
      stage: "macos-install-register",
    });
  }
  runPackageProcess("mdimport", [appPath], {
    failureCode: "macos_app_registration_failed",
    stage: "macos-install-index",
  });
}
