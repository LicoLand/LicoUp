import { existsSync } from "node:fs";
import path from "node:path";

import {
  packageClientRuntime,
  packageFailure,
} from "../cli-policy.mjs";
import {
  runPackageProcess,
} from "../process-runner.mjs";

export function macosAppDirFromBundle(bundle) {
  return path.resolve(bundle.executableDir, "..", "..");
}

export function updateMacosAppMetadata(bundle, options) {
  if (options.platform !== "macos") return;
  const plistPath = path.join(
    macosAppDirFromBundle(bundle),
    "Contents",
    "Info.plist",
  );
  if (!existsSync(plistPath)) packageFailure("macos_info_plist_missing");
  for (const [key, value] of [
    ["CFBundleIdentifier", packageClientRuntime.bundleId],
    ["CFBundleName", "LicoUp"],
    ["CFBundleDisplayName", "LicoUp"],
    [
      "NSHumanReadableCopyright",
      "Copyright (c) 2026 LicoMesh. All rights reserved.",
    ],
  ]) {
    runPackageProcess(
      "plutil",
      ["-replace", key, "-string", value, plistPath],
      {
        failureCode: "macos_metadata_update_failed",
        stage: "macos-metadata",
      },
    );
  }
}
