import { copyFileSync, mkdirSync, rmSync } from "node:fs";
import path from "node:path";
import process from "node:process";

import {
  packageClientRuntime,
  packageFailure,
} from "../cli-policy.mjs";
import { runPackageProcess } from "../process-runner.mjs";
import {
  loadClientReleaseTargetCatalog,
  validateClientReleaseTargetCatalog,
} from "../../../../../tools/scripts/lib/client-release-targets.mjs";
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

/// The unbundled release-tool directory for one platform.
export function releaseToolsDirectory(platform) {
  return path.join("build", "apps", "desktop", "release-tools", platform);
}

/// Resolve the optional migration-tool capability from the release target catalog.
///
/// Platform adapters own public asset identity and final release source paths. The
/// shared client builder only receives a descriptor when one selected platform target
/// declares this capability.
export function selectReleaseToolDescriptor(
  platform,
  catalog = loadClientReleaseTargetCatalog(),
) {
  const validated = validateClientReleaseTargetCatalog(catalog);
  const matches = validated.targets.flatMap((target) =>
    target.platform === platform
      ? target.artifacts
        .filter((artifact) => artifact.role === "migration-tool")
        .map((artifact) => ({ artifact, target }))
      : []);
  if (matches.length === 0) return null;
  if (matches.length !== 1) {
    packageFailure("migration_tool_release_target_ambiguous");
  }
  const [{ artifact, target }] = matches;
  const expectedSource = path.posix.join(
    "build",
    "apps",
    "desktop",
    "native-release",
    target.id,
    artifact.file,
  );
  if (artifact.source !== expectedSource) {
    packageFailure("migration_tool_release_source_invalid");
  }
  return Object.freeze({
    assetName: artifact.file,
    platform: target.platform,
    releaseSource: artifact.source,
    targetId: target.id,
  });
}

/// Build the on-demand migration tool and stage it outside the client bundles.
///
/// An actual invocation for a catalog-declared tool invalidates the previous output
/// before building or skipping it. Dry runs and platforms without the capability leave
/// release-tool output untouched; neither claims to refresh it.
export function buildReleaseTools(
  options,
  releaseTool,
  {
    runProcess = runPackageProcess,
    copy = copyFileSync,
    mkdir = mkdirSync,
    remove = rmSync,
  } = {},
) {
  if (options.dryRun || !releaseTool) return null;
  if (releaseTool.platform !== options.platform) {
    packageFailure("migration_tool_release_platform_mismatch");
  }
  const staged = path.join(
    packageClientRuntime.workspaceRoot,
    releaseToolsDirectory(options.platform),
    releaseTool.assetName,
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
