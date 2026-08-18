import { existsSync, statSync } from "node:fs";
import { execFileSync, spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { packageClient } from "./package-client.mjs";

const licoClientBundleId = "land.lico.licoup";
const canonicalPackageArgs = ["--platform", "macos", "--mode", "release"];
const sidecarScanTimeoutMillis = 45_000;

function fail(message) {
  throw new Error(`[client:run:macos] ${message}`);
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    stdio: "inherit",
    ...options
  });
  if (result.status !== 0) {
    fail(`${command} ${args.join(" ")} failed`);
  }
}

function runCaptured(command, args, options = {}) {
  return spawnSync(command, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    ...options
  });
}

function sleep(seconds) {
  spawnSync("sleep", [String(seconds)], { stdio: "ignore" });
}

function runningClientPids() {
  const result = runCaptured("ps", ["-axo", "pid=,command="]);
  if (result.status !== 0) {
    return [];
  }
  const currentPid = process.pid;
  return result.stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const match = /^(\d+)\s+(.+)$/.exec(line);
      return match ? { pid: Number(match[1]), command: match[2] } : null;
    })
    .filter((entry) => {
      if (!entry || entry.pid === currentPid) {
        return false;
      }
      return (
        entry.command.includes("/Contents/MacOS/licoup") &&
        (entry.command.includes("/LicoUp.app/") ||
          entry.command.includes("/licoup.app/"))
      );
    })
    .map((entry) => entry.pid);
}

function waitForClientExit(timeoutMillis) {
  const deadline = Date.now() + timeoutMillis;
  while (Date.now() < deadline) {
    if (runningClientPids().length === 0) {
      return true;
    }
    sleep(0.2);
  }
  return runningClientPids().length === 0;
}

function quitRunningClient() {
  try {
    execFileSync(
      "osascript",
      [
        "-e",
        `if application id "${licoClientBundleId}" is running then tell application id "${licoClientBundleId}" to quit`
      ],
      { stdio: "ignore" }
    );
  } catch {
    // Continue with process-level cleanup below.
  }
  if (waitForClientExit(5000)) {
    return;
  }
  for (const pid of runningClientPids()) {
    try {
      process.kill(pid, "SIGTERM");
    } catch {
      // The process may have exited between listing and kill.
    }
  }
  if (waitForClientExit(3000)) {
    return;
  }
  for (const pid of runningClientPids()) {
    try {
      process.kill(pid, "SIGKILL");
    } catch {
      // Best effort; the open step below will still target the canonical app.
    }
  }
  waitForClientExit(1000);
}

function assertExecutable(filePath, label) {
  if (!existsSync(filePath) || !statSync(filePath).isFile()) {
    fail(`${label} is missing: ${filePath}`);
  }
  try {
    execFileSync("test", ["-x", filePath], { stdio: "ignore" });
  } catch {
    fail(`${label} is not executable: ${filePath}`);
  }
}

function verifyRunnable(appPath) {
  const executable = path.join(appPath, "Contents", "MacOS", "licoup");
  const sidecar = path.join(appPath, "Contents", "MacOS", "licoup-cli");
  assertExecutable(executable, "canonical Flutter executable");
  assertExecutable(sidecar, "canonical licoup sidecar");

  const scan = runCaptured(sidecar, [
    "targets",
    "scan",
    "--include-accessible-environments",
    "true",
    "--include-history-model-catalog",
    "false"
  ], {
    timeout: sidecarScanTimeoutMillis,
    killSignal: "SIGTERM"
  });
  if (scan.error?.code === "ETIMEDOUT") {
    fail(`sidecar target scan exceeded ${sidecarScanTimeoutMillis}ms`);
  }
  if (scan.status !== 0) {
    fail(`sidecar target scan failed: ${scan.stderr.trim() || scan.stdout.trim()}`);
  }
  let decoded;
  try {
    decoded = JSON.parse(scan.stdout);
  } catch {
    fail("sidecar target scan did not return JSON");
  }
  if (decoded?.ok !== true || !Array.isArray(decoded.candidates)) {
    fail("sidecar target scan returned an invalid result");
  }
  const visibleTargets = decoded.candidates.filter(
    (candidate) => candidate?.status !== "not-detected"
  );
  console.log(
    `[client:run:macos] Sidecar scan OK: ${visibleTargets.length} visible target(s).`
  );
}

function main(argv = process.argv.slice(2)) {
  if (process.platform !== "darwin") {
    fail("This entry is only for macOS.");
  }
  if (argv.length > 0) {
    fail("This entry is intentionally optionless; it always builds and opens the release runnable.");
  }

  quitRunningClient();
  const result = packageClient(canonicalPackageArgs);
  const appPath = result?.runnable?.appPath;
  if (!appPath) {
    fail("packaging did not produce a runnable macOS app");
  }
  verifyRunnable(appPath);
  quitRunningClient();
  run("open", [appPath]);
  console.log(`[client:run:macos] Opened canonical client: ${appPath}`);
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
}
