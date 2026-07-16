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
const facadeRef = "tools/scripts/client-release-acceptance.mjs";
const moduleRoot = "tools/scripts/client-release-acceptance";
const leaves = Object.freeze([
  "artifacts/android.mjs",
  "artifacts/digests.mjs",
  "artifacts/helpers.mjs",
  "artifacts/linux-signature.mjs",
  "artifacts/linux.mjs",
  "artifacts/macos.mjs",
  "artifacts/materialize.mjs",
  "artifacts/receipt.mjs",
  "artifacts/selected.mjs",
  "artifacts/stability.mjs",
  "cli.mjs",
  "constants.mjs",
  "evidence.mjs",
  "load-reports.mjs",
  "preflight.mjs",
  "privacy.mjs",
  "reduce.mjs",
  "refs.mjs",
  "report-deps.mjs",
  "run.mjs",
  "sanitize-binding.mjs",
  "self-test/fixtures.mjs",
  "self-test/runner.mjs",
  "support-matrix.mjs",
  "targets.mjs",
  "util.mjs",
  "validate-config.mjs",
  "validate-report.mjs",
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

test("client release acceptance facade is a thin serial CLI entry", async () => {
  const facade = await read(facadeRef);
  assert.ok(facade.trimEnd().split(/\r?\n/u).length <= 12);
  assert.match(facade, /runClientReleaseAcceptanceCli/u);
  assert.equal(facade.includes("function "), false);
  assert.equal(facade.includes("class "), false);
  assert.equal(facade.includes("spawn"), false);
  assert.equal(facade.includes("readFileSync"), false);
  const module = await import(
    `${pathToFileURL(path.join(repoRoot, moduleRoot, "run.mjs")).href}?source-bundle`
  );
  assert.equal(typeof module.runClientReleaseAcceptanceCli, "function");
});

test("client release acceptance owns exactly twenty-eight bounded ordinary modules", async () => {
  assert.deepEqual(await collectModules(moduleRoot), [...leaves]);
  const source = await sources();
  const limits = new Map([
    ["artifacts/android.mjs", 120],
    ["artifacts/digests.mjs", 130],
    ["artifacts/helpers.mjs", 40],
    ["artifacts/linux-signature.mjs", 60],
    ["artifacts/linux.mjs", 120],
    ["artifacts/macos.mjs", 170],
    ["artifacts/materialize.mjs", 200],
    ["artifacts/receipt.mjs", 80],
    ["artifacts/selected.mjs", 110],
    ["artifacts/stability.mjs", 30],
    ["cli.mjs", 30],
    ["constants.mjs", 30],
    ["evidence.mjs", 50],
    ["load-reports.mjs", 250],
    ["preflight.mjs", 90],
    ["privacy.mjs", 50],
    ["reduce.mjs", 200],
    ["refs.mjs", 50],
    ["report-deps.mjs", 50],
    ["run.mjs", 290],
    ["sanitize-binding.mjs", 50],
    ["self-test/fixtures.mjs", 230],
    ["self-test/runner.mjs", 540],
    ["support-matrix.mjs", 90],
    ["targets.mjs", 50],
    ["util.mjs", 50],
    ["validate-config.mjs", 130],
    ["validate-report.mjs", 100],
  ]);
  for (const [leaf, maxLines] of limits) {
    assert.ok(
      source[leaf].trimEnd().split(/\r?\n/u).length <= maxLines,
      `${leaf} is oversized`,
    );
    assert.equal(
      source[leaf].includes("../client-release-acceptance.mjs"),
      false,
    );
  }
  assert.equal(findImportCycle(source), null);
});

test("cli, reduce, artifacts, and self-test each have one authority", async () => {
  const source = await sources();
  assert.deepEqual(declarationOwners(source, "parseReleaseAcceptanceArgs"), [
    "cli.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "runClientReleaseAcceptanceCli"), [
    "run.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "reduceClientReleaseAcceptance"), [
    "reduce.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "runSelfTest"), [
    "self-test/runner.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "verifySelectedArtifacts"), [
    "artifacts/selected.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "validateConfig"), [
    "validate-config.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "runAndLoadApprovedReports"), [
    "load-reports.mjs",
  ]);
});

test("release acceptance self-test dry-run preserves fail-closed contracts", () => {
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
  assert.equal(payload.caseCount, 43);
});
