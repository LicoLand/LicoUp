import {
  existsSync,
  mkdirSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";

import { withClientToolchainEnv } from "../../../../../tools/scripts/client-toolchain-env.mjs";
import {
  modeDirectoryName,
  packageClientRuntime,
  packageFailure,
} from "../cli-policy.mjs";
import { readPackageJson } from "../config-codec.mjs";
import { prepareStagedPubCache } from "../pub-cache.mjs";
import {
  runFlutterProcess,
  runPackageProcess,
} from "../process-runner.mjs";
import {
  buildSymbolsRoot,
  prepareStagedFlutterSource,
} from "../source-staging.mjs";

export function assertFlutterBuildPrereqs(options) {
  if (options.skipFlutterBuild || options.dryRun) return;
  runFlutterProcess(["--version"], {
    stdio: "ignore",
    failureCode: "flutter_toolchain_unavailable",
    stage: "flutter-preflight",
  });
  if (
    options.platform === "windows" &&
    !canCreateSymlink() &&
    !canUseWindowsJunctionPluginFallback(options)
  ) {
    packageFailure("windows_flutter_symlink_support_unavailable");
  }
}

export function buildFlutterApp(options) {
  if (options.skipFlutterBuild || options.dryRun) return false;
  const stagedRoot = prepareStagedFlutterSource();
  const pubCacheRoot = prepareStagedPubCache();
  options.flutterBuildProjectRoot = stagedRoot;
  cleanStaleFlutterBuildArtifacts(options);
  const flutterEnv = withClientToolchainEnv(process.env, {
    pubCache: pubCacheRoot,
  });
  runFlutterPubGet(stagedRoot, flutterEnv, options);
  const args = ["build", options.platform, `--${options.mode}`, "--no-pub"];
  args.push(
    `--dart-define=LICO_ROUTING_MODULE_INCLUDED=${options.routingModuleIncluded !== false}`,
  );
  if (process.env.LICO_AGENT_CONVERSATION_RELEASE_LIVE === "1") {
    args.push("--dart-define=LICO_AGENT_CONVERSATION_RELEASE_LIVE=true");
  }
  if (options.mode === "release") {
    const symbolsDir = path.join(buildSymbolsRoot(options), "dart");
    mkdirSync(symbolsDir, { recursive: true });
    args.push(`--split-debug-info=${symbolsDir}`);
  }
  const flutterBuildEnv =
    options.platform === "macos"
      ? {
          ...flutterEnv,
          LICO_CLIENT_SKIP_XCODE_SIDECAR_BUNDLE: "1",
        }
      : flutterEnv;
  runFlutterProcess(args, {
    cwd: stagedRoot,
    env: flutterBuildEnv,
    failureCode: "flutter_app_build_failed",
    stage: "flutter-build",
  });
  return true;
}

export function generateMacosAppIcons(options) {
  if (options.platform !== "macos" || options.skipFlutterBuild) return;
  runPackageProcess(
    process.execPath,
    [
      path.join(
        packageClientRuntime.flutterClientRoot,
        "scripts",
        "generate-macos-app-icon.mjs",
      ),
      "--verify",
    ],
    {
      failureCode: "macos_app_icon_verification_failed",
      stage: "macos-icon-preflight",
    },
  );
}

export function flutterBuildProjectRoot(options) {
  return options.flutterBuildProjectRoot || packageClientRuntime.flutterClientRoot;
}

export function rawFlutterBuildRootForOptions(options) {
  return path.join(flutterBuildProjectRoot(options), "build");
}

export function packagedBundleRoot(options) {
  return path.join(
    packageClientRuntime.clientBuildRoot,
    "bundles",
    options.platform,
    options.mode,
    "bundle",
  );
}

export function runnableClientRoot(options) {
  return path.join(
    packageClientRuntime.clientBuildRoot,
    "runnable",
    options.platform,
    options.mode,
  );
}

function cleanStaleFlutterBuildArtifacts(options) {
  if (options.platform !== "macos") return;
  const appDir = path.join(
    flutterBuildProjectRoot(options),
    "build",
    "macos",
    "Build",
    "Products",
    modeDirectoryName(options.mode),
    "licoup.app",
  );
  rmSync(appDir, { recursive: true, force: true });
}

function runFlutterPubGet(projectRoot, flutterEnv, options) {
  const args = ["pub", "get", "--offline"];
  try {
    runFlutterProcess(args, {
      cwd: projectRoot,
      env: flutterEnv,
      failureCode: "flutter_pub_get_failed",
      stage: "flutter-pub-get",
    });
  } catch (error) {
    if (!canUseWindowsJunctionPluginFallback(options)) throw error;
    createDesktopPluginJunctions(projectRoot);
    runFlutterProcess(args, {
      cwd: projectRoot,
      env: flutterEnv,
      failureCode: "flutter_pub_get_failed",
      stage: "flutter-pub-get-retry",
    });
  }
}

function createDesktopPluginJunctions(projectRoot) {
  const dependenciesPath = path.join(
    projectRoot,
    ".flutter-plugins-dependencies",
  );
  if (!existsSync(dependenciesPath)) {
    packageFailure("flutter_plugin_metadata_missing");
  }
  const dependencies = readPackageJson(dependenciesPath);
  for (const platform of ["windows", "linux"]) {
    const platformRoot = path.join(projectRoot, platform);
    const plugins = dependencies.plugins?.[platform] || [];
    if (!existsSync(platformRoot) || plugins.length === 0) continue;
    const linkRoot = path.join(
      projectRoot,
      platform,
      "flutter",
      "ephemeral",
      ".plugin_symlinks",
    );
    mkdirSync(linkRoot, { recursive: true });
    for (const plugin of plugins) {
      if (!plugin?.name || !plugin?.path) continue;
      const target = path.resolve(plugin.path);
      if (!existsSync(target) || !statSync(target).isDirectory()) {
        packageFailure("flutter_plugin_source_missing");
      }
      const link = path.join(linkRoot, plugin.name);
      if (!existsSync(link)) symlinkSync(target, link, "junction");
    }
  }
}

function canUseWindowsJunctionPluginFallback(options) {
  return (
    process.platform === "win32" &&
    options.platform === "windows" &&
    canCreateWindowsJunction()
  );
}

function canCreateSymlink() {
  return probeLink("file");
}

function canCreateWindowsJunction() {
  return process.platform === "win32" && probeLink("junction");
}

function probeLink(kind) {
  const root = path.join(
    os.tmpdir(),
    `licoup-link-probe-${process.pid}-${Date.now()}`,
  );
  const target = path.join(root, kind === "junction" ? "target" : "target.txt");
  const link = path.join(root, kind === "junction" ? "link" : "link.txt");
  try {
    mkdirSync(root, { recursive: true });
    if (kind === "junction") mkdirSync(target, { recursive: true });
    else writeFileSync(target, "ok\n", "utf8");
    symlinkSync(target, link, kind === "junction" ? "junction" : undefined);
    return true;
  } catch {
    return false;
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}
