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
  copyFileSync,
  cpSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import {
  buildReleaseTools,
  releaseToolsDirectory,
  selectReleaseToolDescriptor,
} from
  "../../../apps/desktop/scripts/package-client/build/release-tools.mjs";
import {
  loadClientReleaseTargetCatalog,
  resolveClientReleaseTarget,
} from "../../../tools/scripts/lib/client-release-targets.mjs";
import { sha256File } from "../../../tools/scripts/lib/client-release-artifact-digest.mjs";
import { encodedRustFlagsWithPathRemap } from
  "../../../apps/desktop/scripts/package-client/build/native.mjs";

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

function run(root, script, args) {
  return spawnSync(process.execPath, [script, ...args], {
    cwd: root,
    env: process.env,
    encoding: "utf8",
    shell: false,
    stdio: "pipe",
    timeout: 120_000,
    maxBuffer: 8 * 1024 * 1024,
  });
}

// Execute unmodified producers and their real relative imports in an owned
// workspace. No fixed checkout build path is used, even for a refusal fixture.
function arrangeWorkspace(root) {
  const document = readCatalogDocument();
  const sources = new Set([
    builderScript, stagingScript,
    "Cargo.toml", "Cargo.lock", "package.json", "package-lock.json",
    "tools/client-version.json", "tools/client-release-targets.json",
    "tools/scripts/lib/client-release-artifact-digest.mjs",
    "tools/scripts/lib/client-source-state-digest.mjs",
    "tools/scripts/lib/client-release-targets.mjs",
    "tools/scripts/lib/project-temporary-directory-lifecycle.mjs",
    ...document.targets.flatMap((target) => target.builder.templates),
    ...document.targets.filter((target) => target.builder.program === "node")
      .map((target) => target.builder.args[0]),
  ]);
  for (const relative of sources) {
    const destination = path.join(root, relative);
    mkdirSync(path.dirname(destination), { recursive: true });
    copyFileSync(path.join(repoRoot, relative), destination);
  }
  const digestModules = "tools/scripts/lib/client-release-artifact-digest";
  cpSync(path.join(repoRoot, digestModules), path.join(root, digestModules), { recursive: true });
  for (const relative of ["crates", "packages/protocols"]) {
    mkdirSync(path.join(root, relative), { recursive: true });
  }
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
  const fixture = mkdtempSync(path.join(realpathSync(os.tmpdir()), "lico-migration-release-"));
  t.after(() => rmSync(fixture, { recursive: true, force: true }));
  arrangeWorkspace(fixture);
  const releaseDirectory = path.join(
    fixture,
    "build", "releases", productVersion, "macos-direct-arm64",
  );
  const syntheticCandidates = {
    installer: path.join(fixture, "build/apps/desktop/distribution/macos/LicoUp-macos-arm64.dmg"),
    update: path.join(fixture, "build/apps/desktop/distribution/macos/LicoUp-macos-arm64-update.zip"),
    "migration-tool": path.join(
      fixture,
      releaseToolsDirectory("macos"),
      migrationToolAsset,
    ),
  };
  mkdirSync(path.dirname(syntheticCandidates.installer), { recursive: true });
  writeFileSync(syntheticCandidates.installer, "synthetic installer payload\n");
  writeFileSync(syntheticCandidates.update, "synthetic update payload\n");
  mkdirSync(path.dirname(syntheticCandidates["migration-tool"]), { recursive: true });
  writeFileSync(
    syntheticCandidates["migration-tool"],
    "synthetic migration tool payload\n",
  );

  const built = run(fixture, builderScript, ["--target", "macos-direct-arm64"]);
  assert.equal(built.status, 0, built.stderr);
  const builtRecord = JSON.parse(built.stdout);
  assert.ok(
    builtRecord.outputSources.includes(
      `build/apps/desktop/native-release/macos-direct-arm64/${migrationToolAsset}`,
    ),
    "the builder materializes the tool from its unbundled build output",
  );

  const staged = run(fixture, stagingScript, ["stage", "--target", "macos-direct-arm64"]);
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
    path.join(fixture, "build/apps/desktop/native-release/macos-direct-arm64/LicoUp-macos-arm64.build.json"),
    "utf8",
  ));
  assert.ok(buildManifest.artifacts.some((artifact) =>
    artifact.role === "migration-tool" && artifact.sha256 === sha256File(stagedTool)));

  // No client bundle was produced or touched by this fixture.
  assert.equal(existsSync(path.join(fixture, "build/apps/desktop/runnable")), false);

  // Missing current producer output cannot fall through to an unrelated or
  // stale file with the right name. Previously staged release bytes survive.
  rmSync(syntheticCandidates["migration-tool"]);
  writeFileSync(path.join(fixture, migrationToolAsset), "stale root tool");
  writeFileSync(path.join(path.dirname(syntheticCandidates.installer), migrationToolAsset), "stale distribution tool");
  const refused = run(fixture, builderScript, ["--target", "macos-direct-arm64"]);
  assert.notEqual(refused.status, 0);
  assert.equal(JSON.parse(refused.stderr).code, "client_platform_release_artifact_missing");
  assert.equal(readFileSync(stagedTool, "utf8"), "synthetic migration tool payload\n");
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
  const descriptor = selectReleaseToolDescriptor("macos");
  const calls = [];
  const copied = [];
  const removed = [];
  const staged = buildReleaseTools(
    { mode: "release", platform: "macos" },
    descriptor,
    {
      runProcess: (command, args, options) => calls.push({ command, args, options }),
      copy: (source, destination) => copied.push({ source, destination }),
      mkdir: () => undefined,
      remove: (destination) => removed.push(destination),
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
  assert.deepEqual(removed, [staged], "a real attempt invalidates prior staged bytes");
  assert.equal(calls[0].options.env.CARGO_ENCODED_RUSTFLAGS, encodedRustFlagsWithPathRemap());
  assert.equal(Object.hasOwn(calls[0].options.env, "RUSTFLAGS"), false);
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
    const invalidated = [];
    const selectedDescriptor = options.platform === "macos" ? descriptor : null;
    assert.equal(
      buildReleaseTools(options, selectedDescriptor, {
        runProcess: () => { invoked += 1; },
        copy: () => { invoked += 1; },
        mkdir: () => { invoked += 1; },
        remove: (destination) => invalidated.push(destination),
      }),
      null,
    );
    assert.equal(invoked, 0, "a non-release or non-macOS build produces no asset");
    assert.deepEqual(invalidated, !options.dryRun && options.platform === "macos" ? [staged] : []);
  }
});

test("a failed tool build or partial copy cannot leave a publishable staged tool", () => {
  const descriptor = selectReleaseToolDescriptor("macos");
  for (const failure of ["build", "copy"]) {
    const removed = [];
    let copies = 0;
    assert.throws(() => buildReleaseTools(
      { mode: "release", platform: "macos" },
      descriptor,
      {
        runProcess: () => { if (failure === "build") throw new Error("synthetic build failure"); },
        copy: () => { copies += 1; throw new Error("synthetic copy failure"); },
        mkdir: () => undefined,
        remove: (destination) => removed.push(destination),
      },
    ), new RegExp(`synthetic ${failure} failure`, "u"));
    assert.equal(copies, failure === "copy" ? 1 : 0);
    assert.equal(removed.length, failure === "copy" ? 2 : 1);
    assert.ok(removed.every((destination) => destination === removed[0]));
  }
});

test("the target catalog selects release-tool capability and asset identity", () => {
  const catalog = readCatalogDocument();
  const macos = selectReleaseToolDescriptor("macos", catalog);
  assert.deepEqual(macos, {
    assetName: migrationToolAsset,
    platform: "macos",
    releaseSource:
      `build/apps/desktop/native-release/macos-direct-arm64/${migrationToolAsset}`,
    targetId: "macos-direct-arm64",
  });
  assert.equal(selectReleaseToolDescriptor("linux", catalog), null);
  assert.equal(selectReleaseToolDescriptor("windows", catalog), null);

  const renamed = structuredClone(catalog);
  const target = renamed.targets.find((candidate) =>
    candidate.id === "macos-direct-arm64");
  const tool = target.artifacts.find((artifact) =>
    artifact.role === "migration-tool");
  tool.file = "LicoUp-migrate-custom-arm64";
  tool.source =
    `build/apps/desktop/native-release/${target.id}/${tool.file}`;
  const renamedDescriptor = selectReleaseToolDescriptor("macos", renamed);
  const renamedStaged = buildReleaseTools(
    { mode: "release", platform: "macos" },
    renamedDescriptor,
    {
      runProcess: () => undefined,
      copy: () => undefined,
      mkdir: () => undefined,
      remove: () => undefined,
    },
  );
  assert.ok(
    renamedStaged.endsWith(path.join("release-tools", "macos", tool.file)),
    "the shared builder must not own platform asset names",
  );

  const mismatched = structuredClone(catalog);
  mismatched.targets.find((candidate) => candidate.id === "macos-direct-arm64")
    .artifacts.find((artifact) => artifact.role === "migration-tool").source =
      `build/apps/desktop/native-release/macos-app-store-arm64/${migrationToolAsset}`;
  assert.throws(
    () => selectReleaseToolDescriptor("macos", mismatched),
    /migration_tool_release_source_invalid/u,
  );
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
    assert.ok(guide.replace(/\s+/gu, " ").includes(fact), `the guide states ${JSON.stringify(fact)}`);
  }
  const translation = readFileSync(
    path.join(repoRoot, "docs/architecture/CLIENT-UPDATE-AND-STATE-MIGRATION.zh-CN.md"),
    "utf8",
  );
  assert.ok(translation.includes(migrationToolAsset));
});
