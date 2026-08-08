import { existsSync, readdirSync, statSync } from "node:fs";
import path from "node:path";

import { packageFailure } from "../cli-policy.mjs";
import { rawFlutterBuildRootForOptions } from "../build/flutter.mjs";

export function findLinuxBundleSource(options) {
  const linuxBuildRoot = path.join(
    rawFlutterBuildRootForOptions(options),
    "linux",
  );
  if (!existsSync(linuxBuildRoot)) {
    packageFailure("linux_build_directory_missing");
  }
  const candidates = [];
  for (const arch of readdirSync(linuxBuildRoot)) {
    const bundleDir = path.join(linuxBuildRoot, arch, options.mode, "bundle");
    if (existsSync(path.join(bundleDir, "licoup"))) {
      candidates.push(bundleDir);
    }
  }
  if (candidates.length === 0) packageFailure("linux_bundle_missing");
  candidates.sort(
    (left, right) => statSync(right).mtimeMs - statSync(left).mtimeMs,
  );
  return candidates[0];
}

export function linuxBundleLayout(root) {
  return Object.freeze({
    root,
    executableDir: root,
    portableDataDir: path.join(root, "portable-data"),
    moduleResourceDir: path.join(root, "modules"),
    pluginResourceDir: path.join(root, "resources"),
    flutterExecutable: path.join(root, "licoup"),
  });
}
