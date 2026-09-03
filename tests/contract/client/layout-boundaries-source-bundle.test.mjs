import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import { isAllowedLegacyLayoutDependency } from "../../../apps/desktop/scripts/verify-layout-boundaries/dependency-policy.mjs";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);
const facadeRef = "apps/desktop/scripts/verify-layout-boundaries.mjs";
const moduleRoot = "apps/desktop/scripts/verify-layout-boundaries";
const leaves = Object.freeze([
  "bundle-product.mjs",
  "cli.mjs",
  "config.mjs",
  "dart-source.mjs",
  "dependency-policy.mjs",
  "errors.mjs",
  "import-graph.mjs",
  "ownership.mjs",
  "paths.mjs",
  "state-authority.mjs",
  "surface-parse.mjs",
  "verify.mjs",
]);
const selfTestLeaves = Object.freeze([
  "self-test/cases/identity.mjs",
  "self-test/cases/imports.mjs",
  "self-test/cases/ports.mjs",
  "self-test/cases/product.mjs",
  "self-test/fixtures.mjs",
  "self-test/helpers.mjs",
  "self-test/run.mjs",
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

test("layout boundaries facade is a thin serial CLI entry", async () => {
  const facade = await read(facadeRef);
  assert.match(facade, /from "\.\/verify-layout-boundaries\/verify\.mjs"/u);
  assert.match(facade, /from "\.\/verify-layout-boundaries\/errors\.mjs"/u);
  assert.equal(facade.includes("function verifyLayoutBoundaries"), false);
  assert.equal(facade.includes("function discoverLayoutBundleProduct"), false);
  assert.equal(facade.includes("spawnSync"), false);
  const module = await import(
    `${pathToFileURL(path.join(repoRoot, moduleRoot, "cli.mjs")).href}?layout-boundaries-source-bundle`
  );
  assert.equal(typeof module.main, "function");
});

test("layout boundaries owns exactly twelve bounded ordinary modules", async () => {
  const discovered = await collectModules(moduleRoot);
  assert.deepEqual(
    discovered.filter((entry) => !entry.startsWith("self-test/")),
    [...leaves],
  );
  assert.deepEqual(
    discovered.filter((entry) => entry.startsWith("self-test/")),
    [...selfTestLeaves],
  );
  const source = await sources();
  for (const leaf of Object.keys(source)) {
    assert.equal(
      source[leaf].includes("../verify-layout-boundaries.mjs"),
      false,
    );
  }
  assert.equal(findImportCycle(source), null);
});

test("layout boundary self-test package stays thin with precise leaves", async () => {
  for (const leaf of selfTestLeaves) {
    await read(`${moduleRoot}/${leaf}`);
  }
  const facade = await read(
    "apps/desktop/scripts/verify-layout-boundaries-self-test.mjs",
  );
  assert.match(facade, /self-test\/run\.mjs/u);
});

test("verify, bundle-product, errors, and cli each have one authority", async () => {
  const source = await sources();
  assert.deepEqual(declarationOwners(source, "verifyLayoutBoundaries"), [
    "verify.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "discoverLayoutBundleProduct"), [
    "bundle-product.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "LayoutBoundaryError"), [
    "errors.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "main"), ["cli.mjs"]);
});

test("legacy shared layout debt is an exact shrink-only path set", () => {
  assert.equal(isAllowedLegacyLayoutDependency(
    "apps/desktop/lib/src/frontend/shared/appearance/appearance_preset_config.dart",
  ), true);
  assert.equal(isAllowedLegacyLayoutDependency(
    "apps/desktop/lib/src/frontend/shared/ui/theme.dart",
  ), true);
  assert.equal(isAllowedLegacyLayoutDependency(
    "apps/desktop/lib/src/frontend/shared/new_shared_dependency.dart",
  ), false);
  assert.equal(isAllowedLegacyLayoutDependency(
    "apps/desktop/lib/src/frontend/shared/ui/new_shared_widget.dart",
  ), false);
});

test("self-test dry-run preserves fail-closed layout boundary contracts", () => {
  const result = spawnSync(
    process.execPath,
    [path.join(repoRoot, facadeRef), "--self-test"],
    {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 4 * 1024 * 1024,
      timeout: 120_000,
    },
  );
  assert.equal(result.status, 0, result.stderr || result.stdout.slice(0, 400));
});
