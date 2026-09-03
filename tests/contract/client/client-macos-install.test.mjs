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
  existsSync,
  lstatSync,
  realpathSync,
  renameSync,
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

import {
  registeredLicoUpApps,
  uninstallMacosApplication,
} from "../../../tools/scripts/lib/macos-app-lifecycle.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const installerPath = path.join(repoRoot, "tools/scripts/client-macos-install.mjs");
const APP_NAME = "LicoUp.app";
const CURRENT_DIGEST = `sha256:${"a".repeat(64)}`;
const STALE_DIGEST = `sha256:${"b".repeat(64)}`;
const BUNDLE_ID = "land.lico.licoup";
const temporaryRoots = [];
function tempRoot(prefix) {
  const root = mkdtempSync(path.join(os.tmpdir(), prefix));
  temporaryRoots.push(root);
  return root;
}
test.after(() => { for (const root of temporaryRoots) rmSync(root, { recursive: true, force: true }); });

function makeRunnableTree({
  digest = CURRENT_DIGEST,
  platform = "macos",
  mode = "release",
  includeApp = true,
  includeManifest = true,
} = {}) {
  const root = tempRoot("lico-install-runnable-");
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
      JSON.stringify({ CFBundleIdentifier: BUNDLE_ID, CFBundleName: "LicoUp" }),
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
    canonicalPath: (target) => existsSync(target) ? realpathSync(target) : path.resolve(target),
    bundleInfo: (target) => {
      try { return JSON.parse(readFileSync(path.join(target, "Contents", "Info.plist"), "utf8")); }
      catch { return null; }
    },
    isSymlink: (target) => lstatSync(target, { throwIfNoEntry: false })?.isSymbolicLink() || false,
    installationRoots: () => [],
    directoryEntries: (root) => existsSync(root) ? readdirSync(root) : [],
    registeredApps: () => [],
    indexedApps: () => [],
    buildApps: () => [],
    unregister: () => true,
    makeTempDirectory: (root) => mkdtempSync(path.join(root, ".licoup-install-")),
    move: renameSync,
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
  const installDir = tempRoot("lico-install-dest-");
  const { calls, ports } = recordingPorts();

  const result = runMacosInstaller(
    { installDir, runnableRoot },
    ports,
  );

  assert.equal(result.ok, true);
  assert.deepEqual(result.stages, [
    "macos-install-validate-runnable",
    "macos-install-validate-binding",
    "macos-install-stage-payload",
    "macos-install-quit-running",
    "macos-install-unregister",
    "macos-install-replace-destination",
    "macos-install-register",
    "macos-install-clean-build-apps",
  ]);
  const runnableAppPath = path.join(runnableRoot, APP_NAME);
  const installedAppPath = path.join(installDir, APP_NAME);
  assert.equal(calls.copy.length, 2);
  assert.equal(calls.copy[0].source, runnableAppPath);
  assert.equal(path.basename(calls.copy[0].target), "payload");
  assert.equal(calls.copy[1].source, path.join(runnableRoot, "package-metadata", "licoup"));
  assert.deepEqual(readdirSync(installDir).sort(), [APP_NAME, "package-metadata"]);
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
    const installDir = tempRoot("lico-install-dest-");
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
    const installDir = tempRoot("lico-install-dest-");
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
  const installDir = tempRoot("lico-install-dest-");
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
  const installDir = tempRoot("lico-install-dest-");
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
  const installDir = tempRoot("lico-install-dest-");
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
  const installDir = tempRoot("lico-install-dest-");

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
  const installDir = tempRoot("lico-install-cli-dest-");
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

function copyFixtureApp(runnableRoot, destination) {
  mkdirSync(path.dirname(destination), { recursive: true });
  cpSync(path.join(runnableRoot, APP_NAME), destination, { recursive: true });
  return destination;
}

test("upgrade replaces all installed copies and unregisters build and deleted entries", () => {
  const runnableRoot = makeRunnableTree();
  const installDir = tempRoot("lico-lifecycle-system-");
  const userDir = tempRoot("lico-lifecycle-user-");
  const target = copyFixtureApp(runnableRoot, path.join(installDir, APP_NAME));
  const duplicate = copyFixtureApp(runnableRoot, path.join(userDir, "LicoUp old.app"));
  const renamed = copyFixtureApp(runnableRoot, path.join(installDir, ".LicoUp.backup.synthetic"));
  const buildApp = path.join(runnableRoot, APP_NAME);
  const missing = path.join(userDir, "removed", APP_NAME);
  const foreign = copyFixtureApp(runnableRoot, path.join(userDir, "Another.app"));
  writeFileSync(path.join(foreign, "Contents", "Info.plist"), JSON.stringify({
    CFBundleIdentifier: BUNDLE_ID, CFBundleName: "Another",
  }));
  writeFileSync(path.join(target, "obsolete.txt"), "old");
  const data = path.join(userDir, "user-data");
  writeFileSync(data, "keep");
  const { ports } = recordingPorts();
  ports.installationRoots = () => [installDir, userDir];
  ports.registeredApps = () => [target, duplicate, renamed, buildApp, missing];
  ports.indexedApps = () => [buildApp, foreign];
  const unregistered = [];
  ports.unregister = (apps) => { unregistered.push(...apps); return true; };
  for (let iteration = 0; iteration < 2; iteration += 1) {
    runMacosInstaller({ installDir, runnableRoot }, ports);
    assert.equal(treeDigest(target), treeDigest(buildApp));
    assert.equal(existsSync(duplicate), false);
    assert.equal(existsSync(renamed), false);
    assert.equal(existsSync(foreign), true);
    assert.equal(readFileSync(data, "utf8"), "keep");
    assert.deepEqual(readdirSync(installDir).sort(), [APP_NAME, "package-metadata"]);
  }
  for (const app of [target, duplicate, renamed, buildApp, missing]) assert.ok(unregistered.includes(app));
  assert.equal(unregistered.includes(foreign), false);
});

test("copy failure preserves installed app and cleans the temporary payload", () => {
  const runnableRoot = makeRunnableTree();
  const installDir = tempRoot("lico-lifecycle-failure-");
  const target = copyFixtureApp(runnableRoot, path.join(installDir, APP_NAME));
  const before = treeDigest(target);
  const { ports, calls } = recordingPorts();
  ports.copyTree = () => { throw new Error("synthetic-copy-failure"); };
  assert.throws(() => runMacosInstaller({ installDir, runnableRoot }, ports), /synthetic-copy-failure/);
  assert.equal(treeDigest(target), before);
  assert.equal(calls.quit.length, 0);
  assert.deepEqual(readdirSync(installDir), [APP_NAME]);
});

test("uninstall removes apps and package metadata without a runnable and is repeatable", () => {
  const runnableRoot = makeRunnableTree();
  const installDir = tempRoot("lico-lifecycle-uninstall-");
  const target = copyFixtureApp(runnableRoot, path.join(installDir, APP_NAME));
  const duplicate = copyFixtureApp(runnableRoot, path.join(installDir, "LicoUp 2.app"));
  const metadata = path.join(installDir, "package-metadata", "licoup");
  mkdirSync(metadata, { recursive: true });
  writeFileSync(path.join(metadata, "packaging-modules.json"), "{}");
  const { ports } = recordingPorts();
  const unregistered = [];
  ports.registeredApps = () => [target, duplicate];
  ports.unregister = (apps) => { unregistered.push(...apps); return true; };
  rmSync(runnableRoot, { recursive: true });
  const first = uninstallMacosApplication({ installDir }, ports);
  assert.equal(first.removedApplications, 2);
  assert.equal(first.userDataPreserved, true);
  assert.equal(existsSync(target), false);
  assert.equal(existsSync(duplicate), false);
  assert.equal(existsSync(metadata), false);
  assert.ok(unregistered.includes(target));
  assert.ok(unregistered.includes(duplicate));
  assert.equal(uninstallMacosApplication({ installDir }, ports).removedApplications, 0);
});

test("source overlap, foreign destination and unregister failure never remove an installed app", () => {
  const runnableRoot = makeRunnableTree();
  const { ports } = recordingPorts();
  assert.throws(() => runMacosInstaller({ installDir: runnableRoot, runnableRoot }, ports),
    { code: "macos_install_source_destination_overlap" });
  const installDir = tempRoot("lico-lifecycle-conflict-");
  const target = copyFixtureApp(runnableRoot, path.join(installDir, APP_NAME));
  const infoPath = path.join(target, "Contents", "Info.plist");
  writeFileSync(infoPath, JSON.stringify({ CFBundleIdentifier: "example.foreign", CFBundleName: "Another" }));
  assert.throws(() => runMacosInstaller({ installDir, runnableRoot }, ports),
    { code: "macos_install_destination_conflict" });
  rmSync(target, { recursive: true });
  copyFixtureApp(runnableRoot, target);
  ports.unregister = () => false;
  assert.throws(() => runMacosInstaller({ installDir, runnableRoot }, ports),
    { code: "macos_install_unregister_failed" });
  assert.equal(existsSync(target), true);
  assert.deepEqual(readdirSync(installDir), [APP_NAME]);
});

test("LaunchServices discovery deduplicates exact LicoUp identity including deleted backups", () => {
  const record = (app, name = "LicoUp", id = BUNDLE_ID) =>
    `path:                       ${app} (0xabc)\nname:                       ${name}\nidentifier:                 ${id}\n`;
  const dump = [
    record("/Applications/LicoUp.app"), record("/Applications/LicoUp.app"),
    record("/synthetic/build/LicoUp.app"), record("/synthetic/.LicoUp.backup.old"),
    record("/Applications/Another.app", "Another"),
    record("/Applications/Foreign.app", "LicoUp", "example.foreign"),
  ].join(`\n${"-".repeat(80)}\n`);
  assert.deepEqual(registeredLicoUpApps(dump), [
    "/Applications/LicoUp.app", "/synthetic/build/LicoUp.app", "/synthetic/.LicoUp.backup.old",
  ]);
});


test("successful install consumes generated app copies; uninstall retires newly built copies", () => {
  const runnableRoot = makeRunnableTree();
  const installDir = tempRoot("lico-lifecycle-generated-");
  const generated = path.join(runnableRoot, APP_NAME);
  const { ports } = recordingPorts();
  ports.buildApps = () => [generated];
  const before = treeDigest(generated);
  runMacosInstaller({ installDir, runnableRoot }, ports);
  assert.equal(existsSync(generated), false);
  assert.equal(treeDigest(path.join(installDir, APP_NAME)), before);
  cpSync(path.join(installDir, APP_NAME), generated, { recursive: true });
  const result = uninstallMacosApplication({ installDir }, ports);
  assert.equal(result.removedBuildApplications, 1);
  assert.equal(existsSync(generated), false);
  assert.equal(existsSync(path.join(installDir, APP_NAME)), false);
});
