import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);
const facadeRef = "tools/scripts/client-android-physical-install-launch.mjs";
const moduleRoot = "tools/scripts/client-android-physical-install-launch";
const leaves = Object.freeze([
  "apk/inspect.mjs",
  "cli.mjs",
  "constants.mjs",
  "device/adb.mjs",
  "device/classify.mjs",
  "device/select.mjs",
  "operations/install.mjs",
  "operations/launch.mjs",
  "privacy/leak-scan.mjs",
  "privacy/sanitize.mjs",
  "report/blocked.mjs",
  "report/build.mjs",
  "run.mjs",
  "runtime/status.mjs",
  "self-test.mjs",
  "util/hash.mjs",
  "util/json.mjs",
  "util/paths.mjs",
  "version.mjs",
]);

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function sources() {
  return Object.fromEntries(
    await Promise.all(
      leaves.map(async (leaf) => [leaf, await read(`${moduleRoot}/${leaf}`)]),
    ),
  );
}

async function collectModules(relativeRoot) {
  const found = [];
  async function visit(relativeDirectory, prefix = "") {
    const entries = await fs.readdir(path.join(repoRoot, relativeDirectory), {
      withFileTypes: true,
    });
    for (const entry of entries) {
      const childPrefix = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) {
        await visit(`${relativeDirectory}/${entry.name}`, childPrefix);
      } else if (entry.isFile() && entry.name.endsWith(".mjs")) {
        found.push(childPrefix);
      }
    }
  }
  await visit(relativeRoot);
  return found.sort();
}

function declarationOwners(source, name) {
  const patterns = [
    new RegExp(`(?:export\\s+)?(?:async\\s+)?function\\s+${name}\\s*\\(`, "u"),
    new RegExp(`(?:export\\s+)?class\\s+${name}\\b`, "u"),
    new RegExp(`(?:export\\s+)?const\\s+${name}\\s*=`, "u"),
  ];
  return Object.entries(source)
    .filter(([, value]) => patterns.some((pattern) => pattern.test(value)))
    .map(([leaf]) => leaf)
    .sort();
}

function findImportCycle(source) {
  const graph = new Map();
  for (const [leaf, value] of Object.entries(source)) {
    const dependencies = [];
    for (const match of value.matchAll(/from\s+"(\.{1,2}\/[^"\n]+)"/gu)) {
      const resolved = path.posix.normalize(
        path.posix.join(path.posix.dirname(leaf), match[1]),
      );
      if (source[resolved]) dependencies.push(resolved);
    }
    graph.set(leaf, dependencies);
  }
  const visiting = new Set();
  const visited = new Set();
  let cycle = null;
  function dfs(node, stack) {
    if (visiting.has(node)) {
      cycle = [...stack, node];
      return true;
    }
    if (visited.has(node)) return false;
    visiting.add(node);
    stack.push(node);
    for (const next of graph.get(node) || []) {
      if (dfs(next, stack)) return true;
    }
    stack.pop();
    visiting.delete(node);
    visited.add(node);
    return false;
  }
  for (const node of graph.keys()) {
    if (dfs(node, [])) return cycle;
  }
  return null;
}

test("android physical install/launch facade is a thin serial CLI entry", async () => {
  const facade = await read(facadeRef);
  assert.ok(facade.trimEnd().split(/\r?\n/u).length <= 25);
  assert.match(facade, /from "\.\/client-android-physical-install-launch\/run\.mjs"/u);
  assert.equal(facade.includes("function runSelfTest"), false);
  assert.equal(facade.includes("function inspectApk"), false);
  assert.equal(facade.includes("spawnSync"), false);
  const module = await import(
    `${pathToFileURL(path.join(repoRoot, moduleRoot, "run.mjs")).href}?source-bundle`
  );
  assert.equal(typeof module.run, "function");
});

test("android physical install/launch owns exactly nineteen bounded ordinary modules", async () => {
  assert.deepEqual(await collectModules(moduleRoot), [...leaves]);
  const source = await sources();
  const limits = new Map([
    ["apk/inspect.mjs", 150],
    ["cli.mjs", 90],
    ["constants.mjs", 40],
    ["device/adb.mjs", 90],
    ["device/classify.mjs", 160],
    ["device/select.mjs", 50],
    ["operations/install.mjs", 120],
    ["operations/launch.mjs", 100],
    ["privacy/leak-scan.mjs", 50],
    ["privacy/sanitize.mjs", 30],
    ["report/blocked.mjs", 280],
    ["report/build.mjs", 280],
    ["run.mjs", 220],
    ["runtime/status.mjs", 360],
    ["self-test.mjs", 70],
    ["util/hash.mjs", 30],
    ["util/json.mjs", 20],
    ["util/paths.mjs", 50],
    ["version.mjs", 40],
  ]);
  for (const [leaf, maxLines] of limits) {
    assert.ok(
      source[leaf].trimEnd().split(/\r?\n/u).length <= maxLines,
      `${leaf} is oversized`,
    );
    assert.equal(
      source[leaf].includes("../client-android-physical-install-launch.mjs"),
      false,
    );
  }
  assert.equal(findImportCycle(source), null);
});

test("install, launch, report, and self-test each have one authority", async () => {
  const source = await sources();
  assert.deepEqual(declarationOwners(source, "inspectApk"), ["apk/inspect.mjs"]);
  assert.deepEqual(declarationOwners(source, "installApk"), ["operations/install.mjs"]);
  assert.deepEqual(declarationOwners(source, "launchApp"), ["operations/launch.mjs"]);
  assert.deepEqual(declarationOwners(source, "validateRuntimeStatus"), [
    "runtime/status.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "buildInstallLaunchReport"), [
    "report/build.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "writeBlockedReportIfPossible"), [
    "report/blocked.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "runSelfTest"), ["self-test.mjs"]);
  assert.deepEqual(declarationOwners(source, "run"), ["run.mjs"]);
  assert.deepEqual(declarationOwners(source, "pickDevice"), ["device/select.mjs"]);
});

test("self-test dry-run preserves fail-closed install/launch contracts", () => {
  const result = spawnSync(
    process.execPath,
    [path.join(repoRoot, facadeRef), "--self-test"],
    {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 4 * 1024 * 1024,
      timeout: 60_000,
    },
  );
  assert.equal(result.status, 0, result.stderr || result.stdout.slice(0, 400));
  const payload = JSON.parse(result.stdout);
  assert.equal(payload.ok, true);
  assert.equal(payload.mode, "self-test");
  assert.equal(payload.caseCount, 12);
  assert.equal(payload.privatePathsIncluded, false);
});
