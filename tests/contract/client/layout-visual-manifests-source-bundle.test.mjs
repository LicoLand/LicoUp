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
const facadeRef = "apps/desktop/scripts/verify-layout-visual-manifests.mjs";
const moduleRoot = "apps/desktop/scripts/verify-layout-visual-manifests";
const leaves = Object.freeze([
  "catalog.mjs",
  "check.mjs",
  "cli.mjs",
  "config.mjs",
  "errors.mjs",
  "generate.mjs",
  "manifest-codec.mjs",
  "owner-roots.mjs",
  "paths.mjs",
  "write.mjs",
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

test("layout visual manifests facade is a thin serial CLI entry", async () => {
  const facade = await read(facadeRef);
  assert.ok(facade.trimEnd().split(/\r?\n/u).length <= 40);
  assert.match(facade, /from "\.\/verify-layout-visual-manifests\/check\.mjs"/u);
  assert.match(facade, /from "\.\/verify-layout-visual-manifests\/errors\.mjs"/u);
  assert.equal(facade.includes("function generateLayoutVisualManifests"), false);
  assert.equal(facade.includes("function discoverLayoutCatalog"), false);
  assert.equal(facade.includes("spawnSync"), false);
  const module = await import(
    `${pathToFileURL(path.join(repoRoot, moduleRoot, "cli.mjs")).href}?layout-visual-manifests-source-bundle`
  );
  assert.equal(typeof module.main, "function");
});

test("layout visual manifests owns exactly ten bounded ordinary modules", async () => {
  assert.deepEqual(await collectModules(moduleRoot), [...leaves]);
  const source = await sources();
  const limits = new Map([
    ["catalog.mjs", 50],
    ["check.mjs", 80],
    ["cli.mjs", 50],
    ["config.mjs", 50],
    ["errors.mjs", 20],
    ["generate.mjs", 120],
    ["manifest-codec.mjs", 180],
    ["owner-roots.mjs", 260],
    ["paths.mjs", 90],
    ["write.mjs", 50],
  ]);
  for (const [leaf, maxLines] of limits) {
    assert.ok(
      source[leaf].trimEnd().split(/\r?\n/u).length <= maxLines,
      `${leaf} is oversized`,
    );
    assert.equal(
      source[leaf].includes("../verify-layout-visual-manifests.mjs"),
      false,
    );
  }
  assert.equal(findImportCycle(source), null);
});

test("generate, catalog, errors, and cli each have one authority", async () => {
  const source = await sources();
  assert.deepEqual(declarationOwners(source, "generateLayoutVisualManifests"), [
    "generate.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "discoverLayoutCatalog"), [
    "catalog.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "LayoutVisualManifestError"), [
    "errors.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "main"), ["cli.mjs"]);
});

test("self-test dry-run preserves fail-closed layout visual manifest contracts", () => {
  const result = spawnSync(
    process.execPath,
    [
      path.join(
        repoRoot,
        "apps/desktop/scripts/verify-layout-visual-manifests-self-test.mjs",
      ),
    ],
    {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 4 * 1024 * 1024,
      timeout: 120_000,
    },
  );
  assert.equal(result.status, 0, result.stderr || result.stdout.slice(0, 400));
});
