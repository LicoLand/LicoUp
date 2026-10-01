import { copyFileSync, mkdirSync, rmSync } from "node:fs";
import path from "node:path";
import process from "node:process";

import { packageClientRuntime } from "../cli-policy.mjs";
import { runPackageProcess } from "../process-runner.mjs";
import {
  cargoTargetDir,
  clientProductVersion,
  clientReleaseTrack,
  encodedRustFlagsWithPathRemap,
} from "./native.mjs";

// The standalone migration tool is a release asset, not a bundle resource. It is built
// with the same workspace source and the same embedded product identity as the client,
// and it is staged outside every bundle so a permanent client installation never carries
// a migrator and the running client never selects one. The release target catalog picks
// the staged file up as the `migration-tool` artifact and records its digest. Governed
// publication is a separate consumer contract, not proved by this local build stage.
const MIGRATION_TOOL_MANIFEST = path.join("crates", "licoup-migrate", "Cargo.toml");
const MIGRATION_TOOL_BINARY = "licoup-migrate";
export const MIGRATION_TOOL_ASSET_NAME = "LicoUp-migrate-macos-arm64";

/// The unbundled release-tool directory for one platform.
export function releaseToolsDirectory(platform) {
  return path.join("build", "apps", "desktop", "release-tools", platform);
}

/// Build the on-demand migration tool and stage it outside the client bundles.
///
/// Release-mode macOS packaging only. An actual macOS invocation of this stage
/// invalidates the previous tool before building or skipping it. Dry runs and other platforms
/// leave the macOS output untouched; neither claims to refresh it.
export function buildReleaseTools(
  options,
  {
    runProcess = runPackageProcess,
    copy = copyFileSync,
    mkdir = mkdirSync,
    remove = rmSync,
  } = {},
) {
  if (options.dryRun || options.platform !== "macos") {
    return null;
  }
  const staged = path.join(
    packageClientRuntime.workspaceRoot,
    releaseToolsDirectory(options.platform),
    MIGRATION_TOOL_ASSET_NAME,
  );
  remove(staged, { force: true });
  if (options.skipNativeBuild || options.mode !== "release") return null;
  const environment = {
    ...process.env,
    CARGO_ENCODED_RUSTFLAGS: encodedRustFlagsWithPathRemap(),
    LICO_CLIENT_PRODUCT_VERSION: clientProductVersion(),
    LICO_CLIENT_RELEASE_TRACK: clientReleaseTrack(process.env),
  };
  delete environment.RUSTFLAGS;
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
  mkdir(path.dirname(staged), { recursive: true, mode: 0o755 });
  try {
    copy(built, staged);
  } catch (error) {
    remove(staged, { force: true });
    throw error;
  }
  return staged;
}
