import assert from "node:assert/strict";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { execFileSync, spawn } from "node:child_process";
import {
  completeTestArtifactWorkspace,
  acquireTestArtifactLease,
  inventoryTestArtifacts,
  pruneTestArtifactTarget,
  pruneReclaimableTestArtifacts,
  testArtifactId,
  testArtifactStatus,
} from "./test-artifact-lifecycle.mjs";
import { FLUTTER_TEST_TARGET } from "./test-artifact-lifecycle/constants.mjs";
import { processEntriesLinux, targetProcessUsage } from "./test-artifact-lifecycle/process-use.mjs";
import { parseArtifactCommand, runArtifactCommand } from "../client-test-artifacts.mjs";

const syntheticValue = (label) => `${label}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;

const projectRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));

function temporaryRepository(t) {
  const repoRoot = realpathSync(mkdtempSync(path.join(os.tmpdir(), "licoup-artifact-test-")));
  mkdirSync(path.join(repoRoot, "build"), { recursive: true });
  execFileSync("git", ["init", "--quiet", repoRoot]);
  t.after(() => rmSync(repoRoot, { force: true, recursive: true }));
  return repoRoot;
}

function materialize(repoRoot, relativePath, contents = "compiled") {
  const target = path.join(repoRoot, ...relativePath.split("/"));
  mkdirSync(path.dirname(target), { recursive: true });
  writeFileSync(target, contents, { mode: 0o755 });
  return target;
}

test("active build output is protected and released output is reclaimable", (t) => {
  const repoRoot = temporaryRepository(t);
  const targetPath = FLUTTER_TEST_TARGET;
  const compiledFile = materialize(repoRoot, `${targetPath}/test/client.dill`);
  const deliverable = materialize(repoRoot, "build/out/package.tar", "deliverable");
  const lease = acquireTestArtifactLease({
    repoRoot,
    scope: "flutter-test",
    targetPath,
  });

  assert.deepEqual(testArtifactStatus({ repoRoot }), {
    active: 1,
    cleaned: 0,
    invalid: 0,
    reclaimable: 0,
    unmanaged: 0,
  });
  assert.deepEqual(pruneReclaimableTestArtifacts({ repoRoot }), {
    active: 1,
    eligible: 0,
    failed: 0,
    removed: 0,
    skipped: 0,
    unmanaged: 0,
  });
  assert.equal(existsSync(compiledFile), true);

  assert.deepEqual(lease.release(), { state: "reclaimable" });
  assert.equal(testArtifactStatus({ repoRoot }).reclaimable, 1);
  const dryRun = pruneReclaimableTestArtifacts({ repoRoot, dryRun: true });
  assert.equal(dryRun.eligible, 1);
  assert.equal(dryRun.removed, 0);
  assert.equal(existsSync(compiledFile), true);

  const pruned = pruneReclaimableTestArtifacts({ repoRoot });
  assert.equal(pruned.removed, 1);
  assert.equal(existsSync(compiledFile), false);
  assert.equal(existsSync(deliverable), true);
  assert.equal(testArtifactStatus({ repoRoot }).cleaned, 1);
});

test("output cleanup preserves packaged and installed clients", (t) => {
  const repoRoot = temporaryRepository(t);
  const installedRoot = mkdtempSync(path.join(os.tmpdir(), "licoup-installed-test-"));
  t.after(() => rmSync(installedRoot, { force: true, recursive: true }));
  const targetPath = FLUTTER_TEST_TARGET;
  const compiledFile = materialize(repoRoot, `${targetPath}/release/client.dill`);
  const runnableFile = materialize(
    repoRoot,
    "build/apps/desktop/runnable/macos/release/LicoUp.app/Contents/MacOS/licoup",
  );
  const installedFile = materialize(
    installedRoot,
    "LicoUp.app/Contents/MacOS/licoup",
  );
  const lease = acquireTestArtifactLease({
    repoRoot,
    scope: "client-build",
    targetPath,
  });
  lease.release();

  const result = pruneReclaimableTestArtifacts({ repoRoot });

  assert.equal(result.removed, 1);
  assert.equal(existsSync(compiledFile), false);
  assert.equal(existsSync(runnableFile), true);
  assert.equal(existsSync(installedFile), true);
});

test("all concurrent leases must finish before output becomes reclaimable", (t) => {
  const repoRoot = temporaryRepository(t);
  const targetPath = FLUTTER_TEST_TARGET;
  materialize(repoRoot, `${targetPath}/test/client.dill`);
  const first = acquireTestArtifactLease({ repoRoot, scope: "first", targetPath });
  const second = acquireTestArtifactLease({ repoRoot, scope: "second", targetPath });

  assert.deepEqual(first.release(), { state: "active" });
  assert.equal(testArtifactStatus({ repoRoot }).active, 1);
  assert.equal(pruneReclaimableTestArtifacts({ repoRoot }).removed, 0);
  assert.deepEqual(second.release(), { state: "reclaimable" });
  assert.equal(testArtifactStatus({ repoRoot }).reclaimable, 1);
});

test("dead leases require the configured grace period before recovery", (t) => {
  const repoRoot = temporaryRepository(t);
  const targetPath = FLUTTER_TEST_TARGET;
  const compiledFile = materialize(repoRoot, `${targetPath}/test/client.dill`);
  const clock = { value: Date.parse("2026-01-01T00:00:00.000Z") };
  acquireTestArtifactLease({
    deadLeaseGraceMs: 1_000,
    isAlive: () => false,
    now: () => clock.value,
    repoRoot,
    scope: "crashed",
    targetPath,
  });

  clock.value += 999;
  assert.equal(testArtifactStatus({
    deadLeaseGraceMs: 1_000,
    isAlive: () => false,
    now: () => clock.value,
    repoRoot,
  }).active, 1);
  clock.value += 1;
  const status = testArtifactStatus({
    deadLeaseGraceMs: 1_000,
    isAlive: () => false,
    now: () => clock.value,
    repoRoot,
  });
  assert.equal(status.active, 0);
  assert.equal(status.invalid, 0);
  assert.equal(status.reclaimable, 1);
  const pruned = pruneReclaimableTestArtifacts({
    deadLeaseGraceMs: 1_000,
    isAlive: () => false,
    now: () => clock.value,
    repoRoot,
  });
  assert.equal(pruned.removed, 1);
  assert.equal(existsSync(compiledFile), false);
});

test("concurrent processes reclaim a stale lock once and serialize output ownership", async (t) => {
  const sv_stale = syntheticValue('stale');
  const repoRoot = temporaryRepository(t);
  const targetPath = FLUTTER_TEST_TARGET;
  const artifactId = testArtifactId(targetPath);
  const record = path.join(repoRoot, "build", ".test-artifacts", artifactId);
  const lock = path.join(record, ".lock");
  mkdirSync(lock, { recursive: true });
  writeFileSync(path.join(lock, "owner.json"), JSON.stringify({
    acquiredAt: "2000-01-01T00:00:00.000Z",
    pid: 2_000_000_000,
    token: sv_stale,
  }));

  const source = String.raw`
    import { existsSync, readFileSync, writeFileSync } from "node:fs";
    import path from "node:path";
    import { pathToFileURL } from "node:url";
    const root = process.argv[1];
    const id = process.argv[2];
    const sourceRoot = process.argv[3];
    const { artifactRecordPaths, withArtifactLock } = await import(
      pathToFileURL(path.join(sourceRoot, "tools/scripts/lib/test-artifact-lifecycle/registry.mjs"))
    );
    const state = path.join(root, "build", "critical-section.json");
    withArtifactLock(artifactRecordPaths(root, id), () => {
      const active = existsSync(state) ? JSON.parse(readFileSync(state, "utf8")).active : 0;
      if (active !== 0) process.exitCode = 4;
      writeFileSync(state, JSON.stringify({ active: active + 1 }));
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 30);
      writeFileSync(state, JSON.stringify({ active: 0 }));
    });
  `;

  const children = [0, 1].map(() => spawn(process.execPath, [
    "--input-type=module",
    "-e",
    source,
    repoRoot,
    artifactId,
    projectRoot,
  ], { stdio: "ignore" }));
  const exitCodes = await Promise.all(children.map((child) => new Promise((resolve) => {
    child.once("close", resolve);
  })));

  assert.deepEqual(exitCodes, [0, 0]);
  assert.deepEqual(JSON.parse(readFileSync(path.join(repoRoot, "build", "critical-section.json"), "utf8")), {
    active: 0,
  });
  assert.equal(existsSync(lock), false);
});

test("concurrent processes reclaim an ownerless lock that is still younger than the grace period", async (t) => {
  const repoRoot = temporaryRepository(t);
  const targetPath = FLUTTER_TEST_TARGET;
  const artifactId = testArtifactId(targetPath);
  const record = path.join(repoRoot, "build", ".test-artifacts", artifactId);
  const lock = path.join(record, ".lock");
  // An ownerless lock whose mtime is fresh: the owner died between creating
  // the lock and writing owner.json. Contenders must spin until the lock
  // ages past the grace period, then reclaim it exactly once — previously the
  // reclaim claim lived inside the lock and refreshed its mtime on every
  // attempt, so this case livelocked forever.
  mkdirSync(lock, { recursive: true });

  const source = String.raw`
    import { existsSync, readFileSync, writeFileSync } from "node:fs";
    import path from "node:path";
    import { pathToFileURL } from "node:url";
    const root = process.argv[1];
    const id = process.argv[2];
    const sourceRoot = process.argv[3];
    const deadLeaseGraceMs = Number(process.argv[4]);
    const { artifactRecordPaths, withArtifactLock } = await import(
      pathToFileURL(path.join(sourceRoot, "tools/scripts/lib/test-artifact-lifecycle/registry.mjs"))
    );
    const state = path.join(root, "build", "critical-section.json");
    withArtifactLock(artifactRecordPaths(root, id), () => {
      const active = existsSync(state) ? JSON.parse(readFileSync(state, "utf8")).active : 0;
      if (active !== 0) process.exitCode = 4;
      writeFileSync(state, JSON.stringify({ active: active + 1 }));
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 30);
      writeFileSync(state, JSON.stringify({ active: 0 }));
    }, { deadLeaseGraceMs });
  `;

  const children = [0, 1].map(() => spawn(process.execPath, [
    "--input-type=module",
    "-e",
    source,
    repoRoot,
    artifactId,
    projectRoot,
    "2000",
  ], { stdio: "ignore" }));
  const exitCodes = await Promise.all(children.map((child) => new Promise((resolve) => {
    child.once("close", resolve);
  })));

  assert.deepEqual(exitCodes, [0, 0]);
  assert.deepEqual(JSON.parse(readFileSync(path.join(repoRoot, "build", "critical-section.json"), "utf8")), {
    active: 0,
  });
  assert.equal(existsSync(lock), false);
});

test("tampered descriptors and unmanaged targets fail closed", (t) => {
  const repoRoot = temporaryRepository(t);
  const targetPath = FLUTTER_TEST_TARGET;
  const protectedFile = materialize(repoRoot, `${targetPath}/test/client.dill`);
  const unmanagedFile = materialize(repoRoot, "build/agents/old-target/test/client");
  const lease = acquireTestArtifactLease({ repoRoot, scope: "flutter", targetPath });
  lease.release();
  const descriptorPath = path.join(
    repoRoot,
    "build",
    ".test-artifacts",
    testArtifactId(targetPath),
    "descriptor.json",
  );
  const descriptor = JSON.parse(readFileSync(descriptorPath, "utf8"));
  descriptor.relativeTarget = `${FLUTTER_TEST_TARGET}/other`;
  writeFileSync(descriptorPath, `${JSON.stringify(descriptor)}\n`);

  const result = pruneReclaimableTestArtifacts({ repoRoot });
  assert.equal(result.failed, 1);
  assert.equal(result.unmanaged, 1);
  assert.equal(result.removed, 0);
  assert.equal(existsSync(protectedFile), true);
  assert.equal(existsSync(unmanagedFile), true);
});

test("outside, download-cache, registry, and symlink targets are rejected", (t) => {
  const repoRoot = temporaryRepository(t);
  assert.throws(() => acquireTestArtifactLease({
    repoRoot,
    scope: "outside",
    targetPath: "../outside",
  }), /inside/u);
  assert.throws(() => acquireTestArtifactLease({
    repoRoot,
    scope: "unmanaged-root",
    targetPath: "build/out",
  }), /managed build output/u);
  assert.throws(() => acquireTestArtifactLease({
    repoRoot,
    scope: "download-cache",
    targetPath: `${FLUTTER_TEST_TARGET}/registry`,
  }), /download caches/u);
  assert.throws(() => acquireTestArtifactLease({
    repoRoot,
    scope: "registry",
    targetPath: "build/.test-artifacts/forged",
  }), /managed build output/u);

  if (process.platform !== "win32") {
    const outside = path.join(repoRoot, "outside");
    mkdirSync(outside);
    const flutterBuild = path.join(repoRoot, "apps", "desktop", "build");
    mkdirSync(flutterBuild, { recursive: true });
    symlinkSync(outside, path.join(flutterBuild, "linked-target"));
    assert.throws(() => acquireTestArtifactLease({
      repoRoot,
      scope: "symlink",
      targetPath: `${FLUTTER_TEST_TARGET}/linked-target`,
    }), /symbolic links/u);
  }
});

test("repository scripts never invoke a bare Cargo toolchain", () => {
  const packageJson = JSON.parse(readFileSync(path.join(projectRoot, "package.json"), "utf8"));
  assert.equal(
    Object.entries(packageJson.scripts).filter(([, command]) =>
      /(?:^|&&|\|)\s*cargo\s+(?:build|clippy|run|test)\b/u.test(command)).length,
    0,
  );
  assert.equal(
    packageJson.scripts["client:artifacts:status"],
    "node tools/scripts/client-test-artifacts.mjs status",
  );
  assert.equal(
    packageJson.scripts["client:artifacts:prune"],
    "node tools/scripts/client-test-artifacts.mjs prune",
  );
  assert.equal(
    packageJson.scripts["client:artifacts:inventory"],
    "node tools/scripts/client-test-artifacts.mjs inventory",
  );
  assert.equal(
    packageJson.scripts["client:artifacts:workspace-complete"],
    "node tools/scripts/client-test-artifacts.mjs workspace-complete",
  );
});

test("inventory finds unregistered build output without scanning deliverables", (t) => {
  const repoRoot = temporaryRepository(t);
  const compiledFile = materialize(
    repoRoot,
    `${FLUTTER_TEST_TARGET}/test/client.dill`,
    "compiler output",
  );
  materialize(repoRoot, "build/out/package.tar", "deliverable");
  const inventory = inventoryTestArtifacts({
    repoRoot,
    processSnapshot: { available: true, entries: [] },
  });
  assert.deepEqual(inventory.entries.map((entry) => entry.relativeTarget), [
    FLUTTER_TEST_TARGET,
  ]);
  assert.equal(inventory.entries[0].bytes, Buffer.byteLength("compiler output"));
  assert.equal(inventory.entries[0].state, "reclaimable");
  assert.equal(typeof inventory.entries[0].lastUsedAt, "string");
  assert.deepEqual(inventory.entries[0].protectedReasons, []);
  assert.equal(existsSync(compiledFile), true);
});

test("targeted dry-run is read-only and targeted prune only removes the selected output", (t) => {
  const repoRoot = temporaryRepository(t);
  const selected = materialize(repoRoot, `${FLUTTER_TEST_TARGET}/test/client.dill`);
  const deliverable = materialize(repoRoot, "build/out/package.tar", "package");
  const options = {
    processSnapshot: { available: true, entries: [] },
    repoRoot,
    targetPath: FLUTTER_TEST_TARGET,
  };
  const dryRun = pruneTestArtifactTarget({ ...options, dryRun: true });
  const inventory = inventoryTestArtifacts(options).entries[0];
  assert.equal(inventory.reclaimableBytes, Buffer.byteLength("compiled"));
  assert.equal(dryRun.eligible, 1);
  assert.equal(dryRun.removed, false);
  assert.equal(existsSync(selected), true);
  assert.equal(existsSync(path.join(repoRoot, "build", ".test-artifacts")), false);

  const pruned = pruneTestArtifactTarget(options);
  assert.equal(pruned.removed, true);
  assert.equal(pruned.removedCount, 1);
  assert.equal(pruned.bytesAfter, 0);
  assert.equal(existsSync(selected), false);
  assert.equal(existsSync(path.dirname(selected)), false);
  assert.equal(existsSync(deliverable), true);
});

test("tracked source inside a managed output root is protected", (t) => {
  const repoRoot = temporaryRepository(t);
  const source = materialize(
    repoRoot,
    `${FLUTTER_TEST_TARGET}/kept-source.dart`,
    "source",
  );
  execFileSync("git", ["-C", repoRoot, "add", "--", `${FLUTTER_TEST_TARGET}/kept-source.dart`]);
  const result = pruneTestArtifactTarget({
    processSnapshot: { available: true, entries: [] },
    repoRoot,
    targetPath: FLUTTER_TEST_TARGET,
  });
  assert.equal(result.removed, false);
  assert.equal(result.protectedReasons.includes("tracked-source"), true);
  assert.equal(existsSync(source), true);
});

test("workspace completion prunes the managed output and protects active builds and binaries", (t) => {
  const repoRoot = temporaryRepository(t);
  const compiled = materialize(repoRoot, `${FLUTTER_TEST_TARGET}/test/client.dill`);
  const deliverable = materialize(repoRoot, "build/out/package.bin", "deliverable");
  const activeBuild = completeTestArtifactWorkspace({
    processSnapshot: {
      available: true,
      entries: [{
        pid: 4242,
        path: "/usr/bin/flutter",
        cwd: repoRoot,
        command: "flutter",
      }],
    },
    repoRoot,
  });
  assert.equal(activeBuild.removed, false);
  assert.equal(activeBuild.active, 1);
  assert.equal(activeBuild.protectedReasons.includes("active-build"), true);
  assert.equal(existsSync(compiled), true);
  assert.equal(existsSync(deliverable), true);

  const activeBinary = pruneTestArtifactTarget({
    processSnapshot: {
      available: true,
      entries: [{ pid: 4243, path: compiled, command: "client" }],
    },
    repoRoot,
    targetPath: FLUTTER_TEST_TARGET,
  });
  assert.equal(activeBinary.removed, false);
  assert.deepEqual(activeBinary.protectedReasons, ["running-binary"]);
  assert.equal(existsSync(compiled), true);

  const completed = completeTestArtifactWorkspace({
    processSnapshot: { available: true, entries: [] },
    repoRoot,
  });
  assert.equal(completed.removed, true);
  assert.equal(completed.removedCount, 1);
  assert.deepEqual(completed.relativeTargets, [FLUTTER_TEST_TARGET]);
  assert.equal(existsSync(compiled), false);
  assert.equal(existsSync(deliverable), true);
});

test("process probes protect managed output while a build tool references it", (t) => {
  const repoRoot = temporaryRepository(t);
  const targetPath = path.join(repoRoot, ...FLUTTER_TEST_TARGET.split("/"));
  const flutter = targetProcessUsage(targetPath, {
    available: true,
    entries: [{
      pid: 4244,
      path: "/usr/bin/flutter",
      cwd: os.tmpdir(),
      command: "flutter",
      arguments: ["build", "macos", "--build-dir", targetPath],
    }],
  }, repoRoot);
  assert.deepEqual(flutter.buildPids, [4244]);

  const unrelated = targetProcessUsage(targetPath, {
    available: true,
    entries: [{
      pid: 4245,
      path: "/usr/bin/vim",
      cwd: repoRoot,
      command: "vim",
      arguments: ["notes.txt"],
    }],
  }, repoRoot);
  assert.deepEqual(unrelated.buildPids, []);
});

test("artifact CLI parses checkout-scoped inventory and maintenance commands", () => {
  assert.deepEqual(parseArtifactCommand(["prune", "--dry-run"]), {
    command: "prune",
    dryRun: true,
    repoRoot: null,
    targetPath: null,
  });
  assert.equal(parseArtifactCommand(["prune", "--repo-root", "/checkout"]), null);
  assert.deepEqual(parseArtifactCommand(["inventory", "--repo-root", "/checkout"]), {
    command: "inventory",
    dryRun: false,
    repoRoot: "/checkout",
    targetPath: null,
  });
  assert.deepEqual(parseArtifactCommand([
    "prune",
    "--target",
    FLUTTER_TEST_TARGET,
    "--dry-run",
  ]), {
    command: "prune",
    dryRun: true,
    repoRoot: null,
    targetPath: FLUTTER_TEST_TARGET,
  });
  assert.equal(parseArtifactCommand(["workspace-complete", "--target", "target"]), null);
});

test("artifact CLI dispatches one checkout and reports only relative targets", (t) => {
  const repoRoot = temporaryRepository(t);
  const compiled = materialize(repoRoot, `${FLUTTER_TEST_TARGET}/test/client.dill`);
  const inventory = runArtifactCommand(parseArtifactCommand([
    "inventory",
    "--repo-root",
    repoRoot,
  ]), { currentRepoRoot: repoRoot });
  assert.equal(inventory.ok, true);
  assert.equal(inventory.operation, "inventory");
  assert.deepEqual(inventory.entries.map((entry) => entry.relativeTarget), [
    FLUTTER_TEST_TARGET,
  ]);
  assert.equal(JSON.stringify(inventory).includes(repoRoot), false);

  const preview = runArtifactCommand(parseArtifactCommand(["prune", "--dry-run"]), {
    currentRepoRoot: repoRoot,
  });
  assert.equal(preview.ok, true);
  assert.equal(preview.operation, "prune-dry-run");
  assert.equal(existsSync(compiled), true);

  const completed = runArtifactCommand(parseArtifactCommand([
    "workspace-complete",
    "--repo-root",
    repoRoot,
  ]), { currentRepoRoot: repoRoot });
  assert.equal(completed.ok, true);
  assert.equal(completed.removed, true);
  assert.deepEqual(completed.relativeTargets, [FLUTTER_TEST_TARGET]);
  assert.equal(existsSync(compiled), false);
  assert.equal(JSON.stringify(completed).includes(repoRoot), false);
});

test("Linux /proc enumeration skips EACCES, EPERM, and ENOENT entries while preserving accessible processes", () => {
  const makeError = (code) => Object.assign(new Error(code), { code });
  const fakeDirent = (name, isDir = true) => ({ name, isDirectory: () => isDir });
  const entries = processEntriesLinux({
    procRoot: "/proc",
    readDir: () => [
      fakeDirent("1"),
      fakeDirent("2"),
      fakeDirent("3"),
      fakeDirent("self", true),
      fakeDirent("42"),
    ],
    readLink: (target) => {
      if (target === "/proc/1/exe") throw makeError("EACCES");
      if (target === "/proc/2/exe") throw makeError("EPERM");
      if (target === "/proc/3/exe") throw makeError("ENOENT");
      if (target === "/proc/42/cwd") throw makeError("EACCES");
      if (target === "/proc/42/exe") return "/usr/bin/node";
      throw new Error(`unexpected readLink target: ${target}`);
    },
    readText: (target) => {
      if (target === "/proc/42/comm") return "node\n";
      if (target === "/proc/42/cmdline") return "node\0--test\0";
      throw new Error(`unexpected readText target: ${target}`);
    },
  });
  assert.deepEqual(entries, [
    {
      pid: 42,
      path: "/usr/bin/node",
      paths: ["/usr/bin/node"],
      cwd: "",
      command: "node",
      arguments: ["node", "--test"],
    },
  ]);

  assert.throws(
    () => processEntriesLinux({
      procRoot: "/proc",
      readDir: () => [fakeDirent("9")],
      readLink: () => {
        throw makeError("EIO");
      },
    }),
    /EIO/u,
  );
});
