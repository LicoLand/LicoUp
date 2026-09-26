import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

import {
  buildInstallLock,
  checkLockStructure,
  verifyByteAttribution,
  verifyInstallLock,
} from "../../../tools/distribution/catalog/lib/lock.mjs";
import { fixtureDistribution, fixtureGraph, sha256HexOfFile, tempDir, writeFiles } from "./fixtures.mjs";

const BUILD_SCHEMA = "licoup.distribution-build.v1";
const ARTIFACT_FILES = Object.freeze({
  "packages/core/bin/host": "core host bytes\n",
  "packages/core/lib/core.dat": "core data\n",
  "packages/optional/bin/agent": "agent bytes\n",
});

function artifactTree(directory, extra = {}) {
  writeFiles(directory, { ...ARTIFACT_FILES, ...extra });
}

function buildResult(graph, overrides = {}) {
  return {
    schema: BUILD_SCHEMA,
    graph_digest: graph.graphDigest,
    source_revision: "0".repeat(40),
    packages: [
      { id: "org.test.core", version: "0.3.0", root: "packages/core", artifacts: [{ path: "bin/host" }, { path: "lib/core.dat" }] },
      { id: "org.test.optional", version: "1.0.0", root: "packages/optional", artifacts: [{ path: "bin/agent" }] },
    ],
    ...overrides,
  };
}

test("the lock records the bytes and digests of the real files", async (t) => {
  const graph = fixtureGraph();
  const root = tempDir(t);
  artifactTree(root);
  const lock = await buildInstallLock({ graph, build: buildResult(graph), artifactsRoot: root });

  const coreBytes = fs.statSync(path.join(root, "packages/core/bin/host")).size
    + fs.statSync(path.join(root, "packages/core/lib/core.dat")).size;
  const core = lock.packages["org.test.core"];
  assert.equal(core.bytes, coreBytes);
  assert.equal(core.artifacts[1].sha256, sha256HexOfFile(path.join(root, "packages/core/lib/core.dat")));
  assert.match(core.declaration_digest, /^[0-9a-f]{64}$/u);
  assert.deepEqual(lock.profiles.minimal.closure, ["org.test.core"]);
  assert.equal(lock.profiles.minimal.bytes, coreBytes);
  assert.equal(lock.profiles.full.bytes, coreBytes + lock.packages["org.test.optional"].bytes);
  assert.deepEqual(lock.profiles.full.delivery_tasks, ["T01", "T02"]);
  assert.equal(lock.tasks.T01.fingerprint, graph.taskFingerprint("T01"));
  assert.equal(checkLockStructure(lock).ok, true, "a freshly built lock is structurally valid");
});

test("the lock is byte-for-byte reproducible from the same inputs", async (t) => {
  const graph = fixtureGraph();
  const root = tempDir(t);
  artifactTree(root);
  const first = await buildInstallLock({ graph, build: buildResult(graph), artifactsRoot: root });
  const second = await buildInstallLock({ graph, build: buildResult(graph), artifactsRoot: root });
  assert.equal(JSON.stringify(second), JSON.stringify(first));
});

test("a fabricated or malformed build fact is refused", async (t) => {
  const graph = fixtureGraph();
  const root = tempDir(t);
  artifactTree(root);
  const build = (overrides) => buildResult(graph, overrides);
  const withCoreArtifact = (artifact) => build({
    packages: [
      { id: "org.test.core", version: "0.3.0", root: "packages/core", artifacts: [artifact] },
      { id: "org.test.optional", version: "1.0.0", root: "packages/optional", artifacts: [{ path: "bin/agent" }] },
    ],
  });

  await assert.rejects(
    buildInstallLock({ graph, build: withCoreArtifact({ path: "bin/host", sha256: "0".repeat(64) }), artifactsRoot: root }),
    /does not match the file/u,
  );
  await assert.rejects(
    buildInstallLock({ graph, build: withCoreArtifact({ path: "bin/host", bytes: 1 }), artifactsRoot: root }),
    /but the file is/u,
  );
  await assert.rejects(
    buildInstallLock({ graph, build: withCoreArtifact({ path: "bin/absent" }), artifactsRoot: root }),
    /is missing/u,
  );
  await assert.rejects(
    buildInstallLock({ graph, build: withCoreArtifact({ path: "bin/host", digest: "x" }), artifactsRoot: root }),
    /unknown field/u,
  );
  await assert.rejects(
    buildInstallLock({ graph, build: build({ graph_digest: "f".repeat(64) }), artifactsRoot: root }),
    /produced from graph/u,
  );
  await assert.rejects(
    buildInstallLock({ graph, build: build({
      packages: [
        { id: "org.test.absent", version: "1.0.0", root: "packages/absent", artifacts: [{ path: "bin/agent" }] },
      ],
    }), artifactsRoot: root }),
    /outside the distribution graph/u,
  );
  await assert.rejects(
    buildInstallLock({ graph, build: build({
      packages: [
        { id: "org.test.core", version: "0.3.0", root: "packages/core", artifacts: [{ path: "../outside" }] },
      ],
    }), artifactsRoot: root }),
    /relative segments/u,
  );
  await assert.rejects(
    buildInstallLock({ graph, build: build({
      packages: [
        { id: "org.test.core", version: "0.3.0", root: "packages/core", artifacts: [{ path: "bin/host" }, { path: "bin/host" }] },
      ],
    }), artifactsRoot: root }),
    /two artifacts/u,
  );

  const nestedRoot = tempDir(t);
  artifactTree(nestedRoot, { "packages/core/sub/bin/agent": "nested\n" });
  await assert.rejects(
    buildInstallLock({ graph, build: build({
      packages: [
        { id: "org.test.core", version: "0.3.0", root: "packages/core", artifacts: [{ path: "bin/host" }] },
        { id: "org.test.optional", version: "1.0.0", root: "packages/core/sub", artifacts: [{ path: "bin/agent" }] },
      ],
    }), artifactsRoot: nestedRoot }),
    /overlap/u,
  );
});

test("a symlinked artifact is refused rather than followed", async (t) => {
  const graph = fixtureGraph();
  const root = tempDir(t);
  artifactTree(root);
  try {
    fs.symlinkSync(path.join(root, "packages/core/bin/host"), path.join(root, "packages/core/bin/link"));
  } catch (error) {
    t.skip(`this environment cannot create symlinks: ${error.code}`);
    return;
  }
  const build = buildResult(graph, {
    packages: [
      { id: "org.test.core", version: "0.3.0", root: "packages/core", artifacts: [{ path: "bin/link" }] },
    ],
  });
  await assert.rejects(
    buildInstallLock({ graph, build, artifactsRoot: root }),
    /not a regular file/u,
  );
});

test("a profile whose closure is not built refuses the lock", async (t) => {
  const graph = fixtureGraph();
  const root = tempDir(t);
  artifactTree(root);
  const build = buildResult(graph, {
    packages: [
      { id: "org.test.core", version: "0.3.0", root: "packages/core", artifacts: [{ path: "bin/host" }] },
    ],
  });
  await assert.rejects(
    buildInstallLock({ graph, build, artifactsRoot: root }),
    /cannot be installed/u,
  );
});

test("byte attribution reports drift and unattributed files without rewriting the lock", async (t) => {
  const graph = fixtureGraph();
  const root = tempDir(t);
  artifactTree(root);
  const lock = await buildInstallLock({ graph, build: buildResult(graph), artifactsRoot: root });
  const snapshot = JSON.stringify(lock);

  const clean = await verifyByteAttribution({ lock, artifactsRoot: root });
  assert.equal(clean.ok, true);
  assert.equal(clean.totals.bytes, lock.packages["org.test.core"].bytes + lock.packages["org.test.optional"].bytes);

  fs.appendFileSync(path.join(root, "packages/core/lib/core.dat"), "tampered");
  const drifted = await verifyByteAttribution({ lock, artifactsRoot: root });
  assert.equal(drifted.ok, false);
  const codes = drifted.issues.map((issue) => issue.code);
  assert.ok(codes.includes("artifact_bytes_changed"));
  assert.ok(codes.includes("artifact_digest_changed"));

  fs.rmSync(path.join(root, "packages/optional/bin/agent"));
  const missing = await verifyByteAttribution({ lock, artifactsRoot: root });
  assert.ok(missing.issues.some((issue) => issue.code === "artifact_missing"));

  const strayRoot = tempDir(t);
  artifactTree(strayRoot, { "packages/optional/bin/stray.txt": "not declared\n" });
  const strayLock = await buildInstallLock({ graph, build: buildResult(graph), artifactsRoot: strayRoot });
  const stray = await verifyByteAttribution({ lock: strayLock, artifactsRoot: strayRoot });
  const warn = stray.issues.find((issue) => issue.code === "unattributed_file");
  assert.ok(warn, "an undeclared file must be reported");
  assert.equal(warn.package, "org.test.optional");
  assert.equal(stray.ok, true, "a warning is not an error by default");
  const strict = await verifyByteAttribution({ lock: strayLock, artifactsRoot: strayRoot, strict: true });
  assert.equal(strict.ok, false);
  assert.equal(JSON.stringify(lock), snapshot, "verification never edits the lock");
});

test("lock verification reports graph drift, stale declarations and stale task fingerprints", async (t) => {
  const graph = fixtureGraph();
  const root = tempDir(t);
  artifactTree(root);
  const lock = await buildInstallLock({ graph, build: buildResult(graph), artifactsRoot: root });

  const clean = await verifyInstallLock({ graph, lock, artifactsRoot: root });
  assert.equal(clean.ok, true);
  assert.ok(clean.tasks.every((task) => task.fingerprint_matches));

  const mutated = fixtureGraph({
    distribution: fixtureDistribution({
      packages: fixtureDistribution().packages.map((pkg) =>
        pkg.id === "org.test.core" ? { ...pkg, provides: [...pkg.provides, "core.extra.v1"] } : pkg),
    }),
  });
  const drifted = await verifyInstallLock({ graph: mutated, lock, artifactsRoot: root });
  assert.equal(drifted.ok, false);
  const codes = drifted.issues.map((issue) => issue.code);
  assert.ok(codes.includes("graph_digest_changed"));
  assert.ok(codes.includes("package_declaration_changed"));
  assert.ok(codes.includes("task_fingerprint_changed"));
  assert.ok(drifted.tasks.some((task) => task.id === "T01" && task.fingerprint_matches === false));

  const withoutBytes = await verifyInstallLock({ graph, lock });
  assert.equal(withoutBytes.ok, true, "without an artifacts root only declarations are compared");
  assert.equal(withoutBytes.attribution, null);
});

test("a tampered lock is reported as malformed rather than interpreted", async (t) => {
  const graph = fixtureGraph();
  const root = tempDir(t);
  artifactTree(root);
  const lock = await buildInstallLock({ graph, build: buildResult(graph), artifactsRoot: root });

  const rewritten = structuredClone(lock);
  rewritten.lock_digest = "0".repeat(64);
  assert.equal(checkLockStructure(rewritten).ok, false);
  assert.ok(checkLockStructure(rewritten).issues.some((issue) => /lock_digest/u.test(issue.detail)));

  const inflated = structuredClone(lock);
  inflated.packages["org.test.core"].bytes += 1;
  const structure = checkLockStructure(inflated);
  assert.equal(structure.ok, false);
  assert.ok(structure.issues.some((issue) => /sum of its artifacts/u.test(issue.detail)));

  const withoutTasks = structuredClone(lock);
  delete withoutTasks.tasks;
  assert.equal(checkLockStructure(withoutTasks).ok, false);
  const verified = await verifyInstallLock({ graph, lock: withoutTasks, artifactsRoot: root });
  assert.equal(verified.ok, false, "a malformed lock is reported, not thrown");
  assert.ok(verified.issues.some((issue) => issue.code === "lock_malformed"));
});
