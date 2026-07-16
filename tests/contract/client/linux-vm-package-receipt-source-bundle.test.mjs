import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);
const facadeRef = "tools/scripts/client-secure-mesh-linux-vm-package-receipt.mjs";
const moduleRoot = "tools/scripts/client-secure-mesh-linux-vm-package-receipt";
const leaves = Object.freeze([
  "cli.mjs",
  "gui.mjs",
  "receipt.mjs",
  "report.mjs",
  "run.mjs",
  "util.mjs",
]);

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
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

test("linux vm package receipt facade is a thin serial CLI entry", async () => {
  const facade = await read(facadeRef);
  assert.ok(facade.trimEnd().split(/\r?\n/u).length <= 12);
  assert.equal(facade.includes("spawnSync"), false);
  assert.equal(facade.includes("readFileSync"), false);
  const module = await import(
    `${pathToFileURL(path.join(repoRoot, moduleRoot, "run.mjs")).href}?source-bundle`
  );
  assert.equal(typeof module.main, "function");
});

test("linux vm package receipt owns exactly six bounded ordinary modules", async () => {
  assert.deepEqual(await collectModules(moduleRoot), [...leaves]);
  const limits = new Map([
    ["cli.mjs", 40],
    ["gui.mjs", 120],
    ["receipt.mjs", 290],
    ["report.mjs", 80],
    ["run.mjs", 100],
    ["util.mjs", 90],
  ]);
  for (const [leaf, maxLines] of limits) {
    const source = await read(`${moduleRoot}/${leaf}`);
    assert.ok(
      source.trimEnd().split(/\r?\n/u).length <= maxLines,
      `${leaf} is oversized`,
    );
    assert.equal(source.includes("../client-secure-mesh-linux-vm-package-receipt.mjs"), false);
  }
});
