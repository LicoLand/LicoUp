import { existsSync } from "node:fs";
import path from "node:path";

import {
  modeDirectoryName,
  packageFailure,
} from "../cli-policy.mjs";
import { rawFlutterBuildRootForOptions } from "../build/flutter.mjs";

export function findMacosBundleSource(options) {
  const productsDir = path.join(
    rawFlutterBuildRootForOptions(options),
    "macos",
    "Build",
    "Products",
    modeDirectoryName(options.mode),
  );
  const executable = path.join(
    productsDir,
    "licoup.app",
    "Contents",
    "MacOS",
    "licoup",
  );
  if (!existsSync(executable)) packageFailure("macos_bundle_missing");
  return productsDir;
}

export function macosBundleLayout(root) {
  const appDir = path.join(root, "licoup.app");
  return Object.freeze({
    root,
    executableDir: path.join(appDir, "Contents", "MacOS"),
    portableDataDir: path.join(root, "portable-data"),
    moduleResourceDir: path.join(root, "modules"),
    flutterExecutable: path.join(
      appDir,
      "Contents",
      "MacOS",
      "licoup",
    ),
  });
}
