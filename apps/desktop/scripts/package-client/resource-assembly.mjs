import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  renameSync,
  rmSync,
} from "node:fs";
import path from "node:path";

import {
  packageClientRuntime,
  packageFailure,
} from "./cli-policy.mjs";
import {
  packagedBundleRoot,
  runnableClientRoot,
} from "./build/flutter.mjs";
import { binarySuffix, cargoTargetDir } from "./build/native.mjs";
import {
  findLinuxBundleSource,
  linuxBundleLayout,
} from "./bundle-resolver/linux.mjs";
import {
  findMacosBundleSource,
  macosBundleLayout,
} from "./bundle-resolver/macos.mjs";
import {
  findWindowsBundleSource,
  windowsBundleLayout,
} from "./bundle-resolver/windows.mjs";
import { copyTree } from "./source-staging.mjs";

export function assemblePackageResources(selected, skipped, options) {
  const bundle = resolveBundle(options);
  mkdirSync(bundle.executableDir, { recursive: true });
  mkdirSync(bundle.moduleResourceDir, { recursive: true });
  removeSkippedArtifacts(skipped, bundle);
  const copiedArtifacts = stageSelectedModuleArtifacts(selected, bundle, options);
  return { bundle, copiedArtifacts };
}

// Canonical artifact staging seam shared by normal packaging and focused bundle verification.
export function stageSelectedModuleArtifacts(selected, bundle, options) {
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
  return copiedArtifacts;
}

export function stageRunnableClient(result, options) {
  const root = runnableClientRoot(options);
  rmSync(root, { recursive: true, force: true });
  mkdirSync(path.dirname(root), { recursive: true });
  copyTree(result.bundle.root, root);
  let appPath = "";
  if (options.platform === "macos") {
    const defaultAppPath = path.join(root, "licoup.app");
    appPath = path.join(root, packageClientRuntime.appName);
    if (!existsSync(defaultAppPath)) {
      packageFailure("packaged_macos_app_missing");
    }
    renameSync(defaultAppPath, appPath);
  }
  const executable = runnableExecutableForRoot(root, options.platform);
  if (!existsSync(executable)) packageFailure("runnable_executable_missing");
  return {
    root,
    executable,
    appPath: appPath || executable,
    portableDataDir: path.join(root, "portable-data"),
    manifestPath: "",
    windowsManifestPath: "",
  };
}

export function resolveBundle(options) {
  let root = packagedBundleRoot(options);
  if (!stagedBundleExists(root, options.platform)) {
    root = stageFlutterBundle(options);
  }
  return bundleLayout(root, options.platform);
}

export function flutterExecutableForRoot(root, platform) {
  if (platform === "macos") {
    return path.join(
      root,
      "licoup.app",
      "Contents",
      "MacOS",
      "licoup",
    );
  }
  return path.join(
    root,
    platform === "windows" ? "licoup.exe" : "licoup",
  );
}

export function runnableExecutableForRoot(root, platform) {
  if (platform === "macos") {
    return path.join(
      root,
      packageClientRuntime.appName,
      "Contents",
      "MacOS",
      "licoup",
    );
  }
  return flutterExecutableForRoot(root, platform);
}

function stageFlutterBundle(options) {
  const source = findFlutterBundleSource(options);
  const target = packagedBundleRoot(options);
  rmSync(target, { recursive: true, force: true });
  mkdirSync(path.dirname(target), { recursive: true });
  copyTree(source, target);
  return target;
}

function findFlutterBundleSource(options) {
  if (options.platform === "linux") return findLinuxBundleSource(options);
  if (options.platform === "macos") return findMacosBundleSource(options);
  return findWindowsBundleSource(options);
}

function bundleLayout(root, platform) {
  if (platform === "linux") return linuxBundleLayout(root);
  if (platform === "macos") return macosBundleLayout(root);
  return windowsBundleLayout(root);
}

function stagedBundleExists(root, platform) {
  return existsSync(flutterExecutableForRoot(root, platform));
}

function copySidecar(binaryName, bundle, options) {
  const suffix = binarySuffix(options.platform);
  const source = path.join(
    cargoTargetDir(options.mode, options),
    `${binaryName}${suffix}`,
  );
  if (!existsSync(source)) packageFailure("sidecar_binary_missing");
  const target = path.join(bundle.executableDir, `${binaryName}${suffix}`);
  copyFileSync(source, target);
  if (options.platform !== "windows") chmodSync(target, 0o755);
  return target;
}

function copySwiftSidecar(moduleConfig, bundle, options) {
  const artifactName = moduleConfig.artifactName || moduleConfig.id;
  const source = path.join(
    cargoTargetDir(options.mode, options),
    artifactName,
  );
  if (!existsSync(source)) packageFailure("swift_sidecar_missing");
  const target = path.join(bundle.executableDir, artifactName);
  copyFileSync(source, target);
  chmodSync(target, 0o755);
  return target;
}

function copyModuleResources(moduleConfig, bundle) {
  const copied = [];
  for (const includePath of moduleConfig.includePaths || []) {
    const source = path.join(packageClientRuntime.workspaceRoot, includePath);
    if (!existsSync(source)) packageFailure("module_resource_missing");
    const target = path.join(
      bundle.moduleResourceDir,
      moduleConfig.id,
      path.basename(source),
    );
    rmSync(target, { recursive: true, force: true });
    mkdirSync(path.dirname(target), { recursive: true });
    copyTree(source, target);
    copied.push(target);
  }
  return copied;
}

function removeSkippedArtifacts(skipped, bundle) {
  for (const moduleConfig of skipped) {
    if (moduleConfig.packaging === "swift-sidecar") {
      const artifactName = moduleConfig.artifactName || moduleConfig.id;
      rmSync(path.join(bundle.executableDir, artifactName), { force: true });
    } else if (moduleConfig.packaging === "module-resources") {
      rmSync(path.join(bundle.moduleResourceDir, moduleConfig.id), {
        recursive: true,
        force: true,
      });
    }
  }
}
