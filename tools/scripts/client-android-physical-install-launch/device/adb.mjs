import { spawnSync } from "node:child_process";
import process from "node:process";
import { findAndroidAdbTool } from "../../lib/android-apk-facts.mjs";
import { minimalReleaseToolEnvironment } from "../../lib/release-tool-environment.mjs";
import { repoRoot } from "../constants.mjs";

export function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

export function runCommand(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    encoding: "utf8",
    timeout: options.timeoutMs || 30_000,
    maxBuffer: 64 * 1024 * 1024,
    stdio: "pipe",
    env: minimalReleaseToolEnvironment(),
  });
  return {
    ok: result.status === 0,
    status: result.status,
    stdout: String(result.stdout || ""),
    stderr: String(result.stderr || "")
  };
}

export function runAdb(adb, serial, args, options = {}) {
  return runCommand(adb, ["-s", serial, ...args], options);
}

export function pickAdb() {
  if (String(process.env.ADB || "").trim()) {
    throw new Error("custom adb override is not allowed in a release closure");
  }
  const adb = findAndroidAdbTool(repoRoot, { requireApprovedToolchain: true });
  const result = spawnSync(adb, ["version"], {
    encoding: "utf8",
    env: minimalReleaseToolEnvironment(),
  });
  if (result.status !== 0) {
    throw new Error("adb is not available");
  }
  return adb;
}

export function pickAdbIfAvailable() {
  try {
    return pickAdb();
  } catch {
    return "";
  }
}

export function authorizedDeviceCountIfAvailable(adb) {
  const result = runCommand(adb, ["devices"]);
  if (!result.ok) {
    return 0;
  }
  return result.stdout
    .split(/\r?\n/)
    .slice(1)
    .map((line) => line.trim().split(/\s+/))
    .filter(([serial, state]) => serial && state === "device")
    .length;
}
