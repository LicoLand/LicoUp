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
const facadeRef = "tools/scripts/client-cli-vm.mjs";
const moduleRoot = "tools/scripts/client-cli-vm";
const leaves = Object.freeze([
  "cli.mjs",
  "constants.mjs",
  "distro/select.mjs",
  "image/disk.mjs",
  "image/download.mjs",
  "image/seed.mjs",
  "linux-product/artifacts.mjs",
  "linux-product/bootstrap.mjs",
  "linux-product/command.mjs",
  "linux-product/incomplete.mjs",
  "linux-product/run.mjs",
  "linux-product/shell-helpers.mjs",
  "linux-product/source-manifest.mjs",
  "linux-product/toolchain.mjs",
  "linux-product/validate.mjs",
  "list.mjs",
  "paths.mjs",
  "process.mjs",
  "run.mjs",
  "self-test/runner.mjs",
  "ssh/key.mjs",
  "ssh/session.mjs",
  "sync/artifacts.mjs",
  "sync/repo.mjs",
  "verify/bootstrap.mjs",
  "verify/command.mjs",
  "verify/distro.mjs",
  "vm/lifecycle.mjs",
  "vm/prepare.mjs",
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

test("client CLI VM facade is a thin serial CLI entry", async () => {
  const facade = await read(facadeRef);
  assert.ok(facade.trimEnd().split(/\r?\n/u).length <= 15);
  assert.match(facade, /from "\.\/client-cli-vm\/run\.mjs"/u);
  assert.equal(facade.includes("function "), false);
  assert.equal(facade.includes("class "), false);
  assert.equal(facade.includes("spawnSync"), false);
  assert.equal(facade.includes("readFileSync"), false);
  const module = await import(
    `${pathToFileURL(path.join(repoRoot, moduleRoot, "run.mjs")).href}?source-bundle`
  );
  assert.equal(typeof module.main, "function");
});

test("client CLI VM owns exactly twenty-nine bounded ordinary modules", async () => {
  assert.deepEqual(await collectModules(moduleRoot), [...leaves]);
  const source = await sources();
  const limits = new Map([
    ["cli.mjs", 70],
    ["constants.mjs", 50],
    ["distro/select.mjs", 50],
    ["image/disk.mjs", 40],
    ["image/download.mjs", 70],
    ["image/seed.mjs", 70],
    ["linux-product/artifacts.mjs", 50],
    ["linux-product/bootstrap.mjs", 60],
    ["linux-product/command.mjs", 120],
    ["linux-product/incomplete.mjs", 60],
    ["linux-product/run.mjs", 160],
    ["linux-product/shell-helpers.mjs", 50],
    ["linux-product/source-manifest.mjs", 80],
    ["linux-product/toolchain.mjs", 50],
    ["linux-product/validate.mjs", 170],
    ["list.mjs", 50],
    ["paths.mjs", 60],
    ["process.mjs", 50],
    ["run.mjs", 100],
    ["self-test/runner.mjs", 220],
    ["ssh/key.mjs", 40],
    ["ssh/session.mjs", 50],
    ["sync/artifacts.mjs", 40],
    ["sync/repo.mjs", 40],
    ["verify/bootstrap.mjs", 60],
    ["verify/command.mjs", 80],
    ["verify/distro.mjs", 40],
    ["vm/lifecycle.mjs", 140],
    ["vm/prepare.mjs", 30],
  ]);
  for (const [leaf, maxLines] of limits) {
    assert.ok(
      source[leaf].trimEnd().split(/\r?\n/u).length <= maxLines,
      `${leaf} is oversized`,
    );
    assert.equal(source[leaf].includes("../client-cli-vm.mjs"), false);
  }
  assert.equal(findImportCycle(source), null);
});

test("cli, verify, linux-product, and self-test each have one authority", async () => {
  const source = await sources();
  assert.deepEqual(declarationOwners(source, "parseArgs"), ["cli.mjs"]);
  assert.deepEqual(declarationOwners(source, "main"), ["run.mjs"]);
  assert.deepEqual(declarationOwners(source, "verifyCommand"), [
    "verify/command.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "verifyDistro"), [
    "verify/distro.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "linuxProductCommand"), [
    "linux-product/command.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "verifyLinuxProductDistro"), [
    "linux-product/run.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "runScriptSelfTest"), [
    "self-test/runner.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "printList"), ["list.mjs"]);
});

test("self-test dry-run preserves fail-closed contracts", () => {
  const result = spawnSync(
    process.execPath,
    [path.join(repoRoot, facadeRef), "self-test"],
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
  assert.equal(payload.schemaVersion, "licomesh.client-cli-vm.self-test.v1");
  assert.equal(payload.runtimeDataIncluded, false);
});
