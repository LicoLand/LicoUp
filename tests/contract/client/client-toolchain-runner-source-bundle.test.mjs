import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);
const facadeRef = "tools/scripts/client-toolchain-runner.mjs";
const moduleRoot = "tools/scripts/client-toolchain-runner";
const leaves = Object.freeze([
  "artifacts.mjs",
  "cli.mjs",
  "constants.mjs",
  "flutter.mjs",
  "process.mjs",
  "pub-cache.mjs",
  "run.mjs",
  "windows.mjs",
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

test("client toolchain runner facade is a thin serial CLI entry", async () => {
  const facade = await read(facadeRef);
  assert.ok(facade.trimEnd().split(/\r?\n/u).length <= 12);
  const module = await import(
    `${pathToFileURL(path.join(repoRoot, moduleRoot, "run.mjs")).href}?source-bundle`
  );
  assert.equal(typeof module.main, "function");
});

test("client toolchain runner owns exactly eight bounded ordinary modules", async () => {
  assert.deepEqual(await collectModules(moduleRoot), [...leaves]);
  const limits = new Map([
    ["artifacts.mjs", 80],
    ["cli.mjs", 50],
    ["constants.mjs", 20],
    ["flutter.mjs", 200],
    ["process.mjs", 90],
    ["pub-cache.mjs", 220],
    ["run.mjs", 30],
    ["windows.mjs", 80],
  ]);
  for (const [leaf, maxLines] of limits) {
    const source = await read(`${moduleRoot}/${leaf}`);
    assert.ok(
      source.trimEnd().split(/\r?\n/u).length <= maxLines,
      `${leaf} is oversized`,
    );
    assert.equal(source.includes("../client-toolchain-runner.mjs"), false);
  }
});

test("build-producing tests lease only compiler outputs", async () => {
  const module = await import(
    `${pathToFileURL(path.join(repoRoot, moduleRoot, "artifacts.mjs")).href}?artifact-targets`
  );
  assert.deepEqual(module.toolchainTestArtifactTargets({
    command: "flutter",
    args: ["test", "test/widget_test.dart"],
    cwd: path.join(repoRoot, "apps/desktop"),
  }), ["apps/desktop/build"]);
  assert.deepEqual(module.toolchainTestArtifactTargets({
    command: "./gradlew",
    args: [":app:testDebugUnitTest"],
    cwd: path.join(repoRoot, "apps/desktop/android"),
  }), [
    "apps/desktop/build",
    "build/crates/licoup-native/android-target",
  ]);
  assert.deepEqual(module.toolchainTestArtifactTargets({
    command: "./gradlew",
    args: [":app:compileDebugKotlin"],
    cwd: path.join(repoRoot, "apps/desktop/android"),
  }), [
    "apps/desktop/build",
    "build/crates/licoup-native/android-target",
  ]);
  assert.deepEqual(module.toolchainTestArtifactTargets({
    command: "flutter",
    args: ["pub", "get", "--offline"],
    cwd: path.join(repoRoot, "apps/desktop"),
  }), []);
});

test("toolchain artifact leases release on command failure", async () => {
  const module = await import(
    `${pathToFileURL(path.join(repoRoot, moduleRoot, "artifacts.mjs")).href}?artifact-release`
  );
  let releases = 0;
  await assert.rejects(() => module.withToolchainTestArtifactLeases({
    command: "flutter",
    args: ["test"],
    cwd: path.join(repoRoot, "apps/desktop"),
    leaseFactory() {
      return { release() { releases += 1; } };
    },
  }, async () => { throw new Error("synthetic tool failure"); }), /synthetic tool failure/u);
  assert.equal(releases, 1);
});

test("Windows command resolution prefers executable tools and handles command wrappers", async () => {
  const module = await import(
    `${pathToFileURL(path.join(repoRoot, moduleRoot, "windows.mjs")).href}?windows-behavior`
  );
  const flutterBase = ["C:", "tools", "flutter"].join("/");
  const flutterCommand = `${flutterBase}.cmd`;
  const flutterExecutable = `${flutterBase}.exe`;
  const located = module.resolveCommand("flutter", {
    platform: "win32",
    locate: () => ({
      status: 0,
      stdout: `${flutterCommand}\r\n${flutterExecutable}\r\n`,
    }),
  });
  assert.equal(located, flutterExecutable);
  assert.equal(module.quoteWindowsCommandArg("two words"), '"two words"');
  assert.equal(
    module.resolveCommand(flutterBase, {
      platform: "win32",
      fileExists: (candidate) => candidate.endsWith(".cmd"),
    }),
    flutterCommand,
  );
});
