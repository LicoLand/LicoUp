#!/usr/bin/env node
// Existing-runnable macOS installer.
//
// Packaging owns build and manifest emission.  This installer validates the
// canonical already-built release runnable against the current source state,
// replaces the destination only after validation, registers the installed
// app, and optionally launches the exact installed bundle with a bounded
// stable-survival observation.  It never invokes a build.
//
// Privacy contract: this tool never prints resolved local paths, process
// commands, user identity, or raw tool output.  It returns stable booleans
// and named stages only.

import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  clientSourceStateDigest,
} from "./lib/client-source-state-digest.mjs";

import {
  MACOS_APP_NAME as APP_NAME,
  MacosInstallError,
  createMacosAppPorts,
  installMacosApplication,
  uninstallMacosApplication,
} from "./lib/macos-app-lifecycle.mjs";

export { MacosInstallError };

const workspaceRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));

const EXECUTABLE_RELATIVE_PATH = path.join("Contents", "MacOS", "licoup");
const MANIFEST_RELATIVE_PATH = path.join(
  "package-metadata",
  "licoup",
  "packaging-modules.json",
);
const DEFAULT_RUNNABLE_ROOT = path.join(
  workspaceRoot,
  "build",
  "apps",
  "desktop",
  "runnable",
  "macos",
  "release",
);
const DEFAULT_INSTALL_DIR = "/Applications";
const DEFAULT_STABLE_WINDOW_MS = 30_000;
const STABLE_POLL_INTERVAL_MS = 500;
const LAUNCH_ATTEMPTS = 3;
const LAUNCH_RETRY_DELAY_MS = 500;
const SOURCE_DIGEST_PATTERN = /^sha256:[a-f0-9]{64}$/u;
const STAGE_PATTERN = /^macos-(?:install|uninstall)-[a-z-]+$/u;
const STABLE_DETAIL_PATTERN = /^[a-z][a-z0-9._-]{0,63}$/u;
const INITIALIZE_FAILURE_CODE = "client_initialize_failed";

function fail(code, stage = "", detail = "") {
  const error = new MacosInstallError(code, stage);
  error.detail = STABLE_DETAIL_PATTERN.test(detail) ? detail : "";
  throw error;
}

function parseArgs(argv) {
  const options = {
    launchInstalled: false,
    verifyStable: false,
    uninstall: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--uninstall") {
      options.uninstall = true;
    } else if (arg === "--launch-installed") {
      options.launchInstalled = true;
    } else if (arg === "--verify-stable") {
      options.verifyStable = true;
    } else {
      fail("macos_install_option_invalid");
    }
  }
  if (options.uninstall && (options.launchInstalled || options.verifyStable)) {
    fail("macos_install_option_invalid");
  }
  return options;
}

function resolveInstallDir() {
  const explicit = process.env.LICO_CLIENT_INSTALL_DIR;
  if (explicit) return path.resolve(explicit);
  return DEFAULT_INSTALL_DIR;
}

function resolveRunnableRoot() {
  const explicit = process.env.LICO_CLIENT_RUNNABLE_ROOT;
  return explicit ? path.resolve(explicit) : DEFAULT_RUNNABLE_ROOT;
}

export function publicMacosInstallFailure(error) {
  const code = error instanceof MacosInstallError
    ? error.code
    : "macos_install_failed";
  const stage = error instanceof MacosInstallError &&
    STAGE_PATTERN.test(error.stage || "")
    ? error.stage
    : "";
  const detail = error instanceof MacosInstallError &&
    STABLE_DETAIL_PATTERN.test(error.detail || "")
    ? error.detail
    : "";
  return {
    ok: false,
    code,
    ...(stage ? { stage } : {}),
    ...(detail ? { detail } : {}),
    privatePathsIncluded: false,
  };
}

export function runMacosInstaller(
  {
    installDir,
    runnableRoot,
    launchInstalled = false,
    verifyStable = false,
    stableWindowMs = DEFAULT_STABLE_WINDOW_MS,
  },
  ports,
) {
  if (verifyStable && !launchInstalled) {
    fail("macos_install_stable_requires_launch");
  }

  const stages = [];
  const runnableAppPath = path.join(runnableRoot, APP_NAME);
  const installedAppPath = path.join(installDir, APP_NAME);

  stages.push("macos-install-validate-runnable");
  if (
    !ports.exists(runnableAppPath) ||
    !ports.exists(path.join(runnableAppPath, EXECUTABLE_RELATIVE_PATH))
  ) {
    fail("macos_install_runnable_missing", "macos-install-validate-runnable");
  }

  stages.push("macos-install-validate-binding");
  const manifestPath = path.join(runnableRoot, MANIFEST_RELATIVE_PATH);
  if (!ports.exists(manifestPath)) {
    fail("macos_install_manifest_missing", "macos-install-validate-binding");
  }
  let manifest;
  try {
    manifest = ports.readJsonFile(manifestPath);
  } catch {
    fail("macos_install_manifest_invalid", "macos-install-validate-binding");
  }
  const expectedDigest = ports.sourceDigest();
  if (
    !SOURCE_DIGEST_PATTERN.test(String(manifest.sourceStateDigest || "")) ||
    manifest.sourceStateDigest !== expectedDigest
  ) {
    fail("macos_install_stale_runnable", "macos-install-validate-binding");
  }
  if (
    manifest.platform !== "macos" ||
    manifest.mode !== "release" ||
    manifest.flutterExecutable !==
      path.join(APP_NAME, "Contents", "MacOS", "licoup")
  ) {
    fail("macos_install_runnable_mismatch", "macos-install-validate-binding");
  }

  const lifecycle = installMacosApplication({
    sourceApp: runnableAppPath,
    installDir,
    manifestRoot: path.join(runnableRoot, path.dirname(MANIFEST_RELATIVE_PATH)),
    stages,
  }, ports);

  const result = {
    ok: true,
    stages,
    launchRequested: launchInstalled,
    launchVerified: false,
    stableVerified: false,
    initializationVerified: false,
    visualCaptureRecorded: false,
    installedAppPath,
    removedApplications: lifecycle.removedApplications,
    unregisteredApplications: lifecycle.unregisteredApplications,
  };

  let launchedAtMs = 0;
  if (launchInstalled) {
    stages.push("macos-install-launch-installed");
    let launched = false;
    launchedAtMs = Date.now();
    for (let attempt = 1; attempt <= LAUNCH_ATTEMPTS; attempt += 1) {
      if (ports.launchInstalled(installedAppPath)) {
        launched = true;
        break;
      }
      if (attempt < LAUNCH_ATTEMPTS) ports.waitForLaunchRetry();
    }
    if (!launched) {
      fail("macos_install_launch_failed", "macos-install-launch-installed");
    }
    result.launchVerified = true;
  }

  if (verifyStable) {
    stages.push("macos-install-verify-stable");
    result.stableVerified = ports.observeStable(installedAppPath, stableWindowMs);
    if (!result.stableVerified) {
      fail("macos_install_unstable", "macos-install-verify-stable");
    }

    // Visual evidence rides on the stable window: capture the settled screen
    // before the initialization verdict so a failed bootstrap is photographed.
    // Capture is best-effort evidence, never a gate.
    stages.push("macos-install-capture-visual");
    result.visualCaptureRecorded = ports.captureVisual(
      visualReportPath(Date.now()),
    );

    // A launched process is not a working client: the bootstrap records any
    // initialization failure in the local lifecycle diagnostic log. Admitting
    // only fresh records keeps previous runs' evidence from failing this one.
    stages.push("macos-install-verify-initialization");
    const initializeFailure = ports
      .readLifecycleDiagnostics()
      .find(
        (record) =>
          record.code === INITIALIZE_FAILURE_CODE &&
          record.createdAtMs >= launchedAtMs,
      );
    if (initializeFailure) {
      fail(
        "macos_install_initialize_failed",
        "macos-install-verify-initialization",
        initializeFailure.stepId,
      );
    }
    result.initializationVerified = true;
  }

  return result;
}

function sleep(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

function processMarkerPresent(marker) {
  const result = spawnSync("ps", ["-axo", "command="], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 10_000,
  });
  if (result.status !== 0) return null;
  return String(result.stdout || "")
    .split(/\r?\n/u)
    .some((line) => line.includes(marker));
}

function observeStableInstalledClient(appPath, windowMs) {
  const marker = `${appPath}${path.sep}Contents${path.sep}MacOS${path.sep}`;
  const deadline = Date.now() + windowMs;
  let stable = false;
  while (Date.now() < deadline) {
    const present = processMarkerPresent(marker);
    if (stable && present === false) return false;
    if (present === true) stable = true;
    sleep(Math.min(STABLE_POLL_INTERVAL_MS, Math.max(200, Math.floor(windowMs / 8))));
  }
  return stable;
}

function launchInstalledApp(appPath) {
  const result = spawnSync("open", [appPath], {
    stdio: ["ignore", "ignore", "ignore"],
    timeout: 30_000,
  });
  return result.status === 0;
}

// The installed bundled client keeps its state root in the home dot folder;
// the lifecycle diagnostic log is the bounded local evidence written by the
// client itself. Only stable codes, step ids, and timestamps leave this reader.
function readLifecycleDiagnosticRecords() {
  const logPath = path.join(
    os.homedir(),
    ".lico-up",
    "client-state",
    "diagnostics",
    "client-lifecycle.jsonl",
  );
  let text;
  try {
    text = readFileSync(logPath, "utf8");
  } catch {
    return [];
  }
  const records = [];
  for (const line of text.split(/\r?\n/u)) {
    if (!line.trim()) continue;
    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch {
      continue;
    }
    const createdAtMs = Date.parse(String(parsed.createdAt || ""));
    const code = String(parsed.code || "");
    const stepId = String(parsed.stepId || "");
    if (!Number.isFinite(createdAtMs)) continue;
    if (!STABLE_DETAIL_PATTERN.test(code)) continue;
    if (!STABLE_DETAIL_PATTERN.test(stepId)) continue;
    records.push({ code, stepId, createdAtMs });
  }
  return records;
}

function visualReportPath(timestampMs) {
  return path.join(
    workspaceRoot,
    "build",
    "reports",
    `client-macos-install-${timestampMs}.png`,
  );
}

// Screen capture permission is a host privacy grant: when it is missing the
// capture simply records false and the install keeps its verdict.
function captureVisualReport(targetPath) {
  try {
    mkdirSync(path.dirname(targetPath), { recursive: true });
    const result = spawnSync("screencapture", ["-x", targetPath], {
      stdio: ["ignore", "ignore", "ignore"],
      timeout: 15_000,
    });
    return result.status === 0 && existsSync(targetPath);
  } catch {
    return false;
  }
}

function realPorts() {
  return {
    ...createMacosAppPorts(),
    readJsonFile: (filePath) => JSON.parse(readFileSync(filePath, "utf8")),
    sourceDigest: () =>
      clientSourceStateDigest(workspaceRoot, CANONICAL_CLIENT_SOURCE_ROOTS),
    launchInstalled: (appPath) => launchInstalledApp(appPath),
    waitForLaunchRetry: () => sleep(LAUNCH_RETRY_DELAY_MS),
    observeStable: (appPath, windowMs) =>
      observeStableInstalledClient(appPath, windowMs),
    readLifecycleDiagnostics: () => readLifecycleDiagnosticRecords(),
    captureVisual: (targetPath) => captureVisualReport(targetPath),
  };
}

export function publicMacosInstallSuccess(result) {
  return {
    ok: true,
    stages: result.stages,
    launchRequested: result.launchRequested,
    launchVerified: result.launchVerified,
    stableVerified: result.stableVerified,
    initializationVerified: result.initializationVerified === true,
    visualCaptureRecorded: result.visualCaptureRecorded === true,
  };
}

function main(argv = process.argv.slice(2)) {
  if (process.platform !== "darwin") {
    fail("macos_install_requires_macos");
  }
  const flags = parseArgs(argv);
  if (flags.uninstall) {
    console.log(JSON.stringify(uninstallMacosApplication({ installDir: resolveInstallDir() })));
    return;
  }
  const result = runMacosInstaller(
    {
      installDir: resolveInstallDir(),
      runnableRoot: resolveRunnableRoot(),
      launchInstalled: flags.launchInstalled,
      verifyStable: flags.verifyStable,
    },
    realPorts(),
  );
  console.log(JSON.stringify(publicMacosInstallSuccess(result)));
}

const isCliEntry =
  fileURLToPath(import.meta.url) === path.resolve(process.argv[1] || "");

if (isCliEntry) {
  try {
    main();
  } catch (error) {
    console.error(JSON.stringify(publicMacosInstallFailure(error)));
    process.exitCode = 1;
  }
}
