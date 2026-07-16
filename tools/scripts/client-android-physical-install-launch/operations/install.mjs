import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { assertAndroidApkFactsEqual, inspectAndroidApkFacts } from "../../lib/android-apk-facts.mjs";
import {
  resolveContainedExistingPath,
} from "../../lib/client-release-artifact-digest.mjs";
import { minimalReleaseToolEnvironment } from "../../lib/release-tool-environment.mjs";
import { repoRoot } from "../constants.mjs";
import { runAdb } from "../device/adb.mjs";

export function successfulAdbInstall(result) {
  return result?.ok === true &&
    /(?:^|\n)Success(?:\r?\n|$)/u.test(String(result.stdout || ""));
}

export function installApk(adb, serial, apk, options) {
  const streamed = runAdb(adb, serial, ["install", "-r", apk.path], {
    timeoutMs: options.installTimeoutMs
  });
  const streamedReady = successfulAdbInstall(streamed);
  const fallback = streamedReady
    ? null
    : runAdb(adb, serial, ["install", "--no-streaming", "-r", apk.path], {
        timeoutMs: options.installTimeoutMs
      });
  const fallbackReady = successfulAdbInstall(fallback);
  return {
    attempted: true,
    installedViaVerifier: streamedReady || fallbackReady,
    ok: streamedReady || fallbackReady,
    fallbackUsed: streamedReady ? false : fallback !== null
  };
}

export function isPackageInstalled(adb, serial, packageName) {
  const result = runAdb(adb, serial, ["shell", "pm", "path", packageName]);
  return result.ok && String(result.stdout || "")
    .split(/\r?\n/u)
    .some((line) => line.trim().startsWith("package:") &&
      line.trim().slice("package:".length).startsWith("/"));
}

function installedBaseApkDevicePath(adb, serial, packageName) {
  const result = runAdb(adb, serial, ["shell", "pm", "path", packageName], {
    timeoutMs: 10_000
  });
  if (!result.ok) return "";
  const candidates = String(result.stdout || "")
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .filter((line) => line.startsWith("package:"))
    .map((line) => line.slice("package:".length));
  return candidates.find((candidate) => /(?:^|\/)base\.apk$/u.test(candidate)) ||
    (candidates.length === 1 ? candidates[0] : "");
}

export function inspectInstalledApk(adb, serial, packageName, workRoot) {
  const devicePath = installedBaseApkDevicePath(adb, serial, packageName);
  if (!devicePath) return { ready: false };
  const installedPath = path.join(workRoot, "installed-base.apk");
  const pulled = spawnSync(adb, [
    "-s",
    serial,
    "pull",
    devicePath,
    installedPath,
  ], {
    cwd: repoRoot,
    stdio: "ignore",
    timeout: 120_000,
    env: minimalReleaseToolEnvironment(),
  });
  if (pulled.status !== 0 || !existsSync(installedPath)) {
    return { ready: false };
  }
  const safeInstalledPath = resolveContainedExistingPath(workRoot, installedPath, {
    expectedKind: "file",
  });
  const facts = inspectAndroidApkFacts(repoRoot, safeInstalledPath, {
    requireApprovedToolchain: true,
  });
  if (facts.packageName !== packageName) return { ready: false };
  return { ready: true, facts };
}

export { assertAndroidApkFactsEqual };
