import assert from "node:assert/strict";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  acquireTestArtifactLease,
  pruneReclaimableTestArtifacts,
  testArtifactId,
  testArtifactStatus,
} from "./test-artifact-lifecycle.mjs";

const projectRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));

function temporaryRepository(t) {
  const repoRoot = mkdtempSync(path.join(os.tmpdir(), "licoup-artifact-test-"));
  mkdirSync(path.join(repoRoot, "build"), { recursive: true });
  t.after(() => rmSync(repoRoot, { force: true, recursive: true }));
  return repoRoot;
}

function materialize(repoRoot, relativePath, contents = "compiled") {
  const target = path.join(repoRoot, ...relativePath.split("/"));
  mkdirSync(path.dirname(target), { recursive: true });
  writeFileSync(target, contents);
  return target;
}

test("active compiler output is protected and released output is reclaimable", (t) => {
  const repoRoot = temporaryRepository(t);
  const targetPath = "build/native/target";
  const compiledFile = materialize(repoRoot, `${targetPath}/debug/client`);
  const dependencyCache = materialize(repoRoot, "build/dependency-downloads/crate.cache");
  const lease = acquireTestArtifactLease({
    repoRoot,
    scope: "native-test",
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
  assert.equal(existsSync(dependencyCache), true);
  assert.equal(testArtifactStatus({ repoRoot }).cleaned, 1);
});

test("all concurrent leases must finish before output becomes reclaimable", (t) => {
  const repoRoot = temporaryRepository(t);
  const targetPath = "build/native/target";
  materialize(repoRoot, `${targetPath}/debug/client`);
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
  const targetPath = "build/native/target";
  const compiledFile = materialize(repoRoot, `${targetPath}/debug/client`);
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

test("tampered descriptors and unmanaged targets fail closed", (t) => {
  const repoRoot = temporaryRepository(t);
  const targetPath = "build/native/target";
  const protectedFile = materialize(repoRoot, `${targetPath}/debug/client`);
  const unmanagedFile = materialize(repoRoot, "build/agents/old-target/debug/client");
  const lease = acquireTestArtifactLease({ repoRoot, scope: "native", targetPath });
  lease.release();
  const descriptorPath = path.join(
    repoRoot,
    "build",
    ".test-artifacts",
    testArtifactId(targetPath),
    "descriptor.json",
  );
  const descriptor = JSON.parse(readFileSync(descriptorPath, "utf8"));
  descriptor.relativeTarget = "build/other-target";
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
    scope: "download-cache",
    targetPath: "build/pub-cache",
  }), /download caches/u);
  assert.throws(() => acquireTestArtifactLease({
    repoRoot,
    scope: "registry",
    targetPath: "build/.test-artifacts/forged",
  }), /managed build output/u);

  if (process.platform !== "win32") {
    const outside = path.join(repoRoot, "outside");
    mkdirSync(outside);
    symlinkSync(outside, path.join(repoRoot, "build", "linked"));
    assert.throws(() => acquireTestArtifactLease({
      repoRoot,
      scope: "symlink",
      targetPath: "build/linked/target",
    }), /symbolic links/u);
  }
});

test("repository build-producing Cargo scripts use the lifecycle wrapper", () => {
  const packageJson = JSON.parse(readFileSync(path.join(projectRoot, "package.json"), "utf8"));
  const cargoConfig = readFileSync(path.join(projectRoot, ".cargo", "config.toml"), "utf8");
  const androidBuild = readFileSync(
    path.join(projectRoot, "apps", "desktop", "android", "app", "build.gradle.kts"),
    "utf8",
  );
  const macosProject = readFileSync(
    path.join(projectRoot, "apps", "desktop", "macos", "Runner.xcodeproj", "project.pbxproj"),
    "utf8",
  );
  const packageNativeBuild = readFileSync(
    path.join(projectRoot, "apps", "desktop", "scripts", "package-client", "build", "native.mjs"),
    "utf8",
  );
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
  assert.match(cargoConfig, /target-dir = "build\/crates\/licoup-native\/target"/u);
  assert.match(
    androidBuild,
    /repoRoot\.resolve\("build\/crates\/licoup-native\/target"\)/u,
  );
  assert.match(androidBuild, /tools\/scripts\/cargo-client\.mjs/u);
  assert.doesNotMatch(androidBuild, /commandLine\(\s*"cargo"/u);
  assert.doesNotMatch(androidBuild, /android-target/u);
  assert.match(macosProject, /tools\/scripts\/cargo-client\.mjs/u);
  assert.doesNotMatch(macosProject, /CARGO_TARGET_DIR=.*cargo build/u);
  assert.match(packageNativeBuild, /cargo-client\.mjs/u);
  assert.doesNotMatch(packageNativeBuild, /runPackageProcess\("cargo"/u);
});
