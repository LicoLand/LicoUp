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
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const flutterClientRoot = path.join(workspaceRoot, "apps", "desktop");
const clientBuildRoot = path.join(workspaceRoot, "build", "apps", "desktop");
const nativeTargetRoot = path.join(workspaceRoot, "build", "crates", "lico-client-native", "target");
const defaultConfigPath = path.join(flutterClientRoot, "packaging.modules.json");
const PACKAGING_MODULES_SCHEMA_VERSION = "v0.0.1:client-desktop:packaging-modules-1";
const BUNDLE_MANIFEST_SCHEMA_VERSION = "v0.0.1:client-desktop:bundle-manifest-1";
const WINDOWS_PLATFORM_MANIFEST_SCHEMA_VERSION = "v0.0.1:client-desktop:windows-platform-manifest-1";
const licoClientBundleId = "com.lico.client";
const licoClientAppName = "LicoLite Client.app";
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
    dryRun: false
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
    } else if (arg === "--dry-run") {
      options.dryRun = true;
      options.skipFlutterBuild = true;
      options.skipNativeBuild = true;
    } else {
      throw new Error(`Unknown packaging option: ${arg}`);
    }
  }
  return options;
}

function splitList(value) {
  return String(value || "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function normalizeProfile(value) {
  const normalized = String(value || "").trim();
  if (normalized === "future-client") {
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
  if (process.platform === "win32" && /\.(?:bat|cmd)$/i.test(command)) {
    const commandLine = ["call", command, ...args].map(quoteWindowsCommandArg).join(" ");
    execFileSync(process.env.ComSpec || "cmd.exe", ["/d", "/s", "/c", commandLine], {
      cwd: workspaceRoot,
      stdio: "inherit",
      windowsHide: true,
      ...options
    });
    return;
  }
  execFileSync(command, args, {
    cwd: workspaceRoot,
    stdio: "inherit",
    ...options
  });
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
    runFlutter(["--version"], { stdio: "ignore" });
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
    return "/private/tmp/lico-client-build";
  }
  if (process.platform === "win32") {
    return path.join(os.tmpdir(), "lico-client-build");
  }
  return "/tmp/lico-client-build";
}

function cleanBuildRoot() {
  return path.resolve(process.env.LICO_CLIENT_CLEAN_BUILD_ROOT || defaultCleanBuildRoot());
}

function stagedFlutterClientRoot() {
  return path.join(cleanBuildRoot(), "source", "apps", "desktop");
}

function actualPubCacheRoot() {
  if (process.env.PUB_CACHE) {
    return path.resolve(process.env.PUB_CACHE);
  }
  if (process.platform === "win32") {
    return path.resolve(process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local"), "Pub", "Cache");
  }
  return path.resolve(path.join(os.homedir(), ".pub-cache"));
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

function loadPackagingConfig(configPath) {
  const config = readJson(configPath);
  if (
    config.schemaVersion !== PACKAGING_MODULES_SCHEMA_VERSION ||
    !config.modules ||
    typeof config.modules !== "object"
  ) {
    throw new Error(`Invalid client packaging module config: ${configPath}`);
  }
  return config;
}

function platformSupported(moduleConfig, platform) {
  const platforms = Array.isArray(moduleConfig.platforms) ? moduleConfig.platforms : [];
  return platforms.length === 0 || platforms.includes(platform);
}

function selectModules(config, options) {
  const activeProfile = options.profile || config.packageProfile || "future-client";
  if (activeProfile !== "future-client") {
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

function cargoTargetDir(mode) {
  return path.join(nativeTargetRoot, cargoProfile(mode));
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
    args.push("--release");
  }
  for (const bin of bins) {
    args.push("--bin", bin);
  }
  run("cargo", args, {
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
    const target = path.join(cargoTargetDir(options.mode), artifactName);
    mkdirSync(path.dirname(target), { recursive: true });
    run("xcrun", ["swiftc", "-parse-as-library", "-O", "-o", target, source]);
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
  const flutterEnv = {
    ...process.env,
    PUB_CACHE: pubCacheRoot
  };
  runFlutterPubGet(stagedRoot, flutterEnv, options);
  const args = ["build", options.platform, `--${options.mode}`, "--no-pub"];
  if (options.mode === "release") {
    const dartSymbolsDir = path.join(buildSymbolsRoot(options), "dart");
    mkdirSync(dartSymbolsDir, { recursive: true });
    args.push(`--split-debug-info=${dartSymbolsDir}`);
  }
  runFlutter(args, {
    cwd: stagedRoot,
    env: flutterEnv
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
    if (isInstalledLicoClientApp(normalized)) {
      return normalized;
    }
  }
  return "";
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
    path.join(rawFlutterBuildRootForOptions(options), "windows", "runner", modeDir)
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
    return path.join(root, "LicoClient.app", "Contents", "MacOS", "flutter_client");
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
  const source = path.join(cargoTargetDir(options.mode), `${binaryName}${suffix}`);
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
  const source = path.join(cargoTargetDir(options.mode), artifactName);
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
  updateMacosPlistString(plistPath, "CFBundleName", "LicoLite Client");
  updateMacosPlistString(plistPath, "CFBundleDisplayName", "LicoLite Client");
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
    config.bundle?.manifestPath || "package-metadata/future-client/packaging-modules.json"
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

function preparePortableData(config, selected, skipped, bundle, options) {
  rmSync(bundle.portableDataDir, { recursive: true, force: true });
  const manifestPath = manifestPathForRoot(config, bundle.root);
  mkdirSync(path.dirname(manifestPath), { recursive: true });
  const manifest = {
    schemaVersion: BUNDLE_MANIFEST_SCHEMA_VERSION,
    generatedAt: new Date().toISOString(),
    platform: options.platform,
    mode: options.mode,
    configPath: path.relative(workspaceRoot, options.configPath),
    bundleRoot: ".",
    flutterExecutable: relativeBundlePath(bundle.root, bundle.flutterExecutable),
    runtimeData: runtimeDataPolicyRecord(options.platform),
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
    `LicoLite ${options.platform} Client Bundle`,
    "",
    "Run the Flutter desktop frontend from this bundle.",
    "The frontend resolves lico-client as its future client sidecar.",
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
    mode: options.mode,
    kind,
    executables: {
      flutterClient: relativeBundlePath(root, flutterExecutable),
      licoClient: relativeBundlePath(root, licoClientExecutable)
    },
    launch: {
      gui: relativeBundlePath(root, flutterExecutable),
      cli: relativeBundlePath(root, licoClientExecutable)
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
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  return manifestPath;
}

function writeRunnableNotes(runnable, options) {
  const lines = [
    `LicoLite ${options.platform} Runnable Client`,
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
    appPath = path.join(root, "LicoClient.app");
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
    signMacosArtifact(appPath, macosEntitlementsPath(options.mode));
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

function macosEntitlementsPath(mode) {
  const fileName = mode === "release" ? "Release.entitlements" : "DebugProfile.entitlements";
  return path.join(flutterClientRoot, "macos", "Runner", fileName);
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
  const entitlementsPath = macosEntitlementsPath(options.mode);
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

function cleanupFlutterBuildCache(options, flutterBuildRan) {
  if (!flutterBuildRan) {
    return;
  }
  if (options.keepFlutterBuildCache) {
    return;
  }
  rmSync(stagedFlutterClientRoot(), { recursive: true, force: true });
}

function printPlan(selected, skipped, options, config) {
  console.log(
    JSON.stringify(
      {
        ok: true,
        platform: options.platform,
        mode: options.mode,
        profile: options.profile || config.packageProfile || "future-client",
        configPath: options.configPath,
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
  run(process.execPath, [path.join(flutterClientRoot, "scripts", "generate-macos-app-icon.mjs")]);
}

export function packageClient(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  const config = loadPackagingConfig(options.configPath);
  const { selected, skipped } = selectModules(config, options);
  if (options.dryRun) {
    printPlan(selected, skipped, options, config);
    return null;
  }
  assertFlutterBuildPrereqs(options);
  buildNativeSidecars(selected, options);
  buildSwiftSidecars(selected, options);
  generateMacosAppIcons(options);
  const flutterBuildRan = buildFlutterApp(options);
  if (flutterBuildRan) {
    rmSync(packagedBundleRoot(options), { recursive: true, force: true });
  }
  const result = applyPackage(config, selected, skipped, options);
  const runnable = createRunnableClient(config, result, options);
  result.windowsManifestPath = writeWindowsPlatformManifest(result.bundle.root, options, "bundle");
  const installedAppPath = installRunnableClient(runnable, options);
  cleanupFlutterBuildCache(options, flutterBuildRan);
  console.log("");
  console.log(`${options.platform} runnable client ready: ${runnable.appPath}`);
  console.log(`Runnable root: ${runnable.root}`);
  console.log(`Runnable executable: ${runnable.executable}`);
  console.log(`${options.platform} client bundle ready: ${result.bundle.root}`);
  console.log(`Flutter executable: ${result.bundle.flutterExecutable}`);
  console.log(runtimeDataDescription(options.platform));
  console.log(`Packaging manifest: ${result.manifestPath}`);
  if (runnable.manifestPath) {
    console.log(`Runnable manifest: ${runnable.manifestPath}`);
  }
  if (result.windowsManifestPath) {
    console.log(`Windows bundle manifest: ${result.windowsManifestPath}`);
  }
  if (runnable.windowsManifestPath) {
    console.log(`Windows runnable manifest: ${runnable.windowsManifestPath}`);
  }
  if (installedAppPath) {
    console.log(`Installed app: ${installedAppPath}`);
  }
  for (const artifact of result.copiedArtifacts) {
    console.log(`Packaged artifact: ${artifact}`);
  }
  result.runnable = runnable;
  result.installedAppPath = installedAppPath;
  return result;
}

if (fileURLToPath(import.meta.url) === path.resolve(process.argv[1] || "")) {
  try {
    packageClient();
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  }
}
