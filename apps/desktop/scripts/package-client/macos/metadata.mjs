import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
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

export const macosCustodyHelper = Object.freeze({
  bundleId: "land.lico.licoup.custody",
  appName: "LicoUpCustody.app",
  executableName: "licoup-cli",
  relativeAppPath: "Contents/Helpers/LicoUpCustody.app",
  relativeExecutablePath:
    "Contents/Helpers/LicoUpCustody.app/Contents/MacOS/licoup-cli",
});

export function macosCustodyHelperPaths(appDir) {
  const appPath = path.join(appDir, macosCustodyHelper.relativeAppPath);
  return {
    appPath,
    executablePath: path.join(appDir, macosCustodyHelper.relativeExecutablePath),
    infoPath: path.join(appPath, "Contents", "Info.plist"),
    profilePath: path.join(appPath, "Contents", "embedded.provisionprofile"),
  };
}

export function stageMacosCustodyMetadata(appDir) {
  const helper = macosCustodyHelperPaths(appDir);
  const version = JSON.parse(readFileSync(path.join(
    packageClientRuntime.workspaceRoot, "tools", "client-version.json",
  ), "utf8"));
  const plist = readFileSync(path.join(
    packageClientRuntime.flutterClientRoot, "macos", "CustodyHelper", "Info.plist",
  ), "utf8")
    .replaceAll("$(PRODUCT_VERSION)", version.productVersion)
    .replaceAll("$(BUILD_NUMBER)", String(version.buildNumber));
  mkdirSync(path.dirname(helper.executablePath), { recursive: true });
  writeFileSync(helper.infoPath, plist, "utf8");
  return helper;
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
