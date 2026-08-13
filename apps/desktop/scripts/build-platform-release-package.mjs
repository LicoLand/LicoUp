#!/usr/bin/env node

/*
 * Build one exact platform release package on its owning host.
 *
 * This entrypoint is deliberately target-driven.  It describes every native
 * command before doing any work, validates the host/tool/credential boundary,
 * and writes only the build-side sources declared by the target catalog.  The
 * release orchestrator is the sole writer of build/releases/{version}/... .
 */

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

import { sha256File } from "../../../tools/scripts/lib/client-release-artifact-digest.mjs";
import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  clientSourceStateDigest,
} from "../../../tools/scripts/lib/client-source-state-digest.mjs";
import {
  loadClientReleaseTargetCatalog,
  selectClientReleaseTargets,
} from "../../../tools/scripts/lib/client-release-targets.mjs";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const catalogPath = path.join(workspaceRoot, "tools", "client-release-targets.json");
const versionPath = path.join(workspaceRoot, "tools", "client-version.json");
const builderManifestSchema = "licomesh.client-release-build-manifest.v1";
const targetIdPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/u;
const commandTimeoutMs = 2 * 60 * 60 * 1000;

class PlatformReleaseBuilderError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

function fail(code) {
  throw new PlatformReleaseBuilderError(code);
}

function text(value) {
  return String(value || "").trim();
}

function hostId() {
  const platform = process.platform === "darwin" ? "darwin"
    : process.platform === "win32" ? "win32" : process.platform;
  const arch = process.arch === "arm64" ? "arm64"
    : process.arch === "x64" ? "x64" : process.arch;
  return `${platform}-${arch}`;
}

function loadVersion() {
  const version = JSON.parse(readFileSync(versionPath, "utf8"));
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(text(version.productVersion)) ||
    !Number.isSafeInteger(version.buildNumber) || version.buildNumber < 1) {
    fail("client_platform_release_version_invalid");
  }
  return Object.freeze({
    productVersion: text(version.productVersion),
    buildNumber: version.buildNumber,
  });
}

function parseArgs(argv = process.argv.slice(2)) {
  let targetId = "";
  let describe = false;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if ((arg === "--target" || arg === "-t") && argv[index + 1]) {
      targetId = text(argv[++index]);
    } else if (arg.startsWith("--target=") && arg.length > 9) {
      targetId = text(arg.slice(9));
    } else if (arg === "--describe") {
      describe = true;
    } else {
      fail("client_platform_release_option_invalid");
    }
  }
  if (targetId && !targetIdPattern.test(targetId)) {
    fail("client_platform_release_target_invalid");
  }
  if (!describe && !targetId) fail("client_platform_release_target_required");
  return Object.freeze({ targetId, describe });
}

function selectTarget(catalog, targetId) {
  try {
    return selectClientReleaseTargets(catalog, [targetId], {
      requireBuildSupported: true,
      requireReleaseSupported: false,
    })[0];
  } catch {
    fail("client_platform_release_target_unknown");
  }
}

function resolveToken(value, version, target) {
  return String(value)
    .replaceAll("{version}", version.productVersion)
    .replaceAll("{targetId}", target.id);
}

function catalogDigest() {
  return `sha256:${createHash("sha256").update(readFileSync(catalogPath)).digest("hex")}`;
}

function artifactSource(target, artifact, version) {
  const source = resolveToken(artifact?.source, version, target);
  if (!source || !source.startsWith("build/") || source.includes("..") || path.isAbsolute(source)) {
    fail("client_platform_release_artifact_source_invalid");
  }
  const absolute = path.resolve(workspaceRoot, source);
  const buildRoot = path.join(workspaceRoot, "build");
  if (!absolute.startsWith(`${buildRoot}${path.sep}`)) {
    fail("client_platform_release_artifact_source_invalid");
  }
  return absolute;
}

function sourceRelative(absolute) {
  return path.relative(workspaceRoot, absolute).split(path.sep).join("/");
}

function packageArtifact(target) {
  const artifact = target.artifacts.find((candidate) =>
    candidate?.role === "installer" || candidate?.role === "submission");
  if (!artifact) fail("client_platform_release_package_artifact_missing");
  return artifact;
}

function buildManifestArtifact(target) {
  const artifact = target.artifacts.find((candidate) => candidate?.role === "build-manifest");
  if (!artifact) fail("client_platform_release_build_manifest_declared_missing");
  return artifact;
}

function recipeFor(target, version) {
  const commands = [];
  const requiredTools = new Set();
  const credentialEnv = new Set();
  const add = (program, args, options = {}) => {
    commands.push(Object.freeze({
      program,
      args: Object.freeze(args.map(String)),
      ...(options.cwd ? { cwd: options.cwd } : {}),
      ...(options.label ? { label: options.label } : {}),
    }));
    if (options.tool !== false) requiredTools.add(program);
  };
  const credentials = (...names) => names.forEach((name) => credentialEnv.add(name));
  const outputPath = (role) => {
    const artifact = target.artifacts.find((candidate) => candidate?.role === role);
    return artifact?.source ? resolveToken(artifact.source, version, target) : "";
  };
  const packagePath = outputPath("installer") || outputPath("submission");
  const outputDir = packagePath ? path.posix.dirname(packagePath) : `build/apps/desktop/native-release/${target.id}`;

  switch (target.id) {
    case "macos-direct-arm64":
    case "macos-direct-x64":
      // Direct macOS distribution is local-only and must enter through the
      // explicit Developer ID platform-channel coordinator.
      break;
    case "macos-app-store-arm64":
      add("xcodebuild", ["-version"], { label: "xcode-version" });
      add("xcodebuild", [
        "-workspace", "apps/desktop/macos/Runner.xcworkspace",
        "-scheme", "Runner", "-configuration", "Release",
        "-archivePath", `${outputDir}/Runner.xcarchive`, "archive",
      ], { label: "xcode-archive" });
      add("xcodebuild", [
        "-exportArchive", "-archivePath", `${outputDir}/Runner.xcarchive`,
        "-exportOptionsPlist", "apps/desktop/packaging/ios/ExportOptions-AppStore.plist",
        "-exportPath", `${outputDir}/export`,
      ], { label: "xcode-export" });
      credentials("LICO_MACOS_APP_STORE_SIGNING_IDENTITY", "LICO_MACOS_APP_STORE_TEAM_ID");
      break;
    case "windows-direct-x64":
      add("flutter", ["build", "windows", "--release"], { cwd: "apps/desktop", label: "flutter-windows" });
      add("makeappx", ["pack", "/d", "apps/desktop/packaging/windows/msix", "/p", packagePath], { label: "msix-pack" });
      add("signtool", ["sign", "/fd", "SHA256", "/a", packagePath], { label: "msix-sign" });
      credentials("LICO_WINDOWS_SIGNING_CERTIFICATE_PATH", "LICO_WINDOWS_SIGNING_CERTIFICATE_PASSWORD");
      break;
    case "windows-store-x64":
      add("flutter", ["build", "windows", "--release"], { cwd: "apps/desktop", label: "flutter-windows" });
      add("makeappx", ["bundle", "/d", "apps/desktop/packaging/windows/msix", "/p", packagePath], { label: "msixupload-bundle" });
      add("signtool", ["sign", "/fd", "SHA256", "/a", packagePath], { label: "msixupload-sign" });
      credentials("LICO_WINDOWS_SIGNING_CERTIFICATE_PATH", "LICO_WINDOWS_SIGNING_CERTIFICATE_PASSWORD");
      break;
    case "linux-deb-arm64":
    case "linux-deb-x64":
      add("flutter", ["build", "linux", "--release"], { cwd: "apps/desktop", label: "flutter-linux" });
      add("dpkg-deb", ["--build", "apps/desktop/packaging/linux/deb", packagePath], { label: "deb-pack" });
      break;
    case "linux-rpm-arm64":
    case "linux-rpm-x64":
      add("flutter", ["build", "linux", "--release"], { cwd: "apps/desktop", label: "flutter-linux" });
      add("rpmbuild", ["-bb", "apps/desktop/packaging/linux/rpm/licoup.spec", "--define", `_rpmdir ${outputDir}`], { label: "rpm-pack" });
      break;
    case "linux-pacman-arm64":
    case "linux-pacman-x64":
      add("flutter", ["build", "linux", "--release"], { cwd: "apps/desktop", label: "flutter-linux" });
      add("makepkg", ["--verifysource", "--force", "--noconfirm"], { cwd: outputDir, label: "pacman-pack" });
      break;
    case "linux-alpine-apk-arm64":
    case "linux-alpine-apk-x64":
      add("flutter", ["build", "linux", "--release"], { cwd: "apps/desktop", label: "flutter-linux" });
      add("abuild", ["-r", "apps/desktop/packaging/linux/alpine/APKBUILD"], { label: "alpine-pack" });
      break;
    case "linux-appimage-arm64":
    case "linux-appimage-x64":
      add("flutter", ["build", "linux", "--release"], { cwd: "apps/desktop", label: "flutter-linux" });
      add("appimagetool", ["apps/desktop/packaging/linux/appimage", packagePath], { label: "appimage-pack" });
      break;
    case "android-direct-arm64-v8a":
      add("node", ["apps/desktop/scripts/build-android-apk.mjs", "--release"], { label: "android-apk" });
      requiredTools.add("flutter");
      credentials(
        "LICO_ANDROID_KEYSTORE_PATH",
        "LICO_ANDROID_KEYSTORE_PASSWORD",
        "LICO_ANDROID_KEY_ALIAS",
        "LICO_ANDROID_KEY_PASSWORD",
      );
      break;
    case "android-play-arm64-v8a":
      add("flutter", ["build", "appbundle", "--release", "--target-platform", "android-arm64"], {
        cwd: "apps/desktop",
        label: "android-aab",
      });
      credentials(
        "LICO_ANDROID_KEYSTORE_PATH",
        "LICO_ANDROID_KEYSTORE_PASSWORD",
        "LICO_ANDROID_KEY_ALIAS",
        "LICO_ANDROID_KEY_PASSWORD",
      );
      break;
    case "ios-app-store-arm64":
      add("xcodebuild", ["-version"], { label: "xcode-version" });
      add("xcodebuild", [
        "-workspace", "apps/desktop/ios/Runner.xcworkspace",
        "-scheme", "Runner", "-configuration", "Release",
        "-archivePath", `${outputDir}/Runner.xcarchive`, "archive",
      ], { label: "xcode-archive" });
      add("xcodebuild", [
        "-exportArchive", "-archivePath", `${outputDir}/Runner.xcarchive`,
        "-exportOptionsPlist", "apps/desktop/packaging/ios/ExportOptions-AppStore.plist",
        "-exportPath", `${outputDir}/export`,
      ], { label: "ipa-export" });
      credentials("LICO_IOS_SIGNING_IDENTITY", "LICO_IOS_TEAM_ID", "LICO_IOS_PROVISIONING_PROFILE");
      break;
    default:
      fail("client_platform_release_recipe_missing");
  }

  return Object.freeze({
    commands: Object.freeze(commands),
    requiredTools: Object.freeze([...requiredTools].sort()),
    credentialEnv: Object.freeze([...credentialEnv].sort()),
    outputDir,
  });
}

function descriptionFor(target, version, sourceDigest, targetCatalogDigest) {
  const recipe = recipeFor(target, version);
  const outputs = target.artifacts
    .filter((artifact) => artifact.role !== "checksum")
    .map((artifact) => ({
      role: artifact.role,
      file: resolveToken(artifact.file, version, target),
      source: artifact.source ? resolveToken(artifact.source, version, target) : null,
    }));
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
    builderHosts: [...(target.builder.hosts || [])],
    productVersion: version.productVersion,
    buildNumber: version.buildNumber,
    sourceStateDigest: sourceDigest,
    targetCatalogDigest,
    commands: recipe.commands,
    requiredTools: recipe.requiredTools,
    credentialEnv: recipe.credentialEnv,
    outputSources: outputs,
    privatePathsIncluded: false,
  });
}

function commandExists(program) {
  if (program === "node" || program === process.execPath) return true;
  if (program.startsWith("/")) {
    const info = lstatSync(program, { throwIfNoEntry: false });
    return Boolean(info?.isFile() && !info.isSymbolicLink());
  }
  const finder = process.platform === "win32" ? "where.exe" : "which";
  const result = spawnSync(finder, [program], {
    cwd: workspaceRoot,
    env: { PATH: process.env.PATH || "" },
    encoding: "utf8",
    stdio: "ignore",
    shell: false,
    timeout: 10_000,
  });
  return !result.error && result.status === 0;
}

function validateCredentials(recipe) {
  for (const name of recipe.credentialEnv) {
    const value = text(process.env[name]);
    if (!value) fail("client_platform_release_credentials_missing");
    if (name.endsWith("_PATH") || name.endsWith("_PROFILE")) {
      const resolved = path.resolve(value);
      const info = lstatSync(resolved, { throwIfNoEntry: false });
      if (!info?.isFile() || info.isSymbolicLink()) {
        fail("client_platform_release_credentials_missing");
      }
    }
  }
}

function preflight(target, recipe) {
  if (!(target.builder.hosts || []).includes(hostId())) {
    fail("client_platform_release_wrong_host");
  }
  for (const program of recipe.requiredTools) {
    if (!commandExists(program)) fail("client_platform_release_tool_missing");
  }
  validateCredentials(recipe);
}

function runCommand(command) {
  const cwd = command.cwd ? path.resolve(workspaceRoot, command.cwd) : workspaceRoot;
  const info = lstatSync(cwd, { throwIfNoEntry: false });
  if (!info?.isDirectory() || info.isSymbolicLink()) fail("client_platform_release_command_cwd_invalid");
  const result = spawnSync(command.program, command.args, {
    cwd,
    env: process.env,
    encoding: "utf8",
    shell: false,
    stdio: "inherit",
    timeout: commandTimeoutMs,
    maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) fail("client_platform_release_command_failed");
}

function ensureBuildPath(filePath) {
  const buildRoot = path.join(workspaceRoot, "build");
  if (!filePath.startsWith(`${buildRoot}${path.sep}`)) fail("client_platform_release_artifact_source_invalid");
  const parent = path.dirname(filePath);
  mkdirSync(parent, { recursive: true, mode: 0o755 });
  const info = lstatSync(filePath, { throwIfNoEntry: false });
  if (info?.isSymbolicLink()) fail("client_platform_release_artifact_invalid");
}

function clearDeclaredSources(target, version) {
  for (const artifact of target.artifacts.filter((candidate) => candidate.source)) {
    const destination = artifactSource(target, artifact, version);
    rmSync(destination, { force: true });
  }
}

function copyRegularFile(source, destination) {
  if (!existsSync(source) || source === destination) return false;
  const info = lstatSync(source, { throwIfNoEntry: false });
  if (!info?.isFile() || info.isSymbolicLink() || realpathSync(source) !== source) {
    fail("client_platform_release_artifact_invalid");
  }
  ensureBuildPath(destination);
  copyFileSync(source, destination);
  return true;
}

function candidateFiles(target, artifact, version) {
  const name = resolveToken(artifact.file, version, target);
  const distributionRoot = path.join(workspaceRoot, "build", "apps", "desktop", "distribution", "macos");
  const candidates = [];
  if (target.platform === "macos" && target.channel === "direct") {
    candidates.push(path.join(distributionRoot, artifact.role === "build-manifest" ? "manifest.json" : name));
  }
  if (target.id === "android-direct-arm64-v8a") {
    candidates.push(path.join(
      workspaceRoot,
      "build", "apps", "desktop", "android", "release",
      artifact.role === "installer" ? "app-release.apk" : "build-manifest.json",
    ));
  }
  if (target.id === "android-play-arm64-v8a") {
    candidates.push(path.join(workspaceRoot, "apps", "desktop", "build", "app", "outputs", "bundle", "release", "app-release.aab"));
  }
  if (target.platform === "ios") {
    candidates.push(...findByExtension(path.join(workspaceRoot, "build", "apps", "desktop", "native-release", target.id, "export"), ".ipa"));
  }
  candidates.push(path.join(workspaceRoot, name));
  return candidates;
}

function findByExtension(directory, extension) {
  const info = lstatSync(directory, { throwIfNoEntry: false });
  if (!info?.isDirectory() || info.isSymbolicLink()) return [];
  return readdirSync(directory, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(extension))
    .sort((left, right) => left.name.localeCompare(right.name))
    .map((entry) => path.join(directory, entry.name));
}

function materializeDeclaredSources(target, version) {
  for (const artifact of target.artifacts.filter((candidate) =>
    candidate.source && candidate.role !== "build-manifest")) {
    const destination = artifactSource(target, artifact, version);
    if (existsSync(destination)) continue;
    const copied = candidateFiles(target, artifact, version)
      .some((candidate) => copyRegularFile(candidate, destination));
    if (!copied) fail("client_platform_release_artifact_missing");
  }
}

function artifactRecord(target, artifact, version) {
  const source = artifactSource(target, artifact, version);
  const info = lstatSync(source, { throwIfNoEntry: false });
  if (!info?.isFile() || info.isSymbolicLink() || realpathSync(source) !== source) {
    fail("client_platform_release_artifact_invalid");
  }
  return {
    role: artifact.role,
    file: resolveToken(artifact.file, version, target),
    source: sourceRelative(source),
    byteSize: statSync(source).size,
    sha256: sha256File(source),
  };
}

function writeBuildManifest(target, version, recipe, sourceDigest, targetCatalogDigest) {
  const packageRecord = artifactRecord(target, packageArtifact(target), version);
  const records = target.artifacts
    .filter((artifact) => artifact.role !== "checksum" && artifact.role !== "build-manifest")
    .map((artifact) => artifactRecord(target, artifact, version));
  const manifestArtifact = buildManifestArtifact(target);
  const manifestPath = artifactSource(target, manifestArtifact, version);
  const manifest = {
    schemaVersion: builderManifestSchema,
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
    productVersion: version.productVersion,
    buildNumber: version.buildNumber,
    sourceStateDigest: sourceDigest,
    targetCatalogDigest,
    artifactDigest: packageRecord.sha256,
    packageDigest: packageRecord.sha256,
    artifact: {
      role: packageRecord.role,
      file: packageRecord.file,
      byteSize: packageRecord.byteSize,
      sha256: packageRecord.sha256,
    },
    artifacts: records,
    commandSequence: recipe.commands,
    requiredTools: recipe.requiredTools,
    credentialEnv: recipe.credentialEnv,
    outputSources: records.map((record) => ({
      role: record.role,
      file: record.file,
      source: record.source,
    })),
  };
  ensureBuildPath(manifestPath);
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o644,
  });
  return { manifest, manifestPath };
}

function buildTarget(target, version, catalog) {
  if (target.releaseSupported !== true) {
    fail("client_platform_release_target_blocked");
  }
  const recipe = recipeFor(target, version);
  preflight(target, recipe);
  clearDeclaredSources(target, version);
  const sourceDigest = clientSourceStateDigest(workspaceRoot, CANONICAL_CLIENT_SOURCE_ROOTS);
  const targetCatalogDigest = catalogDigest();
  for (const command of recipe.commands) runCommand(command);
  materializeDeclaredSources(target, version);
  const manifestResult = writeBuildManifest(
    target,
    version,
    recipe,
    sourceDigest,
    targetCatalogDigest,
  );
  const sourceDigestAfterBuild = clientSourceStateDigest(workspaceRoot, CANONICAL_CLIENT_SOURCE_ROOTS);
  if (sourceDigestAfterBuild !== sourceDigest) fail("client_platform_release_source_changed");
  const outputSources = target.artifacts
    .filter((artifact) => artifact.role !== "checksum")
    .map((artifact) => sourceRelative(artifactSource(target, artifact, version)));
  return {
    ok: true,
    targetId: target.id,
    productVersion: version.productVersion,
    buildNumber: version.buildNumber,
    sourceStateDigest: sourceDigest,
    targetCatalogDigest,
    outputSources,
    buildManifestSource: sourceRelative(manifestResult.manifestPath),
    artifactDigest: manifestResult.manifest.artifactDigest,
    privatePathsIncluded: false,
  };
}

export function describePlatformReleasePackages({ targetId = "" } = {}) {
  const catalog = loadClientReleaseTargetCatalog(catalogPath);
  const version = loadVersion();
  const sourceDigest = clientSourceStateDigest(workspaceRoot, CANONICAL_CLIENT_SOURCE_ROOTS);
  const targetCatalogDigest = catalogDigest();
  const targets = targetId
    ? [selectTarget(catalog, targetId)]
    : catalog.targets;
  const descriptions = targets.map((target) =>
    descriptionFor(target, version, sourceDigest, targetCatalogDigest));
  if (targetId) return descriptions[0];
  return Object.freeze({
    ok: true,
    dryRun: true,
    targetCount: descriptions.length,
    targets: descriptions,
    privatePathsIncluded: false,
  });
}

export function runPlatformReleasePackage(argv = process.argv.slice(2), {
  emit = (record) => process.stdout.write(`${JSON.stringify(record, null, 2)}\n`),
} = {}) {
  const options = parseArgs(argv);
  if (options.describe) {
    const result = describePlatformReleasePackages({ targetId: options.targetId });
    emit({ ok: true, dryRun: true, ...(result.targets ? result : result), ...(!result.targets ? {} : {}) });
    return result;
  }
  const catalog = loadClientReleaseTargetCatalog(catalogPath);
  const target = selectTarget(catalog, options.targetId);
  const version = loadVersion();
  const result = buildTarget(target, version, catalog);
  emit(result);
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    runPlatformReleasePackage();
  } catch (error) {
    const code = error instanceof PlatformReleaseBuilderError
      ? error.code
      : "client_platform_release_failed";
    process.stderr.write(`${JSON.stringify({
      ok: false,
      code,
      privatePathsIncluded: false,
    })}\n`);
    process.exitCode = 1;
  }
}
