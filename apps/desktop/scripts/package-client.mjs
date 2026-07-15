import {
  chmodSync,
  copyFileSync,
  cpSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync
} from "node:fs";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  clientPubCacheRoot,
  withClientToolchainEnv
} from "../../../tools/scripts/client-toolchain-env.mjs";
import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  clientSourceStateDigest,
  createClientSourceManifest,
  readAndVerifyClientSourceManifest,
} from "../../../tools/scripts/lib/client-source-state-digest.mjs";
import {
  resolveContainedExistingPath,
  sha256Buffer,
  sha256File,
  stableReadFileSnapshot,
} from "../../../tools/scripts/lib/client-release-artifact-digest.mjs";
import { inspectWindowsPeFile } from "../../../tools/scripts/lib/windows-pe-facts.mjs";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const flutterClientRoot = path.join(workspaceRoot, "apps", "desktop");
const clientBuildRoot = path.join(workspaceRoot, "build", "apps", "desktop");
const nativeTargetRoot = path.join(workspaceRoot, "build", "crates", "lico-client-native", "target");
const defaultConfigPath = path.join(flutterClientRoot, "packaging.modules.json");
const PACKAGING_MODULES_SCHEMA_VERSION = "v0.0.1:client-desktop:packaging-modules-1";
const BUNDLE_MANIFEST_SCHEMA_VERSION = "v0.0.1:client-desktop:bundle-manifest-2";
const WINDOWS_PLATFORM_MANIFEST_SCHEMA_VERSION = "v0.0.1:client-desktop:windows-platform-manifest-1";
const WINDOWS_X64_TARGET_ID = "windows-x64";
const WINDOWS_X64_RUST_TARGET = "x86_64-pc-windows-msvc";
const licoClientBundleId = "com.lico.client";
const licoClientAppName = "Arc.app";
const clientLocalRuntimePackageRoot = path.join(
  workspaceRoot,
  "build",
  "client-runtime",
  "client-local-runtime"
);
const clientLocalRuntimeSourceRoot = path.join(clientLocalRuntimePackageRoot, "source");
const clientLocalRuntimeBuildScript = path.join(
  workspaceRoot,
  "tools",
  "client-runtime",
  "build-client-runtime-package.mjs"
);
const clientSourceRoots = CANONICAL_CLIENT_SOURCE_ROOTS;
const sourceDigestPattern = /^sha256:[a-f0-9]{64}$/u;
const canonicalPackagingConfigRef = "apps/desktop/packaging.modules.json";
const canonicalBundleManifestRef =
  "package-metadata/lico-client/packaging-modules.json";
const packagingModuleIdPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/u;
const packagingArtifactNamePattern = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/u;
const packagingPlatforms = Object.freeze(["macos", "linux", "windows"]);
const packagingKinds = Object.freeze([
  "flutter-app",
  "module-resources",
  "portable-data",
  "runtime-capability",
  "sidecar-binary",
  "swift-sidecar",
]);

class PackageClientError extends Error {
  constructor(code, details = null) {
    super(code);
    this.code = code;
    this.details = details;
  }
}

function packageFailure(code, details = null) {
  throw new PackageClientError(code, details);
}

function parseArgs(argv = process.argv.slice(2)) {
  const options = {
    platform: normalizePlatform(process.platform),
    mode: "release",
    configPath: defaultConfigPath,
    enabledOverrides: [],
    disabledOverrides: [],
    profile: null,
    skipFlutterBuild: false,
    skipNativeBuild: false,
    keepFlutterBuildCache: process.env.LICO_KEEP_FLUTTER_BUILD_CACHE === "1",
    install: false,
    installDir: "",
    dryRun: false,
    productionEntitlements: false,
    targetId: ""
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];
    if (arg === "--platform" && next) {
      options.platform = normalizePlatform(next);
      index += 1;
    } else if (arg === "--mode" && next) {
      options.mode = normalizeMode(next);
      index += 1;
    } else if (arg === "--config" && next) {
      options.configPath = path.resolve(next);
      index += 1;
    } else if ((arg === "--with" || arg === "--modules") && next) {
      options.enabledOverrides.push(...splitList(next));
      index += 1;
    } else if (arg === "--without" && next) {
      options.disabledOverrides.push(...splitList(next));
      index += 1;
    } else if (arg === "--profile" && next) {
      options.profile = normalizeProfile(next);
      index += 1;
    } else if (arg === "--skip-flutter-build") {
      options.skipFlutterBuild = true;
    } else if (arg === "--skip-native-build") {
      options.skipNativeBuild = true;
    } else if (arg === "--keep-flutter-build-cache") {
      options.keepFlutterBuildCache = true;
    } else if (arg === "--install") {
      options.install = true;
    } else if (arg === "--install-dir" && next) {
      options.installDir = path.resolve(next);
      index += 1;
    } else if (arg === "--production-entitlements") {
      if (next && !next.startsWith("--")) {
        options.productionEntitlements = normalizeBooleanOption(next, arg);
        index += 1;
      } else {
        options.productionEntitlements = true;
      }
    } else if (arg === "--target" && next) {
      options.targetId = String(next).trim();
      index += 1;
    } else if (arg === "--dry-run") {
      options.dryRun = true;
      options.skipFlutterBuild = true;
      options.skipNativeBuild = true;
    } else {
      throw new Error(`Unknown packaging option: ${arg}`);
    }
  }
  validatePackagingOptions(options);
  return options;
}

function normalizeBooleanOption(value, optionName) {
  const normalized = String(value || "").trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) {
    return true;
  }
  if (["0", "false", "no", "off"].includes(normalized)) {
    return false;
  }
  throw new Error(`Unsupported boolean value for ${optionName}: ${value}`);
}

function validatePackagingOptions(options) {
  if (options.platform === "windows") {
    options.targetId ||= String(process.env.LICO_WINDOWS_TARGET || WINDOWS_X64_TARGET_ID).trim();
    if (options.targetId === "windows-arm64") {
      packageFailure("windows_arm64_flutter_upstream_unavailable");
    }
    if (options.targetId !== WINDOWS_X64_TARGET_ID) {
      packageFailure("windows_target_unsupported");
    }
  } else if (options.targetId) {
    packageFailure("packaging_target_not_supported_for_platform");
  }
  validateReleaseBuildPolicy(options);
  if (!options.productionEntitlements) {
    return;
  }
  if (options.platform !== "macos") {
    throw new Error("--production-entitlements is supported only for macOS packaging.");
  }
  if (options.mode !== "release") {
    throw new Error("--production-entitlements requires --mode release.");
  }
  if (!options.dryRun) {
    macosAppIdentifierPrefix();
  }
}

export function validateReleaseBuildPolicy(options) {
  if (options.mode === "release" && options.dryRun !== true &&
    (options.skipFlutterBuild === true || options.skipNativeBuild === true)) {
    packageFailure("release_build_skip_not_permitted");
  }
  if (options.mode === "release" &&
    path.resolve(options.configPath || defaultConfigPath) !== defaultConfigPath) {
    packageFailure("release_packaging_config_not_canonical");
  }
  if (options.mode === "release" &&
    ((options.enabledOverrides || []).length > 0 ||
      (options.disabledOverrides || []).length > 0 || options.profile !== null)) {
    packageFailure("release_packaging_override_not_permitted");
  }
  return true;
}

export function assertReleaseSourceDigestStable(before, after) {
  if (!sourceDigestPattern.test(String(before || "")) || before !== after) {
    packageFailure("release_source_changed_during_build");
  }
  return true;
}

export function diffReleaseSourceManifests(before, after, limit = 32) {
  const beforeEntries = new Map((before?.entries || []).map((entry) => [entry.path, entry]));
  const afterEntries = new Map((after?.entries || []).map((entry) => [entry.path, entry]));
  const changed = [];
  for (const sourceRef of [...new Set([...beforeEntries.keys(), ...afterEntries.keys()])].sort()) {
    const left = beforeEntries.get(sourceRef);
    const right = afterEntries.get(sourceRef);
    if (!left || !right || left.digest !== right.digest || left.mode !== right.mode || left.size !== right.size) {
      changed.push(sourceRef);
    }
  }
  return Object.freeze({
    changedSourceCount: changed.length,
    changedSourceRefs: changed.slice(0, limit),
    truncated: changed.length > limit,
  });
}

function splitList(value) {
  return String(value || "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function publicWorkspacePath(filePath, fallback = "<external-config>") {
  const relative = path.relative(workspaceRoot, path.resolve(filePath));
  if (!relative || relative === ".") {
    return ".";
  }
  if (relative.startsWith("..") || path.isAbsolute(relative)) {
    return fallback;
  }
  return relative.split(path.sep).join("/");
}

function normalizeProfile(value) {
  const normalized = String(value || "").trim();
  if (normalized === "lico-client") {
    return normalized;
  }
  throw new Error(`Unsupported client package profile: ${value}`);
}

function normalizePlatform(value) {
  const normalized = String(value || "").toLowerCase();
  if (normalized === "darwin") {
    return "macos";
  }
  if (normalized === "win32") {
    return "windows";
  }
  if (["macos", "linux", "windows"].includes(normalized)) {
    return normalized;
  }
  throw new Error(`Unsupported client package platform: ${value}`);
}

function normalizeMode(value) {
  const normalized = String(value || "").toLowerCase();
  if (["debug", "profile", "release"].includes(normalized)) {
    return normalized;
  }
  throw new Error(`Unsupported client package mode: ${value}`);
}

function modeDirectoryName(mode) {
  return mode.charAt(0).toUpperCase() + mode.slice(1);
}

function quoteWindowsCommandArg(value) {
  const text = String(value);
  if (text.length === 0) {
    return '""';
  }
  if (!/[\s"&()^|<>]/.test(text)) {
    return text;
  }
  return `"${text.replaceAll('"', '""')}"`;
}

function run(command, args, options = {}) {
  const {
    failureCode = "package_subprocess_failed",
    ...executionOptions
  } = options;
  try {
    if (process.platform === "win32" && /\.(?:bat|cmd)$/i.test(command)) {
      const commandLine = ["call", command, ...args].map(quoteWindowsCommandArg).join(" ");
      execFileSync(process.env.ComSpec || "cmd.exe", ["/d", "/s", "/c", commandLine], {
        cwd: workspaceRoot,
        stdio: "pipe",
        windowsHide: true,
        ...executionOptions
      });
      return;
    }
    execFileSync(command, args, {
      cwd: workspaceRoot,
      stdio: "pipe",
      ...executionOptions
    });
  } catch (error) {
    const detail = [
      error?.stdout?.toString?.() || "",
      error?.stderr?.toString?.() || "",
      error?.message || "",
    ].join("\n").trim();
    if (detail) {
      console.error(detail.slice(-4000));
    }
    packageFailure(failureCode);
  }
}

function flutterCommand() {
  return process.platform === "win32" ? "flutter.bat" : "flutter";
}

function runFlutter(args, options = {}) {
  if (process.platform === "win32") {
    run(flutterCommand(), args, options);
    return;
  }
  run(flutterCommand(), args, options);
}

function canCreateSymlink() {
  const root = path.join(os.tmpdir(), `lico-client-symlink-${process.pid}-${Date.now()}`);
  const target = path.join(root, "target.txt");
  const link = path.join(root, "link.txt");
  try {
    mkdirSync(root, { recursive: true });
    writeFileSync(target, "ok\n", "utf8");
    symlinkSync(target, link);
    return true;
  } catch {
    return false;
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function canCreateWindowsJunction() {
  if (process.platform !== "win32") {
    return false;
  }
  const root = path.join(os.tmpdir(), `lico-client-junction-${process.pid}-${Date.now()}`);
  const target = path.join(root, "target");
  const link = path.join(root, "link");
  try {
    mkdirSync(target, { recursive: true });
    symlinkSync(target, link, "junction");
    return true;
  } catch {
    return false;
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function canUseWindowsJunctionPluginFallback(options) {
  return process.platform === "win32" && options.platform === "windows" && canCreateWindowsJunction();
}

function assertFlutterBuildPrereqs(options) {
  if (options.skipFlutterBuild || options.dryRun) {
    return;
  }
  try {
    runFlutter(["--version"], {
      stdio: "ignore",
      failureCode: "flutter_toolchain_unavailable",
    });
  } catch {
    throw new Error(
      "Flutter executable was not found on PATH. Install Flutter desktop tooling or add Flutter's bin directory to PATH before packaging."
    );
  }
  if (options.platform === "windows" && !canCreateSymlink() && !canUseWindowsJunctionPluginFallback(options)) {
    throw new Error(
      "Windows Flutter desktop packaging requires symlink support for plugins. " +
        "Enable Windows Developer Mode or run in an elevated shell, then retry client:build:windows."
    );
  }
  if (options.platform === "windows" && !canCreateSymlink()) {
    console.warn(
      "[package-client] Windows symlink creation is unavailable; using NTFS junctions for Flutter plugin staging."
    );
  }
}

function defaultCleanBuildRoot() {
  if (process.platform === "darwin") {
    return path.join(path.sep, "private", "tmp", "lico-client-build");
  }
  if (process.platform === "win32") {
    return path.join(os.tmpdir(), "lico-client-build");
  }
  return path.join(path.sep, "tmp", "lico-client-build");
}

function cleanBuildBaseRoot() {
  return path.resolve(process.env.LICO_CLIENT_CLEAN_BUILD_ROOT || defaultCleanBuildRoot());
}

const cleanBuildRunId = `run-${process.pid}-${Date.now()}-${randomUUID()}`;

function cleanBuildRoot() {
  return path.join(cleanBuildBaseRoot(), cleanBuildRunId);
}

function stagedFlutterClientRoot() {
  return path.join(cleanBuildRoot(), "source", "apps", "desktop");
}

function actualPubCacheRoot() {
  return clientPubCacheRoot();
}

function stagedPubCacheRoot() {
  return path.join(cleanBuildRoot(), "pub-cache");
}

function assertOutsideWorkspace(targetPath, label) {
  const relativePath = path.relative(workspaceRoot, targetPath);
  if (!relativePath || (!relativePath.startsWith("..") && !path.isAbsolute(relativePath))) {
    throw new Error(`${label} must be outside the LicoLite workspace: ${targetPath}`);
  }
}

function buildSymbolsRoot(options) {
  return path.join(clientBuildRoot, "symbols", options.platform, options.mode);
}

function readJson(filePath) {
  return JSON.parse(readFileSync(filePath, "utf8"));
}

function copyTree(source, target, options = {}) {
  cpSync(source, target, {
    recursive: true,
    dereference: false,
    verbatimSymlinks: true,
    ...options
  });
}

function trimYamlScalar(value) {
  const trimmed = String(value || "").trim();
  if (
    (trimmed.startsWith("\"") && trimmed.endsWith("\"")) ||
    (trimmed.startsWith("'") && trimmed.endsWith("'"))
  ) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

function pubCacheHostForUrl(value) {
  const normalized = trimYamlScalar(value || "https://pub.dev");
  try {
    return new URL(normalized).host || "pub.dev";
  } catch {
    return normalized || "pub.dev";
  }
}

function lockedHostedPackages(lockFilePath) {
  const packages = [];
  let current = null;
  const finishCurrent = () => {
    if (!current || current.source !== "hosted") {
      return;
    }
    if (!current.version) {
      throw new Error(`Hosted pub package has no locked version: ${current.name}`);
    }
    packages.push({
      name: current.descriptionName || current.name,
      version: current.version,
      host: pubCacheHostForUrl(current.url)
    });
  };

  for (const line of readFileSync(lockFilePath, "utf8").split(/\r?\n/)) {
    const packageMatch = /^  ([A-Za-z0-9_]+):\s*$/.exec(line);
    if (packageMatch) {
      finishCurrent();
      current = {
        name: packageMatch[1],
        descriptionName: null,
        source: null,
        url: null,
        version: null
      };
      continue;
    }
    if (!current) {
      continue;
    }
    const sourceMatch = /^    source:\s+(.+?)\s*$/.exec(line);
    if (sourceMatch) {
      current.source = trimYamlScalar(sourceMatch[1]);
      continue;
    }
    const versionMatch = /^    version:\s+(.+?)\s*$/.exec(line);
    if (versionMatch) {
      current.version = trimYamlScalar(versionMatch[1]);
      continue;
    }
    const descriptionNameMatch = /^      name:\s+(.+?)\s*$/.exec(line);
    if (descriptionNameMatch) {
      current.descriptionName = trimYamlScalar(descriptionNameMatch[1]);
      continue;
    }
    const urlMatch = /^      url:\s+(.+?)\s*$/.exec(line);
    if (urlMatch) {
      current.url = trimYamlScalar(urlMatch[1]);
    }
  }
  finishCurrent();
  return packages;
}

function copyLockedHostedPackage(sourcePubCache, stagedPubCache, packageRef) {
  const packageDirName = `${packageRef.name}-${packageRef.version}`;
  const sourcePackageDir = path.join(sourcePubCache, "hosted", packageRef.host, packageDirName);
  if (!existsSync(sourcePackageDir)) {
    throw new Error(
      `Locked pub package is missing from the local cache: ${packageDirName}. Run ` +
        `"flutter pub get" in ${flutterClientRoot} before packaging.`
    );
  }

  const stagedPackageDir = path.join(stagedPubCache, "hosted", packageRef.host, packageDirName);
  mkdirSync(path.dirname(stagedPackageDir), { recursive: true });
  copyTree(sourcePackageDir, stagedPackageDir);

  const sourceHashFile = path.join(sourcePubCache, "hosted-hashes", packageRef.host, `${packageDirName}.sha256`);
  if (existsSync(sourceHashFile)) {
    const stagedHashFile = path.join(stagedPubCache, "hosted-hashes", packageRef.host, `${packageDirName}.sha256`);
    mkdirSync(path.dirname(stagedHashFile), { recursive: true });
    copyFileSync(sourceHashFile, stagedHashFile);
  }
}

function requirePlainObject(value, code) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    packageFailure(code);
  }
  return value;
}

function requireExactKeys(value, allowed, code) {
  requirePlainObject(value, code);
  if (Object.keys(value).some((key) => !allowed.has(key))) packageFailure(code);
}

function safeConfigRelativePath(value, code) {
  const ref = String(value || "");
  const components = ref.split("/");
  if (!ref || ref !== ref.trim() || path.isAbsolute(ref) || ref.includes("\\") ||
    ref.includes("\0") || path.posix.normalize(ref) !== ref ||
    components.some((component) => !component || component === "." || component === "..")) {
    packageFailure(code);
  }
  return ref;
}

function validateStringList(value, predicate, code) {
  if (!Array.isArray(value) || new Set(value).size !== value.length ||
    value.some((entry) => typeof entry !== "string" || !predicate(entry))) {
    packageFailure(code);
  }
}

export function validatePackagingConfig(config, {
  sourceRoot = workspaceRoot,
} = {}) {
  requireExactKeys(config, new Set([
    "schemaVersion", "description", "packageProfile", "bundle", "modules",
    "deferredCapabilities",
  ]), "packaging_config_schema_invalid");
  if (config.schemaVersion !== PACKAGING_MODULES_SCHEMA_VERSION ||
    config.packageProfile !== "lico-client" ||
    typeof config.description !== "string" || !config.description.trim()) {
    packageFailure("packaging_config_schema_invalid");
  }
  requireExactKeys(config.bundle, new Set([
    "moduleResourceDirectory", "manifestPath",
  ]), "packaging_bundle_schema_invalid");
  if (config.bundle.moduleResourceDirectory !== "modules" ||
    config.bundle.manifestPath !== canonicalBundleManifestRef) {
    packageFailure("packaging_bundle_path_invalid");
  }
  const modules = requirePlainObject(config.modules, "packaging_modules_invalid");
  const moduleIds = Object.keys(modules);
  if (moduleIds.length === 0 || new Set(moduleIds).size !== moduleIds.length ||
    moduleIds.some((id) => !packagingModuleIdPattern.test(id))) {
    packageFailure("packaging_module_id_invalid");
  }
  const knownIds = new Set(moduleIds);
  const moduleKeys = new Set([
    "artifactName", "cargoBin", "category", "enabled", "includePaths", "label",
    "packaging", "platforms", "portableDirectories", "profile", "required",
    "requires", "runtimeToggle", "settingsKeys", "stateDirectories", "swiftSource",
    "targetAdapters",
  ]);
  for (const [id, moduleConfig] of Object.entries(modules)) {
    requireExactKeys(moduleConfig, moduleKeys, "packaging_module_schema_invalid");
    if (typeof moduleConfig.label !== "string" || !moduleConfig.label.trim() ||
      typeof moduleConfig.category !== "string" || !moduleConfig.category.trim() ||
      !packagingKinds.includes(moduleConfig.packaging) ||
      typeof moduleConfig.enabled !== "boolean" ||
      typeof moduleConfig.required !== "boolean") {
      packageFailure("packaging_module_schema_invalid");
    }
    validateStringList(moduleConfig.platforms, (entry) =>
      packagingPlatforms.includes(entry), "packaging_module_platform_invalid");
    validateStringList(moduleConfig.requires || [], (entry) =>
      packagingModuleIdPattern.test(entry) && knownIds.has(entry),
    "packaging_module_dependency_invalid");
    for (const field of ["portableDirectories", "stateDirectories"]) {
      validateStringList(moduleConfig[field] || [], (entry) => {
        try {
          safeConfigRelativePath(entry, "packaging_module_target_path_invalid");
          return true;
        } catch {
          return false;
        }
      }, "packaging_module_target_path_invalid");
    }
    validateStringList(moduleConfig.targetAdapters || [], (entry) =>
      packagingModuleIdPattern.test(entry), "packaging_target_adapter_id_invalid");
    validateStringList(moduleConfig.settingsKeys || [], (entry) =>
      /^[a-z][A-Za-z0-9-]*(?:\.[a-z][A-Za-z0-9-]*)+$/u.test(entry),
    "packaging_settings_key_invalid");
    if (moduleConfig.runtimeToggle !== undefined &&
      typeof moduleConfig.runtimeToggle !== "boolean") {
      packageFailure("packaging_runtime_toggle_invalid");
    }
    if (moduleConfig.cargoBin !== undefined &&
      !packagingModuleIdPattern.test(moduleConfig.cargoBin)) {
      packageFailure("packaging_cargo_bin_invalid");
    }
    if (moduleConfig.artifactName !== undefined &&
      !packagingArtifactNamePattern.test(moduleConfig.artifactName)) {
      packageFailure("packaging_artifact_name_invalid");
    }
    if (moduleConfig.swiftSource !== undefined) {
      const sourceRef = safeConfigRelativePath(
        moduleConfig.swiftSource,
        "packaging_swift_source_invalid",
      );
      if (!sourceRef.startsWith("apps/desktop/macos/") ||
        moduleConfig.packaging !== "swift-sidecar") {
        packageFailure("packaging_swift_source_invalid");
      }
      resolveContainedExistingPath(sourceRoot, path.join(sourceRoot, sourceRef), {
        expectedKind: "file",
      });
    } else if (moduleConfig.packaging === "swift-sidecar") {
      packageFailure("packaging_swift_source_invalid");
    }
    for (const includePath of moduleConfig.includePaths || []) {
      const includeRef = safeConfigRelativePath(
        includePath,
        "packaging_resource_source_invalid",
      );
      resolveContainedExistingPath(sourceRoot, path.join(sourceRoot, includeRef));
    }
    if (moduleConfig.profile !== undefined &&
      (typeof moduleConfig.profile !== "string" || !moduleConfig.profile.trim())) {
      packageFailure("packaging_module_profile_invalid");
    }
    if (id === "native-sidecar" && moduleConfig.cargoBin !== "lico-client") {
      packageFailure("packaging_native_sidecar_authority_invalid");
    }
  }
  requirePlainObject(config.deferredCapabilities, "packaging_deferred_schema_invalid");
  for (const [id, capability] of Object.entries(config.deferredCapabilities)) {
    if (!packagingModuleIdPattern.test(id)) {
      packageFailure("packaging_deferred_id_invalid");
    }
    requireExactKeys(capability, new Set(["status", "reason"]),
      "packaging_deferred_schema_invalid");
    if (capability.status !== "todo" || typeof capability.reason !== "string" ||
      !capability.reason.trim()) {
      packageFailure("packaging_deferred_schema_invalid");
    }
  }
  return config;
}

function loadPackagingConfig(configPath, options) {
  const snapshot = stableReadFileSnapshot(configPath, { maxBytes: 2 * 1024 * 1024 });
  const config = validatePackagingConfig(JSON.parse(snapshot.bytes.toString("utf8")));
  options.packagingConfigDigest = sha256Buffer(snapshot.bytes);
  return config;
}

function platformSupported(moduleConfig, platform) {
  const platforms = Array.isArray(moduleConfig.platforms) ? moduleConfig.platforms : [];
  return platforms.length === 0 || platforms.includes(platform);
}

function selectModules(config, options) {
  const activeProfile = options.profile || config.packageProfile || "lico-client";
  if (activeProfile !== "lico-client") {
    throw new Error(`Unsupported client package profile: ${activeProfile}`);
  }
  const modules = Object.entries(config.modules).map(([id, moduleConfig]) => ({
    id,
    ...moduleConfig
  }));
  const overrides = new Map();
  for (const id of options.enabledOverrides) {
    overrides.set(id, true);
  }
  for (const id of options.disabledOverrides) {
    overrides.set(id, false);
  }

  const knownIds = new Set(modules.map((item) => item.id));
  for (const id of overrides.keys()) {
    if (!knownIds.has(id)) {
      throw new Error(`Unknown client packaging module override: ${id}`);
    }
  }

  const selected = [];
  const skipped = [];
  for (const moduleConfig of modules) {
    const supported = platformSupported(moduleConfig, options.platform);
    const enabled = overrides.has(moduleConfig.id)
      ? overrides.get(moduleConfig.id)
      : moduleConfig.enabled !== false;
    if (!supported) {
      skipped.push({ ...moduleConfig, status: "skipped-platform" });
      continue;
    }
    if (moduleConfig.required && !enabled) {
      throw new Error(`Required client packaging module cannot be disabled: ${moduleConfig.id}`);
    }
    if (!enabled) {
      skipped.push({ ...moduleConfig, status: "disabled" });
      continue;
    }
    selected.push({ ...moduleConfig, status: "enabled" });
  }

  const selectedIds = new Set(selected.map((item) => item.id));
  for (const moduleConfig of selected) {
    for (const dependency of moduleConfig.requires || []) {
      if (!selectedIds.has(dependency)) {
        throw new Error(
          `Client packaging module ${moduleConfig.id} requires disabled or unsupported module ${dependency}`
        );
      }
    }
  }
  return { selected, skipped };
}

function cargoProfile(mode) {
  return mode === "release" ? "release" : "debug";
}

function cargoTargetDir(mode, options = {}) {
  return options.platform === "windows"
    ? path.join(nativeTargetRoot, WINDOWS_X64_RUST_TARGET, cargoProfile(mode))
    : path.join(nativeTargetRoot, cargoProfile(mode));
}

function cargoHome() {
  return process.env.CARGO_HOME || path.join(os.homedir(), ".cargo");
}

function rustFlagsWithPathRemap() {
  const pathRemapFlags = [
    `--remap-path-prefix=${workspaceRoot}=/lico/source`,
    `--remap-path-prefix=${cargoHome()}=/cargo`
  ];
  return [process.env.RUSTFLAGS, ...pathRemapFlags].filter(Boolean).join(" ");
}

function binarySuffix(platform) {
  return platform === "windows" ? ".exe" : "";
}

function buildNativeSidecars(selected, options) {
  const bins = [
    ...new Set(
      selected
        .filter((item) => item.cargoBin)
        .map((item) => item.cargoBin)
    )
  ];
  if (bins.length === 0 || options.skipNativeBuild || options.dryRun) {
    return;
  }
  const args = ["build", "--manifest-path", path.join("crates", "lico-client-native", "Cargo.toml")];
  if (options.mode === "release") {
    args.push("--release", "--locked");
  }
  if (options.platform === "windows") {
    args.push("--target", WINDOWS_X64_RUST_TARGET);
  }
  for (const bin of bins) {
    args.push("--bin", bin);
  }
  run("cargo", args, {
    failureCode: "native_sidecar_build_failed",
    env: {
      ...process.env,
      CARGO_TARGET_DIR: nativeTargetRoot,
      RUSTFLAGS: rustFlagsWithPathRemap()
    }
  });
}

function buildSwiftSidecars(selected, options) {
  if (options.platform !== "macos" || options.skipNativeBuild || options.dryRun) {
    return;
  }
  for (const moduleConfig of selected.filter((item) => item.packaging === "swift-sidecar")) {
    const source = path.join(workspaceRoot, moduleConfig.swiftSource || "");
    const artifactName = moduleConfig.artifactName || moduleConfig.id;
    const target = path.join(cargoTargetDir(options.mode, options), artifactName);
    mkdirSync(path.dirname(target), { recursive: true });
    run("xcrun", ["swiftc", "-parse-as-library", "-O", "-o", target, source], {
      failureCode: "swift_sidecar_build_failed",
    });
    chmodSync(target, 0o755);
  }
}

function isExcludedFlutterSourcePath(sourcePath) {
  const relativePath = path.relative(flutterClientRoot, sourcePath);
  if (!relativePath || relativePath.startsWith("..") || path.isAbsolute(relativePath)) {
    return false;
  }
  const parts = relativePath.split(path.sep);
  const normalized = parts.join("/");
  const topLevel = parts[0];
  if ([".dart_tool", ".idea", "build", ".flutter-plugins", ".flutter-plugins-dependencies"].includes(topLevel)) {
    return true;
  }
  return [
    "macos/Flutter/ephemeral",
    "macos/Pods",
    "macos/Podfile.lock",
    "linux/flutter/ephemeral",
    "windows/flutter/ephemeral",
    "android/.gradle",
    "android/build"
  ].some((prefix) => normalized === prefix || normalized.startsWith(`${prefix}/`));
}

function prepareStagedPubCache() {
  const stagedPubCache = stagedPubCacheRoot();
  const sourcePubCache = actualPubCacheRoot();
  assertOutsideWorkspace(stagedPubCache, "clean build pub cache");
  if (path.resolve(sourcePubCache) === path.resolve(stagedPubCache)) {
    mkdirSync(stagedPubCache, { recursive: true });
    return stagedPubCache;
  }
  rmSync(stagedPubCache, { recursive: true, force: true });
  mkdirSync(stagedPubCache, { recursive: true });
  if (!existsSync(sourcePubCache)) {
    const pubGetHint = process.platform === "win32"
      ? `run "dart pub get" in ${flutterClientRoot}`
      : `run "flutter pub get" in ${flutterClientRoot}`;
    throw new Error(
      `Local Flutter/Dart pub cache does not exist: ${sourcePubCache}. ` +
        `Install Flutter for desktop builds or ${pubGetHint} before packaging. ` +
        "Set PUB_CACHE to a populated cache when using an alternate Flutter installation."
    );
  }
  for (const packageRef of lockedHostedPackages(path.join(flutterClientRoot, "pubspec.lock"))) {
    copyLockedHostedPackage(sourcePubCache, stagedPubCache, packageRef);
  }
  return stagedPubCache;
}

function prepareStagedFlutterSource() {
  const stagedRoot = stagedFlutterClientRoot();
  assertOutsideWorkspace(stagedRoot, "clean Flutter build source");
  rmSync(stagedRoot, { recursive: true, force: true });
  mkdirSync(path.dirname(stagedRoot), { recursive: true });
  copyTree(flutterClientRoot, stagedRoot, {
    filter: (sourcePath) => !isExcludedFlutterSourcePath(sourcePath)
  });
  return stagedRoot;
}

function desktopPluginLinkRoot(projectRoot, platform) {
  return path.join(projectRoot, platform, "flutter", "ephemeral", ".plugin_symlinks");
}

function createDesktopPluginJunctions(projectRoot) {
  const dependenciesPath = path.join(projectRoot, ".flutter-plugins-dependencies");
  if (!existsSync(dependenciesPath)) {
    throw new Error(`Flutter plugin metadata is missing: ${dependenciesPath}`);
  }
  const dependencies = readJson(dependenciesPath);
  let created = 0;
  for (const platform of ["windows", "linux"]) {
    const platformRoot = path.join(projectRoot, platform);
    const plugins = dependencies.plugins?.[platform] || [];
    if (!existsSync(platformRoot) || plugins.length === 0) {
      continue;
    }
    const linkRoot = desktopPluginLinkRoot(projectRoot, platform);
    mkdirSync(linkRoot, { recursive: true });
    for (const plugin of plugins) {
      if (!plugin?.name || !plugin?.path) {
        continue;
      }
      const target = path.resolve(plugin.path);
      if (!existsSync(target) || !statSync(target).isDirectory()) {
        throw new Error(`Flutter ${platform} plugin source is missing for ${plugin.name}: ${target}`);
      }
      const link = path.join(linkRoot, plugin.name);
      if (existsSync(link)) {
        continue;
      }
      symlinkSync(target, link, "junction");
      created += 1;
    }
  }
  return created;
}

function runFlutterPubGet(projectRoot, flutterEnv, options) {
  const args = ["pub", "get", "--offline"];
  try {
    runFlutter(args, {
      cwd: projectRoot,
      env: flutterEnv
    });
  } catch (error) {
    if (!canUseWindowsJunctionPluginFallback(options)) {
      throw error;
    }
    const created = createDesktopPluginJunctions(projectRoot);
    console.warn(`[package-client] Created ${created} Flutter desktop plugin junction(s); retrying pub get.`);
    runFlutter(args, {
      cwd: projectRoot,
      env: flutterEnv
    });
  }
}

function flutterBuildProjectRoot(options) {
  return options.flutterBuildProjectRoot || flutterClientRoot;
}

function buildFlutterApp(options) {
  if (options.skipFlutterBuild || options.dryRun) {
    return false;
  }
  const stagedRoot = prepareStagedFlutterSource();
  const pubCacheRoot = prepareStagedPubCache();
  options.flutterBuildProjectRoot = stagedRoot;
  cleanStaleFlutterBuildArtifacts(options);
  const flutterEnv = withClientToolchainEnv(process.env, { pubCache: pubCacheRoot });
  runFlutterPubGet(stagedRoot, flutterEnv, options);
  const args = ["build", options.platform, `--${options.mode}`, "--no-pub"];
  // Bind the routing module compile-time flag from the canonical module catalog.
  // In excluded builds this makes routing registration, UI, watchers, policy,
  // and history code tree-shakable and unreachable at runtime.
  const routingIncluded = options.routingModuleIncluded !== false;
  args.push(`--dart-define=LICO_ROUTING_MODULE_INCLUDED=${routingIncluded}`);
  if (process.env.LICO_AGENT_CONVERSATION_RELEASE_LIVE === "1") {
    args.push("--dart-define=LICO_AGENT_CONVERSATION_RELEASE_LIVE=true");
  }
  if (options.mode === "release") {
    const dartSymbolsDir = path.join(buildSymbolsRoot(options), "dart");
    mkdirSync(dartSymbolsDir, { recursive: true });
    args.push(`--split-debug-info=${dartSymbolsDir}`);
  }
  const flutterBuildEnv = options.platform === "macos"
    ? {
        ...flutterEnv,
        LICO_CLIENT_SKIP_XCODE_SIDECAR_BUNDLE: "1"
      }
    : flutterEnv;
  runFlutter(args, {
    cwd: stagedRoot,
    env: flutterBuildEnv,
    failureCode: "flutter_app_build_failed",
  });
  return true;
}

function cleanStaleFlutterBuildArtifacts(options) {
  if (options.platform === "macos") {
    const appDir = path.join(
      flutterBuildProjectRoot(options),
      "build",
      "macos",
      "Build",
      "Products",
      modeDirectoryName(options.mode),
      "flutter_client.app"
    );
    rmSync(appDir, { recursive: true, force: true });
  }
}

function rawFlutterBuildRootForOptions(options) {
  return path.join(flutterBuildProjectRoot(options), "build");
}

function packagedBundleRoot(options) {
  return path.join(clientBuildRoot, "bundles", options.platform, options.mode, "bundle");
}

function runnableClientRoot(options) {
  return path.join(clientBuildRoot, "runnable", options.platform, options.mode);
}

function defaultMacosInstallDir() {
  return "/Applications";
}

function explicitMacosInstallDir(options) {
  if (options.installDir) {
    return path.resolve(options.installDir);
  }
  if (process.env.LICO_CLIENT_INSTALL_DIR) {
    return path.resolve(process.env.LICO_CLIENT_INSTALL_DIR);
  }
  return "";
}

function readMacosBundleIdentifier(appPath) {
  const plistPath = path.join(appPath, "Contents", "Info.plist");
  if (!existsSync(plistPath)) {
    return "";
  }
  try {
    return execFileSync(
      "/usr/libexec/PlistBuddy",
      ["-c", "Print :CFBundleIdentifier", plistPath],
      {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"]
      }
    ).trim();
  } catch {
    return "";
  }
}

function isInstalledLicoClientApp(appPath) {
  return existsSync(appPath) && readMacosBundleIdentifier(appPath) === licoClientBundleId;
}

function knownMacosInstallCandidates() {
  return [
    path.join(defaultMacosInstallDir(), licoClientAppName),
    path.join(os.homedir(), "Applications", licoClientAppName)
  ];
}

function runningMacosInstallCandidates() {
  try {
    const marker = `${licoClientAppName}/Contents/MacOS/`;
    return execFileSync("ps", ["-axo", "command="], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"]
    })
      .split(/\r?\n/)
      .map((item) => {
        const markerIndex = item.indexOf(marker);
        if (markerIndex < 0) {
          return "";
        }
        return item.slice(0, markerIndex + licoClientAppName.length).trim();
      })
      .filter(Boolean);
  } catch {
    return [];
  }
}

function spotlightMacosInstallCandidates() {
  try {
    return execFileSync("mdfind", [`kMDItemCFBundleIdentifier == "${licoClientBundleId}"`], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"]
    })
      .split(/\r?\n/)
      .map((item) => item.trim())
      .filter((item) => path.basename(item) === licoClientAppName);
  } catch {
    return [];
  }
}

function findInstalledLicoClientApp() {
  const seen = new Set();
  for (const candidate of [
    ...runningMacosInstallCandidates(),
    ...knownMacosInstallCandidates(),
    ...spotlightMacosInstallCandidates()
  ]) {
    const normalized = path.resolve(candidate);
    if (seen.has(normalized)) {
      continue;
    }
    seen.add(normalized);
    if (isMacosBuildArtifactCandidate(normalized)) {
      continue;
    }
    if (isInstalledLicoClientApp(normalized)) {
      return normalized;
    }
  }
  return "";
}

function isMacosBuildArtifactCandidate(candidate) {
  return [workspaceRoot, cleanBuildBaseRoot()].some((root) => isInsideDirectory(root, candidate));
}

function isInsideDirectory(root, candidate) {
  const relative = path.relative(path.resolve(root), path.resolve(candidate));
  return Boolean(relative) && !relative.startsWith("..") && !path.isAbsolute(relative);
}

function macosInstallDir(options) {
  const explicit = explicitMacosInstallDir(options);
  if (explicit) {
    return explicit;
  }
  const existingApp = findInstalledLicoClientApp();
  if (existingApp) {
    return path.dirname(existingApp);
  }
  return defaultMacosInstallDir();
}

function findLinuxBundleSource(options) {
  const linuxBuildRoot = path.join(rawFlutterBuildRootForOptions(options), "linux");
  if (!existsSync(linuxBuildRoot)) {
    throw new Error(`Linux build directory does not exist: ${linuxBuildRoot}`);
  }
  const candidates = [];
  for (const arch of readdirSync(linuxBuildRoot)) {
    const bundleDir = path.join(linuxBuildRoot, arch, options.mode, "bundle");
    if (existsSync(path.join(bundleDir, "flutter_client"))) {
      candidates.push(bundleDir);
    }
  }
  if (candidates.length === 0) {
    throw new Error(`No Flutter Linux ${options.mode} bundle was produced.`);
  }
  candidates.sort((left, right) => statSync(right).mtimeMs - statSync(left).mtimeMs);
  return candidates[0];
}

function findMacosBundleSource(options) {
  const productsDir = path.join(
    rawFlutterBuildRootForOptions(options),
    "macos",
    "Build",
    "Products",
    modeDirectoryName(options.mode)
  );
  const appDir = path.join(productsDir, "flutter_client.app");
  if (!existsSync(path.join(appDir, "Contents", "MacOS", "flutter_client"))) {
    throw new Error(`macOS app bundle was not found: ${appDir}`);
  }
  return productsDir;
}

function findWindowsBundleSource(options) {
  const modeDir = modeDirectoryName(options.mode);
  const candidates = [
    path.join(rawFlutterBuildRootForOptions(options), "windows", "x64", "runner", modeDir),
    path.join(rawFlutterBuildRootForOptions(options), "windows", "runner", modeDir),
  ];
  const bundleDir = candidates.find((item) => existsSync(path.join(item, "flutter_client.exe")));
  if (!bundleDir) {
    throw new Error(`Windows Flutter ${options.mode} bundle was not found.`);
  }
  return bundleDir;
}

function findFlutterBundleSource(options) {
  if (options.platform === "linux") {
    return findLinuxBundleSource(options);
  }
  if (options.platform === "macos") {
    return findMacosBundleSource(options);
  }
  return findWindowsBundleSource(options);
}

function flutterExecutableForRoot(root, platform) {
  if (platform === "macos") {
    return path.join(root, "flutter_client.app", "Contents", "MacOS", "flutter_client");
  }
  return path.join(root, platform === "windows" ? "flutter_client.exe" : "flutter_client");
}

function runnableExecutableForRoot(root, platform) {
  if (platform === "macos") {
    return path.join(root, licoClientAppName, "Contents", "MacOS", "flutter_client");
  }
  return flutterExecutableForRoot(root, platform);
}

function stagedBundleExists(root, platform) {
  return existsSync(flutterExecutableForRoot(root, platform));
}

function stageFlutterBundle(options) {
  const source = findFlutterBundleSource(options);
  const target = packagedBundleRoot(options);
  rmSync(target, { recursive: true, force: true });
  mkdirSync(path.dirname(target), { recursive: true });
  copyTree(source, target);
  return target;
}

function resolveBundle(options) {
  let root = packagedBundleRoot(options);
  if (!stagedBundleExists(root, options.platform)) {
    root = stageFlutterBundle(options);
  }
  if (options.platform === "linux") {
    return {
      root,
      executableDir: root,
      portableDataDir: path.join(root, "portable-data"),
      moduleResourceDir: path.join(root, "modules"),
      flutterExecutable: flutterExecutableForRoot(root, options.platform)
    };
  }
  if (options.platform === "macos") {
    const appDir = path.join(root, "flutter_client.app");
    return {
      root,
      executableDir: path.join(appDir, "Contents", "MacOS"),
      portableDataDir: path.join(root, "portable-data"),
      moduleResourceDir: path.join(root, "modules"),
      flutterExecutable: flutterExecutableForRoot(root, options.platform)
    };
  }
  return {
    root,
    executableDir: root,
    portableDataDir: path.join(root, "portable-data"),
    moduleResourceDir: path.join(root, "modules"),
    flutterExecutable: flutterExecutableForRoot(root, options.platform)
  };
}

function macosAppDirFromBundle(bundle) {
  return path.resolve(bundle.executableDir, "..", "..");
}

function repairMacosFrameworkSymlinks(appDir) {
  const frameworksDir = path.join(appDir, "Contents", "Frameworks");
  if (!existsSync(frameworksDir)) {
    return [];
  }
  const repaired = [];
  for (const entry of readdirSync(frameworksDir)) {
    if (!entry.endsWith(".framework")) {
      continue;
    }
    const frameworkPath = path.join(frameworksDir, entry);
    const frameworkName = path.basename(entry, ".framework");
    const versionsDir = path.join(frameworkPath, "Versions");
    const versionRoot = path.join(versionsDir, "A");
    if (!existsSync(versionRoot)) {
      continue;
    }

    rmSync(path.join(versionsDir, "Current"), { force: true });
    symlinkSync("A", path.join(versionsDir, "Current"));

    const frameworkBinary = path.join(versionRoot, frameworkName);
    if (existsSync(frameworkBinary)) {
      rmSync(path.join(frameworkPath, frameworkName), { force: true });
      symlinkSync(path.join("Versions", "Current", frameworkName), path.join(frameworkPath, frameworkName));
    }

    const frameworkResources = path.join(versionRoot, "Resources");
    if (existsSync(frameworkResources)) {
      rmSync(path.join(frameworkPath, "Resources"), { force: true });
      symlinkSync(path.join("Versions", "Current", "Resources"), path.join(frameworkPath, "Resources"));
    }
    repaired.push(frameworkPath);
  }
  return repaired;
}

function copySidecar(binaryName, bundle, options) {
  const suffix = binarySuffix(options.platform);
  const source = path.join(cargoTargetDir(options.mode, options), `${binaryName}${suffix}`);
  if (!existsSync(source)) {
    throw new Error(`Sidecar binary is missing: ${source}`);
  }
  const target = path.join(bundle.executableDir, `${binaryName}${suffix}`);
  copyFileSync(source, target);
  if (options.platform !== "windows") {
    chmodSync(target, 0o755);
  }
  return target;
}

function copySwiftSidecar(moduleConfig, bundle, options) {
  const artifactName = moduleConfig.artifactName || moduleConfig.id;
  const source = path.join(cargoTargetDir(options.mode, options), artifactName);
  if (!existsSync(source)) {
    throw new Error(`Swift sidecar is missing: ${source}`);
  }
  const target = path.join(bundle.executableDir, artifactName);
  copyFileSync(source, target);
  chmodSync(target, 0o755);
  return target;
}

function copyModuleResources(moduleConfig, bundle) {
  const copied = [];
  for (const includePath of moduleConfig.includePaths || []) {
    const source = path.join(workspaceRoot, includePath);
    if (!existsSync(source)) {
      throw new Error(`Module resource path does not exist: ${source}`);
    }
    const target = path.join(bundle.moduleResourceDir, moduleConfig.id, path.basename(source));
    rmSync(target, { recursive: true, force: true });
    mkdirSync(path.dirname(target), { recursive: true });
    copyTree(source, target);
    copied.push(target);
  }
  return copied;
}

function buildClientLocalRuntimePackage() {
  run(process.execPath, [clientLocalRuntimeBuildScript]);
  if (!existsSync(path.join(clientLocalRuntimeSourceRoot, "feature-profile", "active-features.json"))) {
    throw new Error(
      `Client local runtime feature profile was not generated: ${clientLocalRuntimeSourceRoot}`
    );
  }
  if (!existsSync(path.join(clientLocalRuntimeSourceRoot, "runtime-plan", "runtime-plan.json"))) {
    throw new Error(
      `Client local runtime plan was not generated: ${clientLocalRuntimeSourceRoot}`
    );
  }
  if (!existsSync(path.join(clientLocalRuntimeSourceRoot, "runtime", "start-client-runtime.mjs"))) {
    throw new Error(
      `Client local runtime entry was not generated: ${clientLocalRuntimeSourceRoot}`
    );
  }
}

function bundledClientLocalRuntimeMetadataRoot(bundle, options) {
  if (options.platform === "macos") {
    return path.join(
      macosAppDirFromBundle(bundle),
      "Contents",
      "Resources",
      "lico-runtime",
      "client-local-runtime"
    );
  }
  return path.join(bundle.root, "package-metadata", "client-local-runtime");
}

function copyClientLocalRuntimeMetadata(bundle, options) {
  buildClientLocalRuntimePackage();
  const targetRoot = bundledClientLocalRuntimeMetadataRoot(bundle, options);
  rmSync(targetRoot, { recursive: true, force: true });
  mkdirSync(targetRoot, { recursive: true });
  copyTree(clientLocalRuntimeSourceRoot, targetRoot);
  return targetRoot;
}

function removeSkippedArtifacts(skipped, bundle) {
  for (const moduleConfig of skipped) {
    if (moduleConfig.packaging === "swift-sidecar") {
      const artifactName = moduleConfig.artifactName || moduleConfig.id;
      rmSync(path.join(bundle.executableDir, artifactName), { force: true });
    } else if (moduleConfig.packaging === "module-resources") {
      rmSync(path.join(bundle.moduleResourceDir, moduleConfig.id), { recursive: true, force: true });
    }
  }
}

function updateMacosPlistString(plistPath, key, value) {
  run("plutil", ["-replace", key, "-string", value, plistPath]);
}

function updateMacosAppMetadata(bundle, options) {
  if (options.platform !== "macos") {
    return;
  }
  const plistPath = path.join(macosAppDirFromBundle(bundle), "Contents", "Info.plist");
  if (!existsSync(plistPath)) {
    throw new Error(`macOS Info.plist is missing: ${plistPath}`);
  }
  updateMacosPlistString(plistPath, "CFBundleIdentifier", licoClientBundleId);
  updateMacosPlistString(plistPath, "CFBundleName", "Lico Arc");
  updateMacosPlistString(plistPath, "CFBundleDisplayName", "Arc");
  updateMacosPlistString(
    plistPath,
    "NSHumanReadableCopyright",
    "Copyright (c) 2026 LicoLite. All rights reserved."
  );
}

function targetSkippedModules(skipped) {
  return skipped.filter((item) => item.status !== "skipped-platform");
}

function manifestPathForRoot(config, root) {
  return path.join(
    root,
    config.bundle?.manifestPath || "package-metadata/lico-client/packaging-modules.json"
  );
}

function relativeBundlePath(root, target) {
  const relativePath = path.relative(root, target);
  return relativePath || ".";
}

function runtimeDataPolicyRecord(platform = "generic") {
  return {
    defaultLocation:
      platform === "windows"
        ? "system-appdata"
        : platform === "linux"
          ? "system-xdg-data"
          : "system-application-support",
    directoryName: "portable-data",
    environmentOverride: "LICO_PORTABLE_DIR",
    packagedMacAppIgnoresEnvironmentOverride: true
  };
}

function runtimeDataDescription(platform) {
  if (platform === "windows") {
    return "Runtime data: system AppData portable-data directory";
  }
  if (platform === "linux") {
    return "Runtime data: system XDG data portable-data directory";
  }
  return "Runtime data: system Application Support portable-data directory";
}

export function packageSourceStateBinding(options, {
  environment = process.env,
  sourceDigest = () => clientSourceStateDigest(workspaceRoot, clientSourceRoots),
  verifySourceManifest = (expectedDigest) => readAndVerifyClientSourceManifest(
    workspaceRoot,
    path.join(
      workspaceRoot,
      ".lico-source-attestation",
      "client-source-manifest.json",
    ),
    expectedDigest,
    { expectedSourceRoots: clientSourceRoots },
  ),
} = {}) {
  const attested = String(environment.LICO_CLIENT_EXPECTED_SOURCE_STATE_DIGEST || "").trim();
  if (!attested) {
    return {
      digest: options.releaseSourceStateDigest || sourceDigest(),
      provenance: "git-worktree"
    };
  }
  if (
    options.platform !== "linux" ||
    !/^sha256:[a-f0-9]{64}$/u.test(attested)
  ) {
    throw new Error("Client source-state attestation is invalid for this packaging target.");
  }
  const manifestBinding = verifySourceManifest(attested);
  if (manifestBinding?.ok !== true ||
    manifestBinding.sourceStateDigest !== attested ||
    !/^sha256:[a-f0-9]{64}$/u.test(String(manifestBinding.manifestDigest || ""))) {
    throw new Error("Client source manifest verification did not establish source authority.");
  }
  if (options.releaseSourceStateDigest && attested !== options.releaseSourceStateDigest) {
    packageFailure("release_source_attestation_mismatch");
  }
  return {
    digest: attested,
    provenance: "vm-orchestrator-verified"
  };
}

function preparePortableData(config, selected, skipped, bundle, options) {
  rmSync(bundle.portableDataDir, { recursive: true, force: true });
  const manifestPath = manifestPathForRoot(config, bundle.root);
  mkdirSync(path.dirname(manifestPath), { recursive: true });
  const sourceBinding = packageSourceStateBinding(options);
  const manifest = {
    schemaVersion: BUNDLE_MANIFEST_SCHEMA_VERSION,
    generatedAt: new Date().toISOString(),
    sourceStateDigest: sourceBinding.digest,
    sourceStateDigestProvenance: sourceBinding.provenance,
    platform: options.platform,
    mode: options.mode,
    configPath: publicWorkspacePath(options.configPath),
    packagingConfigDigest: options.packagingConfigDigest,
    bundleRoot: ".",
    flutterExecutable: relativeBundlePath(bundle.root, bundle.flutterExecutable),
    runtimeData: runtimeDataPolicyRecord(options.platform),
    signing: packageSigningPolicyRecord(options),
    featureProfile: config.featureProfile || null,
    modules: selected.map(publicModuleRecord),
    skippedModules: targetSkippedModules(skipped).map(publicModuleRecord)
  };
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  return manifestPath;
}

function publicModuleRecord(moduleConfig) {
  return {
    id: moduleConfig.id,
    label: moduleConfig.label || moduleConfig.id,
    category: moduleConfig.category || "",
    packaging: moduleConfig.packaging || "",
    profile: moduleConfig.profile || "",
    required: moduleConfig.required === true,
    status: moduleConfig.status || ""
  };
}

function writeBundleNotes(config, selected, bundle, options) {
  const lines = [
    `Lico Arc ${options.platform} Client Bundle`,
    "",
    "Run the Flutter desktop frontend from this bundle.",
    "The frontend resolves lico-client as its LicoArc client sidecar.",
    "Run lico-client for command-line operations against the same system data workspace.",
    "",
    "Enabled modules:",
    ...selected.map((item) => `- ${item.id}: ${item.label || item.id}`),
    "",
    `Packaging config: ${path.relative(workspaceRoot, options.configPath)}`,
    `Packaging manifest: ${path.relative(bundle.root, manifestPathForRoot(config, bundle.root))}`,
    runtimeDataDescription(options.platform),
    ""
  ];
  const fileName = options.platform === "windows" ? "README-windows.txt" : `README-${options.platform}.txt`;
  writeFileSync(path.join(bundle.root, fileName), lines.join("\n"), "utf8");
}

function windowsPlatformManifestPath(root) {
  return path.join(root, "package-metadata", "windows", "client-manifest.json");
}

function assertExistingFile(filePath, label) {
  if (!existsSync(filePath) || !statSync(filePath).isFile()) {
    throw new Error(`${label} is missing: ${filePath}`);
  }
}

function writeWindowsPlatformManifest(root, options, kind) {
  if (options.platform !== "windows") {
    return "";
  }
  const flutterExecutable = flutterExecutableForRoot(root, options.platform);
  const licoClientExecutable = path.join(root, "lico-client.exe");
  assertExistingFile(flutterExecutable, `${kind} Windows Flutter executable`);
  assertExistingFile(licoClientExecutable, `${kind} Windows lico-client sidecar`);
  const manifestPath = windowsPlatformManifestPath(root);
  mkdirSync(path.dirname(manifestPath), { recursive: true });
  const manifest = {
    schemaVersion: WINDOWS_PLATFORM_MANIFEST_SCHEMA_VERSION,
    generatedAt: new Date().toISOString(),
    platform: "windows",
    targetId: options.targetId,
    architecture: "x64",
    sourceStateDigest: options.releaseSourceStateDigest,
    mode: options.mode,
    kind,
    executables: {
      flutterClient: relativeBundlePath(root, flutterExecutable),
      licoClient: relativeBundlePath(root, licoClientExecutable)
    },
    launch: {
      gui: relativeBundlePath(root, flutterExecutable),
      cli: relativeBundlePath(root, licoClientExecutable)
    },
    artifacts: {
      flutterClient: {
        ref: relativeBundlePath(root, flutterExecutable),
        sha256: sha256File(flutterExecutable),
        pe: inspectWindowsPeFile(flutterExecutable),
      },
      licoClient: {
        ref: relativeBundlePath(root, licoClientExecutable),
        sha256: sha256File(licoClientExecutable),
        pe: inspectWindowsPeFile(licoClientExecutable),
      },
    }
  };
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  return manifestPath;
}

function updateRunnableManifest(config, runnable, options) {
  const manifestPath = manifestPathForRoot(config, runnable.root);
  if (!existsSync(manifestPath)) {
    return "";
  }
  const manifest = readJson(manifestPath);
  manifest.bundleRoot = ".";
  manifest.flutterExecutable = relativeBundlePath(runnable.root, runnable.executable);
  manifest.runtimeData = runtimeDataPolicyRecord(options.platform);
  manifest.signing = packageSigningPolicyRecord(options);
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  return manifestPath;
}

function writeRunnableNotes(runnable, options) {
  const lines = [
    `Lico Arc ${options.platform} Runnable Client`,
    "",
    `Runnable client: ${relativeBundlePath(runnable.root, runnable.appPath || runnable.executable)}`,
    `Executable: ${relativeBundlePath(runnable.root, runnable.executable)}`,
    runtimeDataDescription(options.platform),
    "",
    options.platform === "macos"
      ? `Run with: open ${JSON.stringify(relativeBundlePath(runnable.root, runnable.appPath))}`
      : `Run with: ${JSON.stringify(relativeBundlePath(runnable.root, runnable.executable))}`,
    ""
  ];
  writeFileSync(path.join(runnable.root, "RUNNABLE_CLIENT.txt"), lines.join("\n"), "utf8");
}

function createRunnableClient(config, result, options) {
  const root = runnableClientRoot(options);
  rmSync(root, { recursive: true, force: true });
  mkdirSync(path.dirname(root), { recursive: true });
  copyTree(result.bundle.root, root);
  let appPath = "";
  if (options.platform === "macos") {
    const defaultAppPath = path.join(root, "flutter_client.app");
    appPath = path.join(root, licoClientAppName);
    if (!existsSync(defaultAppPath)) {
      throw new Error(`Packaged macOS app is missing: ${defaultAppPath}`);
    }
    renameSync(defaultAppPath, appPath);
  }
  const executable = runnableExecutableForRoot(root, options.platform);
  if (!existsSync(executable)) {
    throw new Error(`Runnable client executable is missing: ${executable}`);
  }
  const runnable = {
    root,
    executable,
    appPath: appPath || executable,
    portableDataDir: path.join(root, "portable-data"),
    manifestPath: ""
  };
  runnable.manifestPath = updateRunnableManifest(config, runnable, options);
  writeRunnableNotes(runnable, options);
  if (options.platform === "macos") {
    for (const frameworkPath of repairMacosFrameworkSymlinks(appPath)) {
      signMacosArtifact(frameworkPath);
    }
    signMacosArtifact(appPath, macosEntitlementsPathForSigning(options));
  }
  runnable.windowsManifestPath = writeWindowsPlatformManifest(root, options, "runnable");
  return runnable;
}

function registerMacosApp(appPath) {
  const lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
  if (existsSync(lsregister)) {
    run(lsregister, ["-f", appPath]);
  }
  run("mdimport", [appPath]);
}

function quitRunningMacosClient() {
  try {
    execFileSync(
      "osascript",
      ["-e", `if application id "${licoClientBundleId}" is running then tell application id "${licoClientBundleId}" to quit`],
      {
        stdio: ["ignore", "ignore", "ignore"]
      }
    );
  } catch {
    // Best effort only; install can still replace an app that is not running or already exited.
  }
}

function installRunnableClient(runnable, options) {
  if (!options.install) {
    return null;
  }
  if (options.platform !== "macos") {
    throw new Error("--install is currently supported only for macOS client bundles.");
  }
  const installDir = macosInstallDir(options);
  const installedAppPath = path.join(installDir, licoClientAppName);
  quitRunningMacosClient();
  mkdirSync(installDir, { recursive: true });
  rmSync(installedAppPath, { recursive: true, force: true });
  copyTree(runnable.appPath, installedAppPath);
  registerMacosApp(installedAppPath);
  return installedAppPath;
}

function macosEntitlementsProfile(options) {
  if (options.mode === "release" && options.productionEntitlements) {
    return "production-release";
  }
  return options.mode === "release" ? "release" : "debug-profile";
}

function macosEntitlementsFileName(options) {
  if (macosEntitlementsProfile(options) === "production-release") {
    return "ProductionRelease.entitlements";
  }
  return options.mode === "release" ? "Release.entitlements" : "DebugProfile.entitlements";
}

function macosEntitlementsPath(options) {
  const fileName = macosEntitlementsFileName(options);
  return path.join(flutterClientRoot, "macos", "Runner", fileName);
}

function macosAppIdentifierPrefix() {
  const configured = String(process.env.LICO_MACOS_APP_IDENTIFIER_PREFIX || "").trim();
  if (!configured) {
    throw new Error(
      "--production-entitlements requires LICO_MACOS_APP_IDENTIFIER_PREFIX for non-dry-run signing."
    );
  }
  const normalized = configured.endsWith(".") ? configured : `${configured}.`;
  if (!/^[A-Z0-9]{10}\.$/u.test(normalized)) {
    throw new Error("LICO_MACOS_APP_IDENTIFIER_PREFIX must be a 10-character Apple Team ID prefix.");
  }
  return normalized;
}

function macosEntitlementsPathForSigning(options) {
  if (!options.productionEntitlements) {
    return macosEntitlementsPath(options);
  }
  const templatePath = macosEntitlementsPath(options);
  const template = readFileSync(templatePath, "utf8");
  const resolved = template
    .replaceAll("$(AppIdentifierPrefix)", macosAppIdentifierPrefix())
    .replaceAll("$(PRODUCT_BUNDLE_IDENTIFIER)", licoClientBundleId);
  if (resolved.includes("$(")) {
    throw new Error("macOS production entitlements template contains unresolved build setting placeholders.");
  }
  const target = path.join(
    clientBuildRoot,
    "signing",
    "macos",
    options.mode,
    "ProductionRelease.resolved.entitlements"
  );
  mkdirSync(path.dirname(target), { recursive: true });
  writeFileSync(target, resolved, "utf8");
  return target;
}

function packageSigningPolicyRecord(options) {
  if (options.platform !== "macos") {
    return {
      platform: options.platform,
      signingKind: "platform-default",
      entitlementsFile: "",
      entitlementProfile: "",
      productionEntitlementsRequested: false
    };
  }
  return {
    platform: "macos",
    signingKind: "local-ad-hoc-codesign",
    entitlementsFile: path.relative(workspaceRoot, macosEntitlementsPath(options)),
    entitlementProfile: macosEntitlementsProfile(options),
    productionEntitlementsRequested: options.productionEntitlements === true,
    nonDryRunRequiresAppIdentifierPrefix: options.productionEntitlements === true
  };
}

function signMacosArtifact(artifactPath, entitlementsPath = "") {
  const args = ["--force", "--sign", "-"];
  if (entitlementsPath) {
    args.push("--entitlements", entitlementsPath);
  }
  args.push(artifactPath);
  run("codesign", args);
}

function signMacosBundle(bundle, copiedArtifacts, options) {
  if (options.platform !== "macos") {
    return;
  }
  const templatePath = macosEntitlementsPath(options);
  if (!existsSync(templatePath)) {
    throw new Error(`macOS entitlements file is missing: ${templatePath}`);
  }
  const entitlementsPath = macosEntitlementsPathForSigning(options);
  if (!existsSync(entitlementsPath)) {
    throw new Error(`macOS entitlements file is missing: ${entitlementsPath}`);
  }
  for (const frameworkPath of repairMacosFrameworkSymlinks(macosAppDirFromBundle(bundle))) {
    signMacosArtifact(frameworkPath);
  }
  for (const artifact of copiedArtifacts) {
    if (existsSync(artifact) && statSync(artifact).isFile()) {
      signMacosArtifact(artifact, entitlementsPath);
    }
  }
  const appDir = macosAppDirFromBundle(bundle);
  signMacosArtifact(appDir, entitlementsPath);
}

function applyPackage(config, selected, skipped, options) {
  const bundle = resolveBundle(options);
  mkdirSync(bundle.executableDir, { recursive: true });
  mkdirSync(bundle.moduleResourceDir, { recursive: true });
  removeSkippedArtifacts(skipped, bundle);

  const copiedArtifacts = [];
  for (const moduleConfig of selected) {
    if (moduleConfig.cargoBin) {
      copiedArtifacts.push(copySidecar(moduleConfig.cargoBin, bundle, options));
    } else if (moduleConfig.packaging === "swift-sidecar") {
      copiedArtifacts.push(copySwiftSidecar(moduleConfig, bundle, options));
    } else if (moduleConfig.packaging === "module-resources") {
      copiedArtifacts.push(...copyModuleResources(moduleConfig, bundle));
    }
  }
  copiedArtifacts.push(copyClientLocalRuntimeMetadata(bundle, options));
  const manifestPath = preparePortableData(config, selected, skipped, bundle, options);
  writeBundleNotes(config, selected, bundle, options);
  updateMacosAppMetadata(bundle, options);
  signMacosBundle(bundle, copiedArtifacts, options);
  return { bundle, copiedArtifacts, manifestPath };
}

function cleanupFlutterBuildCache(options, flutterBuildAttempted) {
  if (!flutterBuildAttempted) {
    return;
  }
  if (options.keepFlutterBuildCache) {
    return;
  }
  rmSync(cleanBuildRoot(), { recursive: true, force: true });
}

function printPlan(selected, skipped, options, config) {
  console.log(
    JSON.stringify(
      {
        ok: true,
        platform: options.platform,
        mode: options.mode,
        profile: options.profile || config.packageProfile || "lico-client",
        configPath: publicWorkspacePath(options.configPath),
        packagingConfigDigest: options.packagingConfigDigest,
        signing: packageSigningPolicyRecord(options),
        enabledModules: selected.map(publicModuleRecord),
        skippedModules: skipped.map(publicModuleRecord)
      },
      null,
      2
    )
  );
}

function generateMacosAppIcons(options) {
  if (options.platform !== "macos" || options.skipFlutterBuild) {
    return;
  }
  run(process.execPath, [
    path.join(flutterClientRoot, "scripts", "generate-macos-app-icon.mjs"),
    "--verify",
  ], { failureCode: "macos_app_icon_verification_failed" });
}

function verifyConversationParityReadiness() {
  run(process.execPath, [
    path.join(workspaceRoot, "tools", "scripts", "client-agent-conversation-parity-reducer.mjs"),
    "--check"
  ], {
    stdio: "ignore",
    failureCode: "conversation_parity_readiness_failed",
  });
}

export function packageClient(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  const config = loadPackagingConfig(options.configPath, options);
  const { selected, skipped } = selectModules(config, options);
  // Bind the compile-time routing inclusion flag from the canonical module
  // catalog so that excluded builds cannot activate routing at runtime.
  const routingModuleSelected = selected.some((m) => m.id === "multi-agent-routing");
  options.routingModuleIncluded = routingModuleSelected;
  verifyConversationParityReadiness();
  if (options.dryRun) {
    printPlan(selected, skipped, options, config);
    return null;
  }
  // Refresh macOS app icons before capturing the release source digest so the
  // generated assets are part of the immutable input set, not a mid-build
  // mutation of apps/desktop sources.
  generateMacosAppIcons(options);
  const releaseSourceBinding = options.mode === "release"
    ? packageSourceStateBinding(options)
    : null;
  const releaseSourceStateDigest = releaseSourceBinding?.digest || "";
  options.releaseSourceStateDigest = releaseSourceStateDigest;
  const releaseSourceManifest = releaseSourceStateDigest &&
      releaseSourceBinding.provenance === "git-worktree"
    ? createClientSourceManifest(
        workspaceRoot,
        clientSourceRoots,
        releaseSourceStateDigest,
      )
    : null;
  const flutterBuildAttempted = !options.skipFlutterBuild;
  try {
    assertFlutterBuildPrereqs(options);
    buildNativeSidecars(selected, options);
    buildSwiftSidecars(selected, options);
    const flutterBuildRan = buildFlutterApp(options);
    if (flutterBuildRan) {
      rmSync(packagedBundleRoot(options), { recursive: true, force: true });
    }
    const result = applyPackage(config, selected, skipped, options);
    const runnable = createRunnableClient(config, result, options);
    result.windowsManifestPath = writeWindowsPlatformManifest(result.bundle.root, options, "bundle");
    const installedAppPath = installRunnableClient(runnable, options);
    if (releaseSourceStateDigest) {
      if (releaseSourceBinding.provenance === "git-worktree") {
        const afterSourceDigest = clientSourceStateDigest(workspaceRoot, clientSourceRoots);
        if (afterSourceDigest !== releaseSourceStateDigest) {
          const afterSourceManifest = createClientSourceManifest(
            workspaceRoot,
            clientSourceRoots,
            afterSourceDigest,
          );
          packageFailure(
            "release_source_changed_during_build",
            diffReleaseSourceManifests(releaseSourceManifest, afterSourceManifest),
          );
        }
        assertReleaseSourceDigestStable(
          releaseSourceStateDigest,
          afterSourceDigest,
        );
      } else if (packageSourceStateBinding(options).digest !== releaseSourceStateDigest) {
        packageFailure("release_source_attestation_changed_during_build");
      }
      if (sha256File(defaultConfigPath, { maxBytes: 2 * 1024 * 1024 }) !==
        options.packagingConfigDigest) {
        packageFailure("release_packaging_config_changed_during_build");
      }
    }
    console.log(JSON.stringify({
      ok: true,
      platform: options.platform,
      mode: options.mode,
      runnableRef: publicWorkspacePath(runnable.appPath || runnable.executable),
      bundleRef: publicWorkspacePath(result.bundle.root),
      executableRef: publicWorkspacePath(runnable.executable),
      manifestRef: publicWorkspacePath(result.manifestPath),
      runnableManifestRef: runnable.manifestPath
        ? publicWorkspacePath(runnable.manifestPath)
        : "",
      windowsManifestRef: result.windowsManifestPath
        ? publicWorkspacePath(result.windowsManifestPath)
        : "",
      installed: Boolean(installedAppPath),
      packagedArtifactRefs: result.copiedArtifacts.map((artifact) =>
        publicWorkspacePath(artifact, "<packaged-artifact>")),
      privatePathsIncluded: false,
    }));
    result.runnable = runnable;
    result.installedAppPath = installedAppPath;
    return result;
  } finally {
    cleanupFlutterBuildCache(options, flutterBuildAttempted);
  }
}

if (fileURLToPath(import.meta.url) === path.resolve(process.argv[1] || "")) {
  try {
    packageClient();
  } catch (error) {
    console.error(JSON.stringify({
      ok: false,
      error: error instanceof PackageClientError
        ? error.code
        : "package_client_failed",
      ...(error instanceof PackageClientError && error.details
        ? error.details
        : {}),
      privatePathsIncluded: false,
    }));
    process.exitCode = 1;
  }
}
