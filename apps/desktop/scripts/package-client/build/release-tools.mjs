import { copyFileSync, mkdirSync } from "node:fs";
import path from "node:path";
import process from "node:process";

import { packageClientRuntime } from "../cli-policy.mjs";
import { runPackageProcess } from "../process-runner.mjs";
import {
  cargoTargetDir,
  clientProductVersion,
  clientReleaseTrack,
} from "./native.mjs";

// The standalone migration tool is a release asset, not a bundle resource. It is built
// with the same workspace source and the same embedded product identity as the client,
// and it is staged outside every bundle so a permanent client installation never carries
// a migrator and the running client never selects one. The release target catalog picks
// the staged file up as the `migration-tool` artifact; that pipeline records its digest
// and publishes it beside the client assets.
const MIGRATION_TOOL_MANIFEST = path.join("crates", "licoup-migrate", "Cargo.toml");
const MIGRATION_TOOL_BINARY = "licoup-migrate";
export const MIGRATION_TOOL_ASSET_NAME = "LicoUp-migrate-macos-arm64";

/// The unbundled release-tool directory for one platform.
export function releaseToolsDirectory(platform) {
  return path.join("build", "apps", "desktop", "release-tools", platform);
}

/// Build the on-demand migration tool and stage it outside the client bundles.
///
/// Release-mode macOS packaging only. A development or non-macOS build leaves the
/// release output absent instead of producing a stale asset, and a dry run performs no
/// work at all.
export function buildReleaseTools(
  options,
  {
    runProcess = runPackageProcess,
    copy = copyFileSync,
    mkdir = mkdirSync,
  } = {},
) {
  if (
    options.dryRun ||
    options.skipNativeBuild ||
    options.mode !== "release" ||
    options.platform !== "macos"
  ) {
    return null;
  }
  const environment = {
    ...process.env,
    LICO_CLIENT_PRODUCT_VERSION: clientProductVersion(),
    LICO_CLIENT_RELEASE_TRACK: clientReleaseTrack(process.env),
  };
  runProcess(
    process.execPath,
    [
      path.join("tools", "scripts", "cargo-client.mjs"),
      "build",
      "--manifest-path",
      MIGRATION_TOOL_MANIFEST,
      "--release",
      "--locked",
      "--bin",
      MIGRATION_TOOL_BINARY,
    ],
    {
      failureCode: "migration_tool_build_failed",
      stage: "migration-tool-build",
      env: environment,
    },
  );

  const built = path.join(
    cargoTargetDir(options.mode, options),
    MIGRATION_TOOL_BINARY,
  );
  const staged = path.join(
    packageClientRuntime.workspaceRoot,
    releaseToolsDirectory(options.platform),
    MIGRATION_TOOL_ASSET_NAME,
  );
  mkdir(path.dirname(staged), { recursive: true, mode: 0o755 });
  copy(built, staged);
  return staged;
}
