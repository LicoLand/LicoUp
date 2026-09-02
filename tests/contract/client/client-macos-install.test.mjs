// Existing-runnable macOS installer contract.
//
// Synthetic canonical and stale macOS runnable trees with package/source-state
// manifests plus fake copy, registration, launch, and process-observation
// ports.  Asserts a zero build-invocation count, pre-mutation stale rejection,
// byte-for-byte matching between runnable and installed trees, exact installed
// launch argument, bounded stable-survival observation, and redacted CLI
// output.  Never builds, launches, or installs a real client.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  cpSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  MacosInstallError,
  publicMacosInstallFailure,
  publicMacosInstallSuccess,
  runMacosInstaller,
} from "../../../tools/scripts/client-macos-install.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const installerPath = path.join(repoRoot, "tools/scripts/client-macos-install.mjs");
const APP_NAME = "LicoUp.app";
const CURRENT_DIGEST = `sha256:${"a".repeat(64)}`;
const STALE_DIGEST = `sha256:${"b".repeat(64)}`;
const BUNDLE_ID = "land.lico.licoup";

function makeRunnableTree({
  digest = CURRENT_DIGEST,
  platform = "macos",
  mode = "release",
  includeApp = true,
  includeManifest = true,
} = {}) {
  const root = mkdtempSync(path.join(os.tmpdir(), "lico-install-runnable-"));
  const appPath = path.join(root, APP_NAME);
  if (includeApp) {
    const executableDir = path.join(appPath, "Contents", "MacOS");
    mkdirSync(executableDir, { recursive: true });
    writeFileSync(
      path.join(executableDir, "licoup"),
      Buffer.from("synthetic-licoup-executable"),
    );
    writeFileSync(
      path.join(appPath, "Contents", "Info.plist"),
      "<plist><dict/></plist>",
    );
  }
  if (includeManifest) {
    const manifestPath = path.join(
      root,
      "package-metadata",
      "licoup",
      "packaging-modules.json",
    );
    mkdirSync(path.dirname(manifestPath), { recursive: true });
    writeFileSync(
      manifestPath,
      `${JSON.stringify({
        schemaVersion: "v0.0.1:client-desktop:bundle-manifest-2",
        sourceStateDigest: digest,
        platform,
        mode,
        flutterExecutable: "LicoUp.app/Contents/MacOS/licoup",
      }, null, 2)}\n`,
    );
  }
  return root;
}

function recordingPorts({
  digest = CURRENT_DIGEST,
  launchResult = true,
  launchResults = null,
  stableResult = true,
} = {}) {
  const calls = {
    copy: [],
    remove: [],
    register: [],
    launch: [],
    observe: [],
    launchWait: 0,
    quit: [],
    mkdir: [],
  };
  const ports = {
    exists: (filePath) => {
      try {
        statSync(filePath);
        return true;
      } catch {
        return false;
      }
    },
    readJsonFile: (filePath) => JSON.parse(readFileSync(filePath, "utf8")),
    sourceDigest: () => digest,
    quitRunning: (appPath) => {
      calls.quit.push(appPath);
    },
    mkdir: (directory) => {
      calls.mkdir.push(directory);
      mkdirSync(directory, { recursive: true });
    },
    remove: (target) => {
      calls.remove.push(target);
      rmSync(target, { recursive: true, force: true });
    },
    copyTree: (source, target) => {
      calls.copy.push({ source, target });
      cpSync(source, target, { recursive: true });
    },
    register: (appPath) => {
      calls.register.push(appPath);
      return true;
    },
    launchInstalled: (appPath) => {
      calls.launch.push(appPath);
      return launchResults === null
        ? launchResult
        : launchResults[calls.launch.length - 1] ?? false;
    },
    waitForLaunchRetry: () => {
      calls.launchWait += 1;
    },
    observeStable: (appPath, windowMs) => {
      calls.observe.push({ appPath, windowMs });
      return stableResult;
    },
  };
  return { calls, ports };
}

function treeDigest(root) {
  const entries = [];
  (function visit(relative) {
    const resolved = path.join(root, relative);
    const info = statSync(resolved);
    if (info.isDirectory()) {
      for (const name of readdirSync(resolved).sort()) {
        visit(path.join(relative, name));
      }
      return;
    }
    entries.push(`${relative}:${info.size}:${readFileSync(resolved).toString("base64")}`);
  })("");
  return createHash("sha256").update(entries.join("|")).digest("hex");
}

function runCli(environment) {
  const environmentWithoutTestContext = { ...process.env };
  delete environmentWithoutTestContext.NODE_TEST_CONTEXT;
  return spawnSync(process.execPath, [installerPath], {
    encoding: "utf8",
    env: { ...environmentWithoutTestContext, ...environment },
    timeout: 60_000,
  });
}

test("existing current-bound runnable installs byte-for-byte without invoking a build", () => {
  const runnableRoot = makeRunnableTree();
  const installDir = mkdtempSync(path.join(os.tmpdir(), "lico-install-dest-"));
  const { calls, ports } = recordingPorts();

  const result = runMacosInstaller(
    { installDir, runnableRoot },
    ports,
  );

  assert.equal(result.ok, true);
  assert.deepEqual(result.stages, [
    "macos-install-validate-runnable",
    "macos-install-validate-binding",
    "macos-install-quit-running",
    "macos-install-replace-destination",
    "macos-install-register",
  ]);
  const runnableAppPath = path.join(runnableRoot, APP_NAME);
  const installedAppPath = path.join(installDir, APP_NAME);
  assert.deepEqual(calls.copy, [
    { source: runnableAppPath, target: installedAppPath },
    {
      source: path.join(runnableRoot, "package-metadata", "licoup"),
      target: path.join(installDir, "package-metadata", "licoup"),
    },
  ]);
  assert.deepEqual(calls.register, [installedAppPath]);
  assert.deepEqual(calls.launch, []);
  assert.equal(treeDigest(installedAppPath), treeDigest(runnableAppPath));
  const manifestRelative = path.join("package-metadata", "licoup", "packaging-modules.json");
  assert.deepEqual(
    readFileSync(path.join(installDir, manifestRelative)),
    readFileSync(path.join(runnableRoot, manifestRelative)),
  );
  assert.deepEqual(
    readFileSync(path.join(installedAppPath, "Contents", "MacOS", "licoup")),
    readFileSync(path.join(runnableAppPath, "Contents", "MacOS", "licoup")),
  );

  const source = readFileSync(installerPath, "utf8");
  assert.equal(source.includes("package-client"), false);
  assert.equal(source.includes("client:run:macos"), false);
  assert.equal(source.includes("client:build"), false);
  assert.equal(source.includes("flutter build"), false);
  assert.equal(Object.keys(calls).includes("spawn"), false);
});

test("stale or mismatched runnable fails before any destination mutation", () => {
  for (const [fixture, expectedCode] of [
    [{ digest: STALE_DIGEST }, "macos_install_stale_runnable"],
    [{ platform: "linux" }, "macos_install_runnable_mismatch"],
    [{ mode: "debug" }, "macos_install_runnable_mismatch"],
  ]) {
    const runnableRoot = makeRunnableTree(fixture);
    const installDir = mkdtempSync(path.join(os.tmpdir(), "lico-install-dest-"));
    const oldMarker = path.join(installDir, APP_NAME, "keep.txt");
    mkdirSync(path.dirname(oldMarker), { recursive: true });
    writeFileSync(oldMarker, "old-content");
    const { calls, ports } = recordingPorts();

    assert.throws(
      () => runMacosInstaller({ installDir, runnableRoot }, ports),
      (error) => error instanceof MacosInstallError &&
        error.code === expectedCode &&
        error.stage === "macos-install-validate-binding",
    );
    assert.equal(calls.copy.length, 0);
    assert.equal(calls.remove.length, 0);
    assert.equal(calls.register.length, 0);
    assert.equal(calls.quit.length, 0);
    assert.equal(readFileSync(oldMarker, "utf8"), "old-content");
  }
});

test("missing runnable, missing or invalid manifest fail closed without mutation", () => {
  for (const [fixture, expectedCode] of [
    [{ includeApp: false }, "macos_install_runnable_missing"],
    [{ includeManifest: false }, "macos_install_manifest_missing"],
  ]) {
    const runnableRoot = makeRunnableTree(fixture);
    const installDir = mkdtempSync(path.join(os.tmpdir(), "lico-install-dest-"));
    const { calls, ports } = recordingPorts();

    assert.throws(
      () => runMacosInstaller({ installDir, runnableRoot }, ports),
      (error) => error instanceof MacosInstallError && error.code === expectedCode,
    );
    assert.equal(calls.copy.length, 0);
    assert.equal(calls.remove.length, 0);
    assert.equal(calls.register.length, 0);
  }

  const runnableRoot = makeRunnableTree();
  const installDir = mkdtempSync(path.join(os.tmpdir(), "lico-install-dest-"));
  const manifestPath = path.join(
    runnableRoot,
    "package-metadata",
    "licoup",
    "packaging-modules.json",
  );
  writeFileSync(manifestPath, "{not-json");
  const { calls, ports } = recordingPorts();
  assert.throws(
    () => runMacosInstaller({ installDir, runnableRoot }, ports),
    (error) => error instanceof MacosInstallError &&
      error.code === "macos_install_manifest_invalid",
  );
  assert.equal(calls.copy.length, 0);
});

test("launch targets the exact installed bundle path and never a bundle-id selection", () => {
  const runnableRoot = makeRunnableTree();
  const installDir = mkdtempSync(path.join(os.tmpdir(), "lico-install-dest-"));
  const { calls, ports } = recordingPorts();

  const result = runMacosInstaller(
    { installDir, runnableRoot, launchInstalled: true },
    ports,
  );

  assert.equal(result.launchVerified, true);
  const installedAppPath = path.join(installDir, APP_NAME);
  assert.deepEqual(calls.launch, [installedAppPath]);
  assert.notEqual(calls.launch[0], path.join(runnableRoot, APP_NAME));
  assert.notEqual(calls.launch[0], BUNDLE_ID);
  assert.equal(path.isAbsolute(calls.launch[0]), true);
});

test("launch retries a bounded transient LaunchServices failure", () => {
  const runnableRoot = makeRunnableTree();
  const installDir = mkdtempSync(path.join(os.tmpdir(), "lico-install-dest-"));
  const { calls, ports } = recordingPorts({ launchResults: [false, true] });

  const result = runMacosInstaller(
    { installDir, runnableRoot, launchInstalled: true },
    ports,
  );

  assert.equal(result.launchVerified, true);
  assert.equal(calls.launch.length, 2);
  assert.equal(calls.launchWait, 1);
  assert.ok(calls.launch.every((value) => value === path.join(installDir, APP_NAME)));
});

test("failed launch and bounded stable survival report only safe state", () => {
  const runnableRoot = makeRunnableTree();
  const installDir = mkdtempSync(path.join(os.tmpdir(), "lico-install-dest-"));

  const failingLaunch = recordingPorts({ launchResult: false });
  assert.throws(
    () => runMacosInstaller(
      { installDir, runnableRoot, launchInstalled: true },
      failingLaunch.ports,
    ),
    (error) => error instanceof MacosInstallError &&
      error.code === "macos_install_launch_failed" &&
      error.stage === "macos-install-launch-installed",
  );
  assert.equal(failingLaunch.calls.launch.length, 3);
  assert.equal(failingLaunch.calls.launchWait, 2);

  const stable = recordingPorts({ stableResult: true });
  const windowMs = 5_000;
  const result = runMacosInstaller(
    { installDir, runnableRoot, launchInstalled: true, verifyStable: true, stableWindowMs: windowMs },
    stable.ports,
  );
  assert.equal(result.stableVerified, true);
  assert.deepEqual(stable.calls.observe, [{
    appPath: path.join(installDir, APP_NAME),
    windowMs,
  }]);

  const unstable = recordingPorts({ stableResult: false });
  assert.throws(
    () => runMacosInstaller(
      { installDir, runnableRoot, launchInstalled: true, verifyStable: true, stableWindowMs: windowMs },
      unstable.ports,
    ),
    (error) => error instanceof MacosInstallError &&
      error.code === "macos_install_unstable" &&
      error.stage === "macos-install-verify-stable",
  );
  assert.equal(unstable.calls.quit.length, 1);

  const noLaunch = recordingPorts();
  assert.throws(
    () => runMacosInstaller(
      { installDir, runnableRoot, verifyStable: true },
      noLaunch.ports,
    ),
    (error) => error instanceof MacosInstallError &&
      error.code === "macos_install_stable_requires_launch",
  );
  assert.equal(noLaunch.calls.copy.length, 0);
});

test("public records are stable, named, and free of private paths", () => {
  const result = {
    ok: true,
    stages: ["macos-install-register"],
    launchRequested: true,
    launchVerified: true,
    stableVerified: true,
    installedAppPath: "/Applications/LicoUp.app",
  };
  assert.deepEqual(publicMacosInstallSuccess(result), {
    ok: true,
    stages: ["macos-install-register"],
    launchRequested: true,
    launchVerified: true,
    stableVerified: true,
  });

  const privateMarker = "/Applications/fixture/LicoUp.app";
  const failure = publicMacosInstallFailure(
    new MacosInstallError("macos_install_stale_runnable", "macos-install-validate-binding"),
  );
  assert.deepEqual(failure, {
    ok: false,
    code: "macos_install_stale_runnable",
    stage: "macos-install-validate-binding",
    privatePathsIncluded: false,
  });
  assert.equal(JSON.stringify(failure).includes(privateMarker), false);
  assert.equal(JSON.stringify(failure).includes("/"), false);
  const generic = publicMacosInstallFailure(new Error(privateMarker));
  assert.deepEqual(generic, {
    ok: false,
    code: "macos_install_failed",
    privatePathsIncluded: false,
  });
});

test("CLI failures are redacted and expose only stable named codes", () => {
  const runnableRoot = makeRunnableTree({ digest: STALE_DIGEST });
  const installDir = mkdtempSync(path.join(os.tmpdir(), "lico-install-cli-dest-"));
  const result = runCli({
    LICO_CLIENT_RUNNABLE_ROOT: runnableRoot,
    LICO_CLIENT_INSTALL_DIR: installDir,
  });

  assert.notEqual(result.status, 0);
  const record = JSON.parse(result.stderr.trim().split(/\r?\n/u).at(-1));
  assert.equal(record.ok, false);
  assert.match(record.code, /^macos_install_[a-z_]+$/u);
  assert.equal(record.privatePathsIncluded, false);
  if (process.platform === "darwin") {
    assert.equal(record.code, "macos_install_stale_runnable");
    assert.equal(record.stage, "macos-install-validate-binding");
  }
  const combined = `${result.stdout}\n${result.stderr}`;
  for (const privatePath of [runnableRoot, installDir, os.homedir()]) {
    assert.equal(combined.includes(privatePath), false, privatePath);
  }
});
