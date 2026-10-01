// Local release fixture for the on-demand migration tool asset.
//
// The fixture proves the release pipeline produces the standalone native migration tool
// beside the client assets, with the same artifact digest metadata every other release
// artifact carries, and that no client bundle gains a migrator. It runs entirely on
// synthetic bytes in the disposable build tree: no signing material is read, nothing is
// uploaded and no release is published.
//
// One test converts a staged-tool-oriented fixture through the real platform release
// builder and the real release-package staging command. The rest are contract checks on
// the declarations and the unbundled build stage. The synthetic old-root inspection that
// acceptance also names is covered by the standalone migration suites
// (`tools/scripts/migration-crate-tests.mjs`), which convert the frozen released root
// and assert the source is unchanged.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { buildReleaseTools, releaseToolsDirectory } from
  "../../../apps/desktop/scripts/package-client/build/release-tools.mjs";
import {
  loadClientReleaseTargetCatalog,
  resolveClientReleaseTarget,
} from "../../../tools/scripts/lib/client-release-targets.mjs";
import { sha256File } from "../../../tools/scripts/lib/client-release-artifact-digest.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const catalogPath = path.join(repoRoot, "tools/client-release-targets.json");
const builderScript = "apps/desktop/scripts/build-platform-release-package.mjs";
const stagingScript = "tools/scripts/client-release-packages.mjs";
const migrationToolAsset = "LicoUp-migrate-macos-arm64";
const migrationToolDigest = `${migrationToolAsset}.sha256`;
const productVersion = JSON.parse(
  readFileSync(path.join(repoRoot, "tools/client-version.json"), "utf8"),
).productVersion;

function readCatalogDocument() {
  return JSON.parse(readFileSync(catalogPath, "utf8"));
}

function resolvedMacosTarget() {
  const catalog = loadClientReleaseTargetCatalog(catalogPath);
  return resolveClientReleaseTarget(
    catalog.targets.find((target) => target.id === "macos-direct-arm64"),
    productVersion,
  );
}

function run(script, args) {
  return spawnSync(process.execPath, [script, ...args], {
    cwd: repoRoot,
    env: process.env,
    encoding: "utf8",
    shell: false,
    stdio: "pipe",
    timeout: 120_000,
    maxBuffer: 8 * 1024 * 1024,
  });
}

function hexDigest(filePath) {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex");
}

test("the release catalog declares the standalone tool with digest metadata", () => {
  const document = readCatalogDocument();
  const artifacts = document.targets.find((target) =>
    target.id === "macos-direct-arm64").artifacts;
  const tool = artifacts.find((artifact) => artifact.role === "migration-tool");
  assert.deepEqual(tool, {
    role: "migration-tool",
    file: migrationToolAsset,
    source: `build/apps/desktop/native-release/macos-direct-arm64/${migrationToolAsset}`,
  });
  const checksum = artifacts.find((artifact) => artifact.file === migrationToolDigest);
  assert.deepEqual(checksum, {
    role: "checksum",
    file: migrationToolDigest,
    for: "migration-tool",
  });
  // The tool belongs to the client release tag, not to a bundle: its declared source is
  // outside every runnable/bundle root, and no other target redeclares it.
  assert.equal(tool.source.includes("/runnable/"), false);
  assert.equal(tool.source.includes("LicoUp.app"), false);
  for (const target of document.targets) {
    const roles = target.artifacts.map((artifact) => artifact.role);
    assert.equal(
      roles.includes("migration-tool"),
      target.id === "macos-direct-arm64",
      `${target.id} must not carry a migrator`,
    );
  }
});

test("the platform fixture stages the tool with checksum metadata and no bundle", (t) => {
  if (process.platform !== "darwin" || process.arch !== "arm64") {
    t.skip("the macOS direct release fixture runs on its owning host only");
    return;
  }
  const releaseDirectory = path.join(
    repoRoot,
    "build", "releases", productVersion, "macos-direct-arm64",
  );
  if (existsSync(releaseDirectory)) {
    t.skip("a real release package directory already exists and is never overwritten");
    return;
  }
  const syntheticCandidates = {
    installer: path.join(repoRoot, "build/apps/desktop/distribution/macos/LicoUp-macos-arm64.dmg"),
    update: path.join(repoRoot, "build/apps/desktop/distribution/macos/LicoUp-macos-arm64-update.zip"),
    "migration-tool": path.join(
      repoRoot,
      releaseToolsDirectory("macos"),
      migrationToolAsset,
    ),
  };
  const generated = [
    ...Object.values(syntheticCandidates),
    path.join(repoRoot, "build/apps/desktop/native-release/macos-direct-arm64"),
    releaseDirectory,
  ];
  try {
    mkdirSync(path.dirname(syntheticCandidates.installer), { recursive: true });
    writeFileSync(syntheticCandidates.installer, "synthetic installer payload\n");
    writeFileSync(syntheticCandidates.update, "synthetic update payload\n");
    mkdirSync(path.dirname(syntheticCandidates["migration-tool"]), { recursive: true });
    writeFileSync(
      syntheticCandidates["migration-tool"],
      "synthetic migration tool payload\n",
    );

    const built = run(builderScript, ["--target", "macos-direct-arm64"]);
    assert.equal(built.status, 0, built.stderr);
    const builtRecord = JSON.parse(built.stdout);
    assert.ok(
      builtRecord.outputSources.includes(
        `build/apps/desktop/native-release/macos-direct-arm64/${migrationToolAsset}`,
      ),
      "the builder materializes the tool from its unbundled build output",
    );

    const staged = run(stagingScript, ["stage", "--target", "macos-direct-arm64"]);
    assert.equal(staged.status, 0, staged.stderr);

    const stagedTool = path.join(releaseDirectory, migrationToolAsset);
    const stagedDigest = path.join(releaseDirectory, migrationToolDigest);
    assert.equal(readFileSync(stagedTool, "utf8"), "synthetic migration tool payload\n");
    assert.equal(
      readFileSync(stagedDigest, "utf8"),
      `${hexDigest(stagedTool)}  ${migrationToolAsset}\n`,
      "the checksum file binds the staged tool's own bytes",
    );

    const packageManifest = JSON.parse(readFileSync(
      path.join(releaseDirectory, "LicoUp-macos-direct-arm64.package.json"),
      "utf8",
    ));
    const toolRecord = packageManifest.artifacts.find((artifact) =>
      artifact.role === "migration-tool");
    assert.deepEqual(toolRecord, {
      role: "migration-tool",
      file: migrationToolAsset,
      byteSize: readFileSync(stagedTool).length,
      sha256: sha256File(stagedTool),
    });
    assert.equal(
      packageManifest.artifacts.find((artifact) => artifact.file === migrationToolDigest)?.for,
      "migration-tool",
    );

    const buildManifest = JSON.parse(readFileSync(
      path.join(repoRoot, "build/apps/desktop/native-release/macos-direct-arm64/LicoUp-macos-arm64.build.json"),
      "utf8",
    ));
    assert.ok(buildManifest.artifacts.some((artifact) =>
      artifact.role === "migration-tool" && artifact.sha256 === sha256File(stagedTool)));

    // No client bundle was produced or touched by this fixture.
    assert.equal(existsSync(path.join(repoRoot, "build/apps/desktop/runnable")), false);
  } finally {
    for (const target of generated.reverse()) {
      rmSync(target, { recursive: true, force: true });
    }
  }
});

test("the client bundle selection never carries a migrator", () => {
  const packagingModules = readFileSync(
    path.join(repoRoot, "apps/desktop/packaging.modules.json"),
    "utf8",
  );
  assert.equal(packagingModules.includes("licoup-migrate"), false);
  assert.equal(packagingModules.includes(migrationToolAsset), false);
  const declaredSource = resolvedMacosTarget().artifacts.find((artifact) =>
    artifact.role === "migration-tool").source;
  assert.ok(declaredSource.startsWith("build/apps/desktop/native-release/"));
  assert.equal(declaredSource.includes("/runnable/"), false);
  assert.equal(declaredSource.includes("LicoUp.app"), false);
});

test("the release tool build stage is unbundled and identity-bound", () => {
  const calls = [];
  const copied = [];
  const staged = buildReleaseTools(
    { mode: "release", platform: "macos" },
    {
      runProcess: (command, args, options) => calls.push({ command, args, options }),
      copy: (source, destination) => copied.push({ source, destination }),
      mkdir: () => undefined,
    },
  );
  assert.equal(calls.length, 1);
  assert.equal(calls[0].command, process.execPath);
  assert.ok(calls[0].args[0].endsWith(path.join("tools", "scripts", "cargo-client.mjs")));
  assert.deepEqual(
    calls[0].args.slice(1, 6),
    ["build", "--manifest-path", path.join("crates", "licoup-migrate", "Cargo.toml"), "--release", "--locked"],
  );
  assert.deepEqual(calls[0].args.slice(6), ["--bin", "licoup-migrate"]);
  assert.equal(
    calls[0].options.env.LICO_CLIENT_PRODUCT_VERSION,
    productVersion,
    "the tool embeds the same product identity as the client build",
  );
  assert.equal(copied.length, 1);
  assert.ok(staged.endsWith(path.join("release-tools", "macos", migrationToolAsset)));
  assert.equal(staged.includes(`${path.sep}runnable${path.sep}`), false);
  assert.equal(
    copied[0].source,
    path.join(repoRoot, "build", "crates", "licoup-native", "target", "release", "licoup-migrate"),
  );

  for (const options of [
    { mode: "release", platform: "macos", dryRun: true },
    { mode: "release", platform: "macos", skipNativeBuild: true },
    { mode: "debug", platform: "macos" },
    { mode: "release", platform: "windows" },
  ]) {
    let invoked = 0;
    assert.equal(
      buildReleaseTools(options, {
        runProcess: () => { invoked += 1; },
        copy: () => { invoked += 1; },
        mkdir: () => { invoked += 1; },
      }),
      null,
    );
    assert.equal(invoked, 0, "a non-release or non-macOS build produces no asset");
  }
});

test("the release catalog keeps the asset and the guidance names it", () => {
  // The in-repo release configuration that produces the asset is the target catalog;
  // uploading it to the GitHub release remains a centrally authorized publication step.
  const stagedRoles = resolvedMacosTarget().artifacts.map((artifact) => artifact.role);
  assert.ok(stagedRoles.includes("migration-tool"));

  const guide = readFileSync(
    path.join(repoRoot, "docs/architecture/CLIENT-UPDATE-AND-STATE-MIGRATION.md"),
    "utf8",
  );
  for (const fact of [
    migrationToolAsset,
    "downloaded on demand",
    "runs offline",
    "bundled migrator",
  ]) {
    assert.ok(guide.includes(fact), `the guide states ${JSON.stringify(fact)}`);
  }
  const translation = readFileSync(
    path.join(repoRoot, "docs/architecture/CLIENT-UPDATE-AND-STATE-MIGRATION.zh-CN.md"),
    "utf8",
  );
  assert.ok(translation.includes(migrationToolAsset));
});
