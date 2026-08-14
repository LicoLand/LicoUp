import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import {
  loadClientReleaseTargetCatalog,
  parseClientReleaseTargetArgs,
  resolveClientReleaseTarget,
  selectClientReleaseTargets,
  validateClientReleaseTargetCatalog,
} from "../../../tools/scripts/lib/client-release-targets.mjs";
import {
  releaseWorkflowMatrix,
  validateReleaseWorkflowRequest,
} from "../../../tools/scripts/client-release-workflow-binding.mjs";
import {
  retireStaleReleasePackageDirectories,
} from "../../../tools/scripts/client-release-packages.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const script = "tools/scripts/client-release-packages.mjs";
const builderScript = "apps/desktop/scripts/build-platform-release-package.mjs";
const catalogPath = path.join(repoRoot, "tools/client-release-targets.json");
const productVersion = JSON.parse(readFileSync(
  path.join(repoRoot, "tools/client-version.json"), "utf8",
)).productVersion;

function currentHostId() {
  const platform = process.platform === "darwin" ? "darwin"
    : process.platform === "win32" ? "win32" : process.platform;
  const arch = process.arch === "arm64" ? "arm64"
    : process.arch === "x64" ? "x64" : process.arch;
  return `${platform}-${arch}`;
}

function wrongHostTarget() {
  const host = currentHostId();
  const target = readCatalogDocument().targets.find((candidate) =>
    !candidate.builder.hosts.includes(host));
  assert.ok(target, `fixture needs a target outside ${host}`);
  return target;
}

function readCatalogDocument() {
  return JSON.parse(readFileSync(catalogPath, "utf8"));
}

function invoke(args) {
  return spawnSync(process.execPath, [script, ...args], {
    cwd: repoRoot,
    env: { ...process.env, LICO_CLIENT_RELEASE_TARGETS: "" },
    encoding: "utf8",
    shell: false,
    stdio: "pipe",
    timeout: 30_000,
    maxBuffer: 4 * 1024 * 1024,
  });
}

test("release package catalog uses exact native package targets", () => {
  const document = readCatalogDocument();
  const catalog = loadClientReleaseTargetCatalog();
  assert.equal(document.schemaVersion, "licomesh.client-release-target-catalog.v4");
  assert.equal(document.outputLayout, "build/releases/{version}/{targetId}");
  assert.equal(document.targets.length, 17);

  const requiredFields = [
    "platform", "distributionFamily", "baseline", "packageFormat", "channel",
    "arch", "updateAuthority", "buildHost",
  ];
  for (const target of document.targets) {
    for (const field of requiredFields) {
      assert.equal(typeof target[field], "string", `${target.id} must declare ${field}`);
      assert.notEqual(target[field].trim(), "", `${target.id} has an empty ${field}`);
    }
    assert.match(target.baseline, /^[a-z0-9]+(?:[.-][a-z0-9]+)*$/u);
    assert.match(target.buildHost, /^(?:darwin|win32|linux)-(?:arm64|x64)$/u);
    assert.ok(target.builder.hosts.includes(target.buildHost),
      `${target.id} owning build host is not in its builder hosts`);
    assert.ok(Array.isArray(target.builder.templates),
      `${target.id} must preserve builder.templates`);
  }

  const familyByTarget = new Map(document.targets.map((target) => [target.id,
    target.distributionFamily]));
  assert.equal(familyByTarget.get("linux-deb-x64"), "debian");
  assert.equal(familyByTarget.get("linux-rpm-x64"), "rpm");
  assert.equal(familyByTarget.get("linux-pacman-x64"), "arch-linux");
  assert.equal(familyByTarget.get("linux-pacman-arm64"), "arch-linux-arm");
  assert.equal(familyByTarget.get("linux-alpine-apk-x64"), "alpine");
  assert.equal(familyByTarget.get("linux-appimage-x64"), "appimage");

  assert.ok(document.targets.some((target) => target.id === "macos-direct-arm64" &&
    target.packageFormat === "dmg" && target.update.kind === "signed-http-manifest" &&
    target.updateAuthority === "signed-http-manifest" && target.buildHost === "darwin-arm64" &&
    target.builder.args[0] === builderScript &&
    target.builder.args.slice(1).join(" ") === "--target macos-direct-arm64"));
  assert.ok(document.targets.some((target) => target.id === "android-play-arm64-v8a" &&
    target.packageFormat === "aab" && target.updateAuthority === "google-play"));
  assert.ok(document.targets.some((target) => target.id === "android-direct-arm64-v8a" &&
    target.packageFormat === "apk" && target.updateAuthority === "manual-download"));
  assert.ok(document.targets.some((target) => target.id === "linux-deb-arm64" &&
    target.packageFormat === "deb" && target.updateAuthority === "apt-repository"));
  assert.ok(document.targets.some((target) => target.id === "windows-direct-x64" &&
    target.packageFormat === "msix" && target.updateAuthority === "appinstaller"));
  assert.ok(document.targets.every((target) =>
    !["tar", "tar.gz", "zip"].includes(target.packageFormat)));
  assert.deepEqual(
    catalog.targets.map((target) => target.distributionFamily),
    document.targets.map((target) => target.distributionFamily),
  );
});

test("v4 release target schema rejects undeclared fields at every authority layer", () => {
  for (const mutate of [
    (catalog) => { catalog.compatibility = "legacy"; },
    (catalog) => { catalog.targets[0].supported = true; },
    (catalog) => { catalog.targets[0].builder.platform = "macos"; },
    (catalog) => { catalog.targets[0].artifacts[0].path = "ignored"; },
    (catalog) => { catalog.targets[0].update.channel = "stable"; },
  ]) {
    const candidate = structuredClone(readCatalogDocument());
    mutate(candidate);
    assert.throws(() => validateClientReleaseTargetCatalog(candidate), /schema is not exact/u);
  }
});

test("native recipes are explicit and remain separate from publication closure", () => {
  const document = readCatalogDocument();
  const recipeFiles = new Set();
  for (const target of document.targets) {
    for (const template of target.builder.templates || []) {
      recipeFiles.add(template);
      const recipePath = path.join(repoRoot, template);
      const info = lstatSync(recipePath);
      assert.ok(info.isFile() && !info.isSymbolicLink(), `${template} must be a regular file`);
    }
    assert.equal(target.packageBuildSupported, true);
    assert.equal(target.packageBlockers.length, 0,
      `${target.id} cannot be build-supported with package blockers`);
    assert.equal(target.builder.kind, "command");
    assert.equal(target.builder.program, "node");
    assert.equal(target.builder.args[0], builderScript);
    assert.deepEqual(target.builder.args.slice(1), ["--target", target.id]);
    assert.ok(target.artifacts.some((artifact) =>
      artifact.role === "build-manifest" && artifact.source));
    if (target.releaseSupported) {
      assert.equal(target.packageBuildSupported, true);
      assert.equal(target.releaseBlockers.length, 0);
    } else {
      assert.ok(target.releaseBlockers.length > 0,
        `${target.id} needs a typed publication/closure blocker`);
    }
  }
  assert.ok(recipeFiles.has("apps/desktop/packaging/linux/deb/control"));
  assert.ok(recipeFiles.has("apps/desktop/packaging/linux/rpm/licoup.spec"));
  assert.ok(recipeFiles.has("apps/desktop/packaging/linux/pacman/PKGBUILD"));
  assert.ok(recipeFiles.has("apps/desktop/packaging/linux/alpine/APKBUILD"));
  assert.ok(recipeFiles.has("apps/desktop/packaging/linux/appimage/AppRun"));
  assert.ok(recipeFiles.has("apps/desktop/packaging/windows/msix/AppxManifest.xml"));
  assert.ok(recipeFiles.has("apps/desktop/packaging/ios/ExportOptions-AppStore.plist"));
  assert.ok(existsSync(path.join(repoRoot, "apps/desktop/packaging/README.md")));
});

test("target parser accepts one, repeated, and comma-separated targets", () => {
  assert.deepEqual(
    [...parseClientReleaseTargetArgs(["--target", "macos-direct-arm64"]).targetIds],
    ["macos-direct-arm64"],
  );
  assert.deepEqual(
    [...parseClientReleaseTargetArgs([
      "--target", "macos-direct-arm64",
      "--targets", "android-direct-arm64-v8a,linux-deb-arm64",
    ]).targetIds],
    ["macos-direct-arm64", "android-direct-arm64-v8a", "linux-deb-arm64"],
  );
  assert.throws(() => parseClientReleaseTargetArgs([
    "--target", "macos-direct-arm64,macos-direct-arm64",
  ]), /duplicates/u);
  assert.throws(() => parseClientReleaseTargetArgs([
    "--target", "macos-direct-arm64",
  ], {
    environment: { LICO_CLIENT_RELEASE_TARGETS: "android-direct-arm64-v8a" },
  }), /multiple authorities/u);
});

test("selection preserves request order and separates build from release support", () => {
  const catalog = loadClientReleaseTargetCatalog();
  const selected = selectClientReleaseTargets(catalog, [
    "android-direct-arm64-v8a", "macos-direct-arm64",
  ], { requireBuildSupported: true, requireReleaseSupported: false });
  assert.deepEqual(selected.map((target) => target.id), [
    "android-direct-arm64-v8a", "macos-direct-arm64",
  ]);
  const linux = selectClientReleaseTargets(catalog, ["linux-deb-arm64"], {
    requireBuildSupported: true,
    requireReleaseSupported: false,
  });
  assert.equal(linux[0].packageBuildSupported, true);
  assert.equal(linux[0].releaseSupported, false);
  assert.throws(() => selectClientReleaseTargets(catalog, ["macos-direct-arm64"], {
    requireBuildSupported: true,
    requireReleaseSupported: true,
  }), /outside closure authority/u);
  assert.throws(() => selectClientReleaseTargets(catalog, ["linux-deb-arm64"], {
    requireBuildSupported: true,
    requireReleaseSupported: true,
  }), /outside closure authority/u);
  assert.equal(
    resolveClientReleaseTarget(
      catalog.targets.find((target) => target.id === "linux-deb-arm64"),
      "1.2.3",
    ).artifacts[0].file,
    "licoup_1.2.3_arm64.deb",
  );
});

test("plan emits one or multiple independently staged package directories", () => {
  const single = invoke(["plan", "--target", "macos-direct-arm64"]);
  assert.equal(single.status, 0, single.stderr);
  const singlePlan = JSON.parse(single.stdout);
  assert.equal(singlePlan.targetCount, 1);
  assert.equal(singlePlan.targets[0].outputRef,
    `build/releases/${productVersion}/macos-direct-arm64`);

  const multiple = invoke([
    "plan", "--targets", "macos-direct-arm64,android-direct-arm64-v8a",
  ]);
  assert.equal(multiple.status, 0, multiple.stderr);
  const multiplePlan = JSON.parse(multiple.stdout);
  assert.equal(multiplePlan.targetCount, 2);
  assert.equal(new Set(multiplePlan.targets.map((target) => target.outputRef)).size, 2);
  assert.ok(multiplePlan.targets.every((target) =>
    target.outputRef.endsWith(`/${target.targetId}`)));
});

test("release package temporary roots retire without touching stable outputs", () => {
  const versionRoot = mkdtempSync(
    path.join(os.tmpdir(), "lico-release-package-lifecycle-"),
  );
  const fixtureUuid = "12345678-1234-4123-8123-123456789abc";
  const stage = (pid) => `.package-stage-${pid}-1-${fixtureUuid}`;
  const backup = (pid) => `.package-backup-${pid}-1-${fixtureUuid}`;
  try {
    const deadStage = stage(9201);
    const deadBackup = backup(9201);
    const liveStage = stage(9202);
    const currentBackup = backup(9203);
    const stableTarget = "macos-direct-arm64";
    const legacyStage = ".package-stage-legacy-random-suffix";
    for (const name of [
      deadStage,
      deadBackup,
      liveStage,
      currentBackup,
      stableTarget,
      legacyStage,
    ]) {
      mkdirSync(path.join(versionRoot, name));
    }
    const result = retireStaleReleasePackageDirectories(
      versionRoot,
      [currentBackup],
      { isProcessAlive: (pid) => pid === 9202 },
    );
    assert.deepEqual(result, { scanned: 4, removed: 2 });
    assert.equal(existsSync(path.join(versionRoot, deadStage)), false);
    assert.equal(existsSync(path.join(versionRoot, deadBackup)), false);
    for (const name of [liveStage, currentBackup, stableTarget, legacyStage]) {
      assert.equal(existsSync(path.join(versionRoot, name)), true, name);
    }

    const failedStage = stage(9204);
    mkdirSync(path.join(versionRoot, failedStage));
    assert.throws(
      () => retireStaleReleasePackageDirectories(versionRoot, [], {
        isProcessAlive: (pid) => pid === 9202 || pid === 9203,
        removeDirectory: () => {
          throw new Error("synthetic removal failure");
        },
      }),
      (error) => {
        assert.equal(error.code, "client_release_package_cleanup_failed");
        assert.deepEqual(error.details, {
          stage: "release-package-retire",
          reason: "temporary_directory_removal_failed",
        });
        assert.equal(error.message.includes(path.sep), false);
        return true;
      },
    );
  } finally {
    rmSync(versionRoot, { recursive: true, force: true });
  }
});

test("builder describes owning-host recipes while keeping macOS direct local-only", () => {
  const described = spawnSync(process.execPath, [builderScript, "--describe"], {
    cwd: repoRoot,
    env: process.env,
    encoding: "utf8",
    shell: false,
    stdio: "pipe",
    timeout: 30_000,
    maxBuffer: 4 * 1024 * 1024,
  });
  assert.equal(described.status, 0, described.stderr);
  const result = JSON.parse(described.stdout);
  assert.equal(result.ok, true);
  assert.equal(result.dryRun, true);
  assert.equal(result.targetCount, 17);
  const macosDirect = result.targets.filter((target) =>
    target.targetId === "macos-direct-arm64");
  assert.equal(macosDirect.length, 1);
  assert.ok(macosDirect.every((target) =>
    target.commands.length === 0 && target.requiredTools.length === 0 &&
    target.credentialEnv.length === 0 && target.privatePathsIncluded === false));
  assert.ok(result.targets.filter((target) =>
    target.targetId !== "macos-direct-arm64").every((target) =>
    target.commands.length > 0 && target.requiredTools.length > 0 &&
    target.outputSources.some((output) => output.role === "build-manifest") &&
    target.privatePathsIncluded === false));
  assert.ok(result.targets.find((target) => target.targetId === "linux-deb-x64")
    .requiredTools.includes("dpkg-deb"));
  assert.ok(result.targets.find((target) => target.targetId === "windows-direct-x64")
    .requiredTools.includes("makeappx"));
  assert.ok(result.targets.find((target) => target.targetId === "android-play-arm64-v8a")
    .commands.some((command) => command.args.includes("appbundle")));
  assert.ok(result.targets.find((target) => target.targetId === "ios-app-store-arm64")
    .requiredTools.includes("xcodebuild"));
});

test("builder rejects a blocked target before host or tool mutation", () => {
  const target = wrongHostTarget();
  const preflight = spawnSync(process.execPath, [
    builderScript, "--target", target.id,
  ], {
    cwd: repoRoot,
    env: process.env,
    encoding: "utf8",
    shell: false,
    stdio: "pipe",
    timeout: 30_000,
    maxBuffer: 4 * 1024 * 1024,
  });
  assert.notEqual(preflight.status, 0);
  assert.deepEqual(JSON.parse(preflight.stderr), {
    ok: false,
    code: "client_platform_release_target_blocked",
    privatePathsIncluded: false,
  });
});

test("plan all includes implemented recipes but build rejects a wrong host before staging", () => {
  const plan = invoke(["plan", "--all"]);
  assert.equal(plan.status, 0, plan.stderr);
  assert.ok(JSON.parse(plan.stdout).targetCount >= 10);

  const build = invoke(["build", "--target", wrongHostTarget().id]);
  assert.notEqual(build.status, 0);
  assert.equal(JSON.parse(build.stderr).code, "client_release_package_host_unsupported");
  assert.equal(JSON.parse(build.stderr).privatePathsIncluded, false);
});

test("prepare matrix accepts every package-build target while publish stays release-bound", () => {
  const catalog = loadClientReleaseTargetCatalog();
  const packageBuildTargets = catalog.targets
    .filter((target) => target.packageBuildSupported)
    .map((target) => target.id);
  const releaseTargets = catalog.targets
    .filter((target) => target.releaseSupported)
    .map((target) => target.id);
  const signedManifestRequired = catalog.targets
    .filter((target) => releaseTargets.includes(target.id))
    .some((target) => target.update.kind === "signed-http-manifest");
  const matrix = releaseWorkflowMatrix(packageBuildTargets.join(","));
  assert.deepEqual(matrix.include.map((entry) => entry.target), packageBuildTargets);
  assert.equal(matrix.include.length, 17);
  for (const entry of matrix.include) {
    const target = catalog.targets.find((candidate) => candidate.id === entry.target);
    assert.deepEqual(entry.runner, [...target.builder.ciRunner].sort());
    assert.equal(entry.buildHost, target.buildHost);
  }
  const request = {
    tag: `v${productVersion}`,
    correlation: "1".repeat(64),
    ref: "refs/heads/release",
    sha: "2".repeat(40),
  };
  assert.equal(validateReleaseWorkflowRequest({
    ...request,
    phase: "prepare",
    targets: packageBuildTargets.join(","),
    sourceRevision: "",
    prepareRunId: "",
    artifactDigests: "",
    signedManifestPresent: "false",
  }), true);
  assert.equal(validateReleaseWorkflowRequest({
    ...request,
    phase: "publish",
    targets: releaseTargets.join(","),
    sourceRevision: request.sha,
    prepareRunId: "7",
    artifactDigests: JSON.stringify(Object.fromEntries(
      releaseTargets.map((target) => [target, `sha256:${"3".repeat(64)}`]),
    )),
    signedManifestPresent: String(signedManifestRequired),
  }), true);
  assert.throws(() => validateReleaseWorkflowRequest({
    ...request,
    phase: "publish",
    targets: packageBuildTargets.join(","),
    sourceRevision: request.sha,
    prepareRunId: "7",
    artifactDigests: JSON.stringify(Object.fromEntries(
      releaseTargets.map((target) => [target, `sha256:${"3".repeat(64)}`]),
    )),
    signedManifestPresent: "true",
  }), /outside closure authority/u);
});
