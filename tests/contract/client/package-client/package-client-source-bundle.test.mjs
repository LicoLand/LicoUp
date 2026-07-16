import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../../..",
);
const facadeRef = "apps/desktop/scripts/package-client.mjs";
const moduleRoot = "apps/desktop/scripts/package-client";
const leaves = Object.freeze([
  "build/flutter.mjs",
  "build/native.mjs",
  "build/swift.mjs",
  "bundle-resolver/linux.mjs",
  "bundle-resolver/macos.mjs",
  "bundle-resolver/windows.mjs",
  "cli-policy.mjs",
  "config-codec.mjs",
  "macos/install.mjs",
  "macos/metadata.mjs",
  "macos/signing.mjs",
  "module-selection.mjs",
  "orchestrator.mjs",
  "portable-manifest.mjs",
  "process-runner.mjs",
  "pub-cache.mjs",
  "resource-assembly.mjs",
  "source-staging.mjs",
  "windows-manifest.mjs",
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

test("package client facade preserves exactly the six existing named exports", async () => {
  const module = await import(
    `${pathToFileURL(path.join(repoRoot, facadeRef)).href}?source-bundle`
  );
  assert.deepEqual(Object.keys(module).sort(), [
    "assertReleaseSourceDigestStable",
    "diffReleaseSourceManifests",
    "packageClient",
    "packageSourceStateBinding",
    "validatePackagingConfig",
    "validateReleaseBuildPolicy",
  ]);
  const facade = await read(facadeRef);
  assert.ok(facade.trimEnd().split(/\r?\n/u).length <= 30);
  assert.equal(facade.includes("execFileSync"), false);
  assert.equal(facade.includes("readFileSync"), false);
  assert.equal(facade.includes("function packageClient("), false);
});

test("package client migration owns exactly nineteen bounded ordinary modules", async () => {
  assert.deepEqual(await collectModules(moduleRoot), [...leaves]);
  const source = await sources();
  const limits = new Map([
    ["build/flutter.mjs", 270],
    ["build/native.mjs", 90],
    ["build/swift.mjs", 70],
    ["bundle-resolver/linux.mjs", 70],
    ["bundle-resolver/macos.mjs", 70],
    ["bundle-resolver/windows.mjs", 70],
    ["cli-policy.mjs", 320],
    ["config-codec.mjs", 340],
    ["macos/install.mjs", 160],
    ["macos/metadata.mjs", 80],
    ["macos/signing.mjs", 220],
    ["module-selection.mjs", 100],
    ["orchestrator.mjs", 220],
    ["portable-manifest.mjs", 320],
    ["process-runner.mjs", 140],
    ["pub-cache.mjs", 170],
    ["resource-assembly.mjs", 230],
    ["source-staging.mjs", 180],
    ["windows-manifest.mjs", 100],
  ]);
  for (const [leaf, maxLines] of limits) {
    assert.ok(
      source[leaf].trimEnd().split(/\r?\n/u).length <= maxLines,
      `${leaf} is oversized`,
    );
    assert.equal(source[leaf].includes("../package-client.mjs"), false);
  }
  assert.equal(findImportCycle(source), null);
});

test("config, selection, source state, runtime, and signing each have one authority", async () => {
  const source = await sources();
  assert.deepEqual(declarationOwners(source, "validatePackagingConfig"), [
    "config-codec.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "selectPackagingModules"), [
    "module-selection.mjs",
  ]);
  for (const name of [
    "assertReleaseSourceDigestStable",
    "diffReleaseSourceManifests",
    "packageSourceStateBinding",
    "captureReleaseSourceState",
    "assertReleaseSourceStateStable",
  ]) {
    assert.deepEqual(declarationOwners(source, name), ["portable-manifest.mjs"]);
  }
  assert.deepEqual(declarationOwners(source, "runtimeDataPolicyRecord"), [
    "cli-policy.mjs",
  ]);
  assert.deepEqual(declarationOwners(source, "packageSigningPolicyRecord"), [
    "macos/signing.mjs",
  ]);
});

test("subprocess failures expose only stable code and stage", async () => {
  const runner = await read(`${moduleRoot}/process-runner.mjs`);
  assert.ok(runner.includes("packageFailure(failureCode, { stage:"));
  for (const forbidden of [
    "console.error",
    "error.stdout",
    "error.stderr",
    "error.message",
    "slice(-4000)",
  ]) {
    assert.equal(runner.includes(forbidden), false, forbidden);
  }
  const facade = await read(facadeRef);
  assert.ok(facade.includes("publicPackageFailure(error)"));
  assert.equal(facade.includes("error.message"), false);
});

test("dry-run is pure planning and never enters build preflight", async () => {
  const { packageClient } = await import(
    `${pathToFileURL(path.join(repoRoot, moduleRoot, "orchestrator.mjs")).href}?dry-run`
  );
  let preflightCalls = 0;
  let plan = null;
  const result = packageClient(
    ["--platform", "linux", "--mode", "release", "--dry-run"],
    {
      emit: (value) => {
        plan = value;
      },
      preflight: () => {
        preflightCalls += 1;
      },
    },
  );
  assert.equal(result, null);
  assert.equal(preflightCalls, 0);
  assert.equal(plan?.ok, true);
  assert.equal(plan?.platform, "linux");

  const orchestrator = await read(`${moduleRoot}/orchestrator.mjs`);
  assert.ok(
    orchestrator.indexOf("if (options.dryRun)") <
      orchestrator.indexOf("preflight(options)"),
  );
  assert.equal(
    [...orchestrator.matchAll(/\bpreflight\(options\)/gu)].length,
    1,
  );
});

test("build, bundle, manifest, and macOS concerns retain dedicated owners", async () => {
  const source = await sources();
  const ownership = new Map([
    ["build/native.mjs", ["buildNativeSidecars", "cargoTargetDir"]],
    ["build/swift.mjs", ["buildSwiftSidecars"]],
    ["build/flutter.mjs", ["buildFlutterApp", "assertFlutterBuildPrereqs"]],
    ["bundle-resolver/linux.mjs", ["findLinuxBundleSource"]],
    ["bundle-resolver/macos.mjs", ["findMacosBundleSource"]],
    ["bundle-resolver/windows.mjs", ["findWindowsBundleSource"]],
    ["resource-assembly.mjs", ["assemblePackageResources"]],
    ["portable-manifest.mjs", ["preparePortableManifest"]],
    ["windows-manifest.mjs", ["writeWindowsPlatformManifest"]],
    ["macos/metadata.mjs", ["updateMacosAppMetadata"]],
    ["macos/signing.mjs", ["signMacosBundle"]],
    ["macos/install.mjs", ["installRunnableClient"]],
  ]);
  for (const [leaf, functions] of ownership) {
    for (const name of functions) {
      assert.ok(source[leaf].includes(`function ${name}(`), `${leaf}: ${name}`);
    }
  }
});

async function collectModules(relativeRoot) {
  const found = [];
  async function visit(relativeDirectory, prefix = "") {
    const entries = await fs.readdir(
      path.join(repoRoot, relativeDirectory),
      { withFileTypes: true },
    );
    for (const entry of entries) {
      const childPrefix = prefix ? `${prefix}/${entry.name}` : entry.name;
      const childDirectory = `${relativeDirectory}/${entry.name}`;
      if (entry.isDirectory()) await visit(childDirectory, childPrefix);
      else if (entry.isFile() && entry.name.endsWith(".mjs")) {
        found.push(childPrefix);
      }
    }
  }
  await visit(relativeRoot);
  return found.sort();
}

function declarationOwners(source, name) {
  const pattern = new RegExp(`function\\s+${name}\\s*\\(`, "u");
  return Object.entries(source)
    .filter(([, value]) => pattern.test(value))
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
  function visit(node) {
    if (visiting.has(node)) return node;
    if (visited.has(node)) return null;
    visiting.add(node);
    for (const dependency of graph.get(node) || []) {
      const cycle = visit(dependency);
      if (cycle) return cycle;
    }
    visiting.delete(node);
    visited.add(node);
    return null;
  }
  for (const node of graph.keys()) {
    const cycle = visit(node);
    if (cycle) return cycle;
  }
  return null;
}
