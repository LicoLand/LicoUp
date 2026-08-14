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

import { cpSync, existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  clientSourceStateDigest,
} from "./lib/client-source-state-digest.mjs";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const APP_NAME = "LicoUp.app";
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
const BUNDLE_ID = "land.lico.licoup";
const SOURCE_DIGEST_PATTERN = /^sha256:[a-f0-9]{64}$/u;
const STAGE_PATTERN = /^macos-install-[a-z-]+$/u;

export class MacosInstallError extends Error {
  constructor(code, stage = "") {
    super(code);
    this.code = code;
    this.stage = stage;
  }
}

function fail(code, stage = "") {
  throw new MacosInstallError(code, stage);
}

function parseArgs(argv) {
  const options = {
    launchInstalled: false,
    verifyStable: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--launch-installed") {
      options.launchInstalled = true;
    } else if (arg === "--verify-stable") {
      options.verifyStable = true;
    } else {
      fail("macos_install_option_invalid");
    }
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
  return {
    ok: false,
    code,
    ...(stage ? { stage } : {}),
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

  stages.push("macos-install-quit-running");
  ports.quitRunning(installedAppPath);

  stages.push("macos-install-replace-destination");
  ports.mkdir(installDir);
  ports.remove(installedAppPath);
  ports.copyTree(runnableAppPath, installedAppPath);
  const installedManifestRoot = path.join(
    installDir,
    path.dirname(MANIFEST_RELATIVE_PATH),
  );
  const runnableManifestRoot = path.join(
    runnableRoot,
    path.dirname(MANIFEST_RELATIVE_PATH),
  );
  ports.remove(installedManifestRoot);
  ports.copyTree(runnableManifestRoot, installedManifestRoot);

  stages.push("macos-install-register");
  if (!ports.register(installedAppPath)) {
    fail("macos_install_register_failed", "macos-install-register");
  }

  const result = {
    ok: true,
    stages,
    launchRequested: launchInstalled,
    launchVerified: false,
    stableVerified: false,
    installedAppPath,
  };

  if (launchInstalled) {
    stages.push("macos-install-launch-installed");
    let launched = false;
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

function quitRunningClient() {
  const script = `if application id "${BUNDLE_ID}" is running then tell application id "${BUNDLE_ID}" to quit`;
  try {
    spawnSync("osascript", ["-e", script], {
      stdio: ["ignore", "ignore", "ignore"],
      timeout: 15_000,
    });
  } catch {
    // Best effort; destination replacement proceeds.
  }
}

function registerInstalledApp(appPath) {
  const lsregister =
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
  if (existsSync(lsregister)) {
    const result = spawnSync(lsregister, ["-f", appPath], {
      stdio: ["ignore", "ignore", "ignore"],
      timeout: 30_000,
    });
    if (result.status !== 0) return false;
  }
  const indexed = spawnSync("mdimport", [appPath], {
    stdio: ["ignore", "ignore", "ignore"],
    timeout: 30_000,
  });
  return indexed.status === 0;
}

function launchInstalledApp(appPath) {
  const result = spawnSync("open", [appPath], {
    stdio: ["ignore", "ignore", "ignore"],
    timeout: 30_000,
  });
  return result.status === 0;
}

function realPorts() {
  return {
    exists: (filePath) => existsSync(filePath),
    readJsonFile: (filePath) => JSON.parse(readFileSync(filePath, "utf8")),
    sourceDigest: () =>
      clientSourceStateDigest(workspaceRoot, CANONICAL_CLIENT_SOURCE_ROOTS),
    quitRunning: () => quitRunningClient(),
    mkdir: (directory) => mkdirSync(directory, { recursive: true }),
    remove: (target) => rmSync(target, { recursive: true, force: true }),
    copyTree: (source, target) =>
      cpSync(source, target, {
        recursive: true,
        dereference: false,
        verbatimSymlinks: true,
      }),
    register: (appPath) => registerInstalledApp(appPath),
    launchInstalled: (appPath) => launchInstalledApp(appPath),
    waitForLaunchRetry: () => sleep(LAUNCH_RETRY_DELAY_MS),
    observeStable: (appPath, windowMs) =>
      observeStableInstalledClient(appPath, windowMs),
  };
}

export function publicMacosInstallSuccess(result) {
  return {
    ok: true,
    stages: result.stages,
    launchRequested: result.launchRequested,
    launchVerified: result.launchVerified,
    stableVerified: result.stableVerified,
  };
}

function main(argv = process.argv.slice(2)) {
  if (process.platform !== "darwin") {
    fail("macos_install_requires_macos");
  }
  const flags = parseArgs(argv);
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
