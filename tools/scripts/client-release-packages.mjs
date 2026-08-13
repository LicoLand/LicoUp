#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  copyFileSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { sha256File } from "./lib/client-release-artifact-digest.mjs";
import {
  loadClientReleaseTargetCatalog,
  parseClientReleaseTargetArgs,
  resolveClientReleaseTarget,
  selectClientReleaseTargets,
} from "./lib/client-release-targets.mjs";
import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  clientSourceStateDigest,
} from "./lib/client-source-state-digest.mjs";
import {
  ProjectTemporaryDirectoryLifecycleError,
  removeCurrentProjectTemporaryDirectory,
  retireInactiveProjectTemporaryDirectories,
} from "./lib/project-temporary-directory-lifecycle.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const buildRoot = path.join(repoRoot, "build");
const packageManifestSchema = "licomesh.client-release-package-manifest.v1";

class ClientReleasePackagesError extends Error {
  constructor(code, details = null) {
    super(code);
    this.code = code;
    this.details = details;
  }
}

function fail(code, details = null) {
  throw new ClientReleasePackagesError(code, details);
}

function loadVersion() {
  const version = JSON.parse(readFileSync(
    path.join(repoRoot, "tools/client-version.json"), "utf8",
  ));
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(version.productVersion || "") ||
    !Number.isInteger(version.buildNumber) || version.buildNumber < 1) {
    fail("client_release_version_invalid");
  }
  return Object.freeze(version);
}

function hostId() {
  const platform = process.platform === "darwin" ? "darwin"
    : process.platform === "win32" ? "win32" : process.platform;
  const arch = process.arch === "arm64" ? "arm64"
    : process.arch === "x64" ? "x64" : process.arch;
  return `${platform}-${arch}`;
}

function packageManifestName(target) {
  return `LicoUp-${target.id}.package.json`;
}

function publicTargetRecord(target) {
  return Object.freeze({
    targetId: target.id,
    runtimeTargetId: target.runtimeTargetId,
    platform: target.platform,
    distributionFamily: target.distributionFamily,
    baseline: target.baseline,
    channel: target.channel,
    packageFormat: target.packageFormat,
    architecture: target.arch,
    updateAuthority: target.updateAuthority,
    buildHost: target.buildHost,
    packageBuildSupported: target.packageBuildSupported,
    releaseSupported: target.releaseSupported,
    outputRef: target.outputRef,
    artifactFiles: target.artifacts.map((artifact) => artifact.file),
    packageManifest: packageManifestName(target),
    updateProtocol: target.update.kind,
    buildHosts: [...target.builder.hosts],
    builderTemplates: [...target.builder.templates],
    packageBlockers: [...target.packageBlockers],
    releaseBlockers: [...target.releaseBlockers],
  });
}

function selectedTargets(catalog, parsed, command) {
  const ids = parsed.all
    ? catalog.targets
      .filter((target) => command === "plan" || target.packageBuildSupported)
      .map((target) => target.id)
    : [...parsed.targetIds];
  if (ids.length === 0) fail("client_release_target_selection_required");
  return selectClientReleaseTargets(catalog, ids, {
    requireBuildSupported: ["build", "stage", "verify"].includes(command),
    requireReleaseSupported: false,
  });
}

function validateCommandOptions(command, remaining) {
  if (!Array.isArray(remaining) || remaining.length !== 0 ||
    !["plan", "build", "stage", "verify"].includes(command)) {
    fail("client_release_packages_option_invalid");
  }
}

function runBuilder(target) {
  if (!target.builder.hosts.includes(hostId())) {
    fail("client_release_package_host_unsupported");
  }
  const result = spawnSync(target.builder.program, target.builder.args, {
    cwd: repoRoot,
    env: process.env,
    encoding: "utf8",
    shell: false,
    stdio: "inherit",
    timeout: 2 * 60 * 60 * 1000,
    maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    fail("client_release_package_builder_failed");
  }
}

function containedBuildFile(relativeRef) {
  const absolute = path.resolve(repoRoot, relativeRef || "");
  if (!absolute.startsWith(`${buildRoot}${path.sep}`)) {
    fail("client_release_package_source_invalid");
  }
  const info = lstatSync(absolute, { throwIfNoEntry: false });
  if (!info?.isFile() || info.isSymbolicLink() || realpathSync(absolute) !== absolute) {
    fail("client_release_package_source_missing");
  }
  return absolute;
}

function containedPackageDirectory(target) {
  const absolute = path.resolve(repoRoot, target.outputRef);
  const releasesRoot = path.join(buildRoot, "releases");
  if (!absolute.startsWith(`${releasesRoot}${path.sep}`)) {
    fail("client_release_package_output_invalid");
  }
  return absolute;
}

function checksumLine(filePath, fileName) {
  return `${sha256File(filePath).slice("sha256:".length)}  ${fileName}\n`;
}

function sourceBinding() {
  return Object.freeze({
    sourceStateDigest: clientSourceStateDigest(
      repoRoot,
      CANONICAL_CLIENT_SOURCE_ROOTS,
    ),
    targetCatalogDigest: sha256File(path.join(
      repoRoot,
      "tools/client-release-targets.json",
    )),
  });
}

function packageFile(outputRoot, name) {
  return containedBuildFile(path.relative(repoRoot, path.join(outputRoot, name)));
}

function stageTarget(target, version, binding, outputRoot) {
  mkdirSync(outputRoot, { recursive: true, mode: 0o755 });

  const byRole = new Map();
  const manifestArtifacts = [];
  for (const artifact of target.artifacts) {
    const output = path.join(outputRoot, artifact.file);
    if (artifact.role === "checksum") {
      const subject = byRole.get(artifact.for);
      if (!subject) fail("client_release_package_checksum_subject_missing");
      writeFileSync(output, checksumLine(subject.path, subject.file), {
        encoding: "utf8",
        mode: 0o644,
        flag: "wx",
      });
    } else {
      if (!artifact.source) fail("client_release_package_source_undefined");
      copyFileSync(containedBuildFile(artifact.source), output, 0);
    }
    const info = statSync(output);
    const record = Object.freeze({
      role: artifact.role,
      ...(artifact.for ? { for: artifact.for } : {}),
      file: artifact.file,
      byteSize: info.size,
      sha256: sha256File(output),
    });
    manifestArtifacts.push(record);
    if (artifact.role !== "checksum") {
      byRole.set(artifact.role, { path: output, file: artifact.file });
    }
  }

  const manifest = Object.freeze({
    schemaVersion: packageManifestSchema,
    targetId: target.id,
    runtimeTargetId: target.runtimeTargetId,
    platform: target.platform,
    distributionFamily: target.distributionFamily,
    baseline: target.baseline,
    channel: target.channel,
    packageFormat: target.packageFormat,
    architecture: target.arch,
    productVersion: version.productVersion,
    buildNumber: version.buildNumber,
    sourceStateDigest: binding.sourceStateDigest,
    targetCatalogDigest: binding.targetCatalogDigest,
    updateProtocol: target.update.kind,
    updateAuthority: target.updateAuthority,
    buildHost: target.buildHost,
    artifacts: manifestArtifacts,
  });
  writeFileSync(path.join(outputRoot, packageManifestName(target)),
    `${JSON.stringify(manifest, null, 2)}\n`, {
      encoding: "utf8", mode: 0o644, flag: "wx",
    });
  verifyTarget(target, version, binding, outputRoot);
  return publicTargetRecord(target);
}

function exactObjectKeys(value, keys) {
  return value && typeof value === "object" && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort());
}

function artifactRecord(manifest, role) {
  return manifest.artifacts.find((artifact) => artifact.role === role);
}

function verifyBuildManifestBinding(target, version, packageManifest, outputRoot) {
  const record = artifactRecord(packageManifest, "build-manifest");
  if (!record) fail("client_release_package_build_manifest_missing");
  const buildManifest = JSON.parse(readFileSync(
    packageFile(outputRoot, record.file),
    "utf8",
  ));
  const genericManifest = buildManifest.schemaVersion ===
    "licomesh.client-release-build-manifest.v1";
  const expectedTargetId = genericManifest ? target.id : target.runtimeTargetId;
  if (buildManifest.targetId !== expectedTargetId ||
    buildManifest.productVersion !== version.productVersion ||
    buildManifest.buildNumber !== version.buildNumber ||
    buildManifest.sourceStateDigest !== packageManifest.sourceStateDigest) {
    fail("client_release_package_build_manifest_invalid");
  }
  const packageArtifact = artifactRecord(packageManifest, "installer") ||
    artifactRecord(packageManifest, "submission");
  if (!packageArtifact) fail("client_release_package_installer_missing");
  if (genericManifest) {
    const expectedBuildManifestKeys = [
      "schemaVersion", "targetId", "runtimeTargetId", "platform",
      "distributionFamily", "baseline", "channel", "packageFormat",
      "architecture", "updateAuthority", "buildHost", "productVersion",
      "buildNumber", "sourceStateDigest", "targetCatalogDigest",
      "artifactDigest", "packageDigest", "artifact", "artifacts",
      "commandSequence", "requiredTools", "credentialEnv", "outputSources",
    ];
    const expectedBuiltArtifacts = packageManifest.artifacts.filter((artifact) =>
      artifact.role !== "checksum" && artifact.role !== "build-manifest");
    if (!exactObjectKeys(buildManifest, expectedBuildManifestKeys) ||
      buildManifest.runtimeTargetId !== target.runtimeTargetId ||
      buildManifest.platform !== target.platform ||
      buildManifest.distributionFamily !== target.distributionFamily ||
      buildManifest.baseline !== target.baseline ||
      buildManifest.channel !== target.channel ||
      buildManifest.packageFormat !== target.packageFormat ||
      buildManifest.architecture !== target.arch ||
      buildManifest.updateAuthority !== target.updateAuthority ||
      buildManifest.buildHost !== target.buildHost ||
      buildManifest.targetCatalogDigest !== packageManifest.targetCatalogDigest ||
      !exactObjectKeys(buildManifest.artifact,
        ["role", "file", "byteSize", "sha256"]) ||
      buildManifest.artifact?.role !== packageArtifact.role ||
      buildManifest.artifact?.file !== packageArtifact.file ||
      buildManifest.artifact?.byteSize !== packageArtifact.byteSize ||
      buildManifest.artifact?.sha256 !== packageArtifact.sha256 ||
      buildManifest.artifactDigest !== packageArtifact.sha256 ||
      buildManifest.packageDigest !== packageArtifact.sha256 ||
      !Array.isArray(buildManifest.artifacts) ||
      buildManifest.artifacts.length !== expectedBuiltArtifacts.length ||
      buildManifest.artifacts.some((artifact, index) => {
        const expected = expectedBuiltArtifacts[index];
        return !exactObjectKeys(artifact, ["role", "file", "source", "byteSize", "sha256"]) ||
          artifact.role !== expected.role || artifact.file !== expected.file ||
          artifact.byteSize !== expected.byteSize || artifact.sha256 !== expected.sha256;
      }) ||
      !Array.isArray(buildManifest.commandSequence) ||
      buildManifest.commandSequence.length === 0 ||
      !Array.isArray(buildManifest.requiredTools) ||
      !Array.isArray(buildManifest.credentialEnv) ||
      !Array.isArray(buildManifest.outputSources)) {
      fail("client_release_package_build_manifest_invalid");
    }
  } else if (target.platform === "macos") {
    const update = artifactRecord(packageManifest, "update");
    if (!update || buildManifest.artifactReady !== true ||
      buildManifest.archive !== packageArtifact.file ||
      buildManifest.sha256 !== packageArtifact.sha256.slice("sha256:".length) ||
      buildManifest.updateArchive !== update.file ||
      buildManifest.updateSha256 !== update.sha256.slice("sha256:".length)) {
      fail("client_release_package_build_manifest_invalid");
    }
  } else if (target.platform === "android") {
    if (buildManifest.mode !== "release" ||
      buildManifest.artifact?.digest !== packageArtifact.sha256 ||
      buildManifest.reproducibility?.ready !== true) {
      fail("client_release_package_build_manifest_invalid");
    }
  } else {
    fail("client_release_package_build_manifest_platform_invalid");
  }
  if (path.dirname(path.join(outputRoot, record.file)) !== outputRoot) {
    fail("client_release_package_build_manifest_invalid");
  }
}

function verifyTarget(
  target,
  version,
  binding = sourceBinding(),
  outputRoot = containedPackageDirectory(target),
) {
  const rootInfo = lstatSync(outputRoot, { throwIfNoEntry: false });
  if (!rootInfo?.isDirectory() || rootInfo.isSymbolicLink() ||
    realpathSync(outputRoot) !== outputRoot) {
    fail("client_release_package_directory_invalid");
  }
  const manifestFile = packageManifestName(target);
  const expectedFiles = [...target.artifacts.map((artifact) => artifact.file), manifestFile].sort();
  const entries = readdirSync(outputRoot, { withFileTypes: true });
  if (entries.some((entry) => !entry.isFile() || entry.isSymbolicLink()) ||
    JSON.stringify(entries.map((entry) => entry.name).sort()) !==
      JSON.stringify(expectedFiles)) {
    fail("client_release_package_file_set_invalid");
  }
  const manifestPath = packageFile(outputRoot, manifestFile);
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  if (!exactObjectKeys(manifest, [
    "schemaVersion", "targetId", "runtimeTargetId", "platform",
    "distributionFamily", "baseline", "channel", "packageFormat",
    "architecture", "productVersion", "buildNumber", "updateAuthority",
    "buildHost", "sourceStateDigest", "targetCatalogDigest",
    "updateProtocol", "artifacts",
  ]) || manifest.schemaVersion !== packageManifestSchema ||
    manifest.targetId !== target.id ||
    manifest.runtimeTargetId !== target.runtimeTargetId ||
    manifest.platform !== target.platform ||
    manifest.distributionFamily !== target.distributionFamily ||
    manifest.baseline !== target.baseline || manifest.channel !== target.channel ||
    manifest.packageFormat !== target.packageFormat ||
    manifest.architecture !== target.arch ||
    manifest.updateAuthority !== target.updateAuthority ||
    manifest.buildHost !== target.buildHost ||
    manifest.productVersion !== version.productVersion ||
    manifest.buildNumber !== version.buildNumber ||
    manifest.sourceStateDigest !== binding.sourceStateDigest ||
    manifest.targetCatalogDigest !== binding.targetCatalogDigest ||
    manifest.updateProtocol !== target.update.kind ||
    !Array.isArray(manifest.artifacts) ||
    manifest.artifacts.length !== target.artifacts.length) {
    fail("client_release_package_manifest_invalid");
  }
  for (let index = 0; index < target.artifacts.length; index += 1) {
    const expected = target.artifacts[index];
    const actual = manifest.artifacts[index];
    const expectedKeys = ["role", "file", "byteSize", "sha256",
      ...(expected.for ? ["for"] : [])];
    const filePath = packageFile(outputRoot, expected.file);
    const info = statSync(filePath);
    if (!exactObjectKeys(actual, expectedKeys) || actual.role !== expected.role ||
      actual.file !== expected.file || actual.for !== expected.for ||
      actual.byteSize !== info.size || actual.sha256 !== sha256File(filePath)) {
      fail("client_release_package_artifact_invalid");
    }
    if (expected.role === "checksum") {
      const subject = target.artifacts.find((artifact) => artifact.role === expected.for);
      const subjectPath = packageFile(outputRoot, subject.file);
      if (readFileSync(filePath, "utf8") !== checksumLine(subjectPath, subject.file)) {
        fail("client_release_package_checksum_invalid");
      }
    }
  }
  verifyBuildManifestBinding(target, version, manifest, outputRoot);
  return publicTargetRecord(target);
}

function stageTargetsAtomically(targets, version) {
  const releasesRoot = path.join(buildRoot, "releases");
  const versionRoot = path.join(releasesRoot, version.productVersion);
  const buildInfo = lstatSync(buildRoot, { throwIfNoEntry: false });
  if (!buildInfo?.isDirectory() || buildInfo.isSymbolicLink() ||
    realpathSync(buildRoot) !== buildRoot) {
    fail("client_release_package_build_root_invalid");
  }
  if (!lstatSync(releasesRoot, { throwIfNoEntry: false })) {
    mkdirSync(releasesRoot, { recursive: false, mode: 0o755 });
  }
  const releasesInfo = lstatSync(releasesRoot);
  if (!releasesInfo.isDirectory() || releasesInfo.isSymbolicLink() ||
    realpathSync(releasesRoot) !== releasesRoot) {
    fail("client_release_package_output_invalid");
  }
  mkdirSync(versionRoot, { recursive: true, mode: 0o755 });
  const versionInfo = lstatSync(versionRoot);
  if (!versionInfo.isDirectory() || versionInfo.isSymbolicLink() ||
    realpathSync(versionRoot) !== versionRoot) {
    fail("client_release_package_output_invalid");
  }
  const runToken = `${process.pid}-${Date.now()}-${randomUUID()}`;
  const stagingName = `.package-stage-${runToken}`;
  const backupName = `.package-backup-${runToken}`;
  retireStaleReleasePackageDirectories(versionRoot, [stagingName, backupName]);
  const stagingRoot = path.join(versionRoot, stagingName);
  const backupRoot = path.join(versionRoot, backupName);
  mkdirSync(stagingRoot, { mode: 0o700 });
  mkdirSync(backupRoot, { mode: 0o700 });
  const binding = sourceBinding();
  const movedExisting = [];
  const installed = [];
  let primaryError = null;
  try {
    for (const target of targets) {
      stageTarget(target, version, binding, path.join(stagingRoot, target.id));
    }
    for (const target of targets) {
      const destination = containedPackageDirectory(target);
      const existing = lstatSync(destination, { throwIfNoEntry: false });
      if (existing) {
        const backup = path.join(backupRoot, target.id);
        renameSync(destination, backup);
        movedExisting.push({ destination, backup });
      }
      renameSync(path.join(stagingRoot, target.id), destination);
      installed.push(destination);
    }
  } catch (error) {
    primaryError = error;
    for (const destination of [...installed].reverse()) {
      rmSync(destination, { recursive: true, force: true });
    }
    for (const { destination, backup } of [...movedExisting].reverse()) {
      if (lstatSync(backup, { throwIfNoEntry: false })) renameSync(backup, destination);
    }
    throw error;
  } finally {
    try {
      removeCurrentProjectTemporaryDirectory({
        root: versionRoot,
        name: stagingName,
        parseOwnerPid: parseReleasePackageTemporaryOwnerPid,
      });
      removeCurrentProjectTemporaryDirectory({
        root: versionRoot,
        name: backupName,
        parseOwnerPid: parseReleasePackageTemporaryOwnerPid,
      });
    } catch (error) {
      if (!primaryError) {
        releaseTemporaryCleanupFailure(error, "release-package-finalize");
      }
    }
  }
}

export function retireStaleReleasePackageDirectories(
  versionRoot,
  currentNames = [],
  operations = {},
) {
  try {
    return retireInactiveProjectTemporaryDirectories({
      root: versionRoot,
      parseOwnerPid: parseReleasePackageTemporaryOwnerPid,
      currentNames,
      ...operations,
    });
  } catch (error) {
    releaseTemporaryCleanupFailure(error, "release-package-retire");
  }
}

export function parseReleasePackageTemporaryOwnerPid(name) {
  const match = /^\.package-(?:stage|backup)-([1-9]\d*)-([1-9]\d*)-([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$/u
    .exec(name);
  if (!match) return null;
  const pid = Number(match[1]);
  return Number.isSafeInteger(pid) ? pid : null;
}

function releaseTemporaryCleanupFailure(error, stage) {
  if (error instanceof ProjectTemporaryDirectoryLifecycleError) {
    fail("client_release_package_cleanup_failed", {
      stage,
      reason: error.reason,
    });
  }
  throw error;
}

export function runClientReleasePackages(argv = process.argv.slice(2), {
  emit = (record) => process.stdout.write(`${JSON.stringify(record, null, 2)}\n`),
} = {}) {
  const [command = "", ...selectionArgs] = argv;
  const parsed = parseClientReleaseTargetArgs(selectionArgs);
  validateCommandOptions(command, parsed.remaining);
  const catalog = loadClientReleaseTargetCatalog();
  const version = loadVersion();
  const targets = selectedTargets(catalog, parsed, command)
    .map((target) => resolveClientReleaseTarget(target, version.productVersion));

  if (command === "build") {
    const incompatible = targets.filter((target) =>
      !target.builder.hosts.includes(hostId()));
    if (incompatible.length > 0) fail("client_release_package_host_unsupported");
    for (const target of targets) runBuilder(target);
    stageTargetsAtomically(targets, version);
  } else if (command === "stage") {
    stageTargetsAtomically(targets, version);
  } else if (command === "verify") {
    const binding = sourceBinding();
    for (const target of targets) verifyTarget(target, version, binding);
  }

  const result = Object.freeze({
    ok: true,
    command,
    productVersion: version.productVersion,
    targetCount: targets.length,
    targets: targets.map(publicTargetRecord),
    privatePathsIncluded: false,
  });
  emit(result);
  return result;
}

if (process.argv[1] && import.meta.url ===
  pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    runClientReleasePackages();
  } catch (error) {
    const code = error instanceof ClientReleasePackagesError
      ? error.code : "client_release_packages_failed";
    process.stderr.write(`${JSON.stringify({
      ok: false,
      code,
      ...(error instanceof ClientReleasePackagesError && error.details
        ? error.details : {}),
      privatePathsIncluded: false,
    })}\n`);
    process.exitCode = 1;
  }
}
