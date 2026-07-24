import { existsSync } from "node:fs";
import path from "node:path";

import {
  modeDirectoryName,
  packageFailure,
} from "../cli-policy.mjs";
import { rawFlutterBuildRootForOptions } from "../build/flutter.mjs";

export function findWindowsBundleSource(options) {
  const modeDir = modeDirectoryName(options.mode);
  const buildRoot = rawFlutterBuildRootForOptions(options);
  const candidates = [
    path.join(buildRoot, "windows", "x64", "runner", modeDir),
    path.join(buildRoot, "windows", "runner", modeDir),
  ];
  const bundleDir = candidates.find((item) =>
    existsSync(path.join(item, "licoup.exe")),
  );
  if (!bundleDir) packageFailure("windows_bundle_missing");
  return bundleDir;
}

export function windowsBundleLayout(root) {
  return Object.freeze({
    root,
    executableDir: root,
    portableDataDir: path.join(root, "portable-data"),
    moduleResourceDir: path.join(root, "modules"),
    flutterExecutable: path.join(root, "licoup.exe"),
  });
}
