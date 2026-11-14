import { copyFileSync, existsSync, mkdirSync, rmSync } from "node:fs";
import path from "node:path";

import {
  packageClientRuntime,
  packageFailure,
} from "../cli-policy.mjs";
import {
  loadClientReleaseTargetCatalog,
  validateClientReleaseTargetCatalog,
} from "../../../../../tools/scripts/lib/client-release-targets.mjs";
import {
  binarySuffix,
  clientProductVersion,
  clientReleaseTrack,
  nativeArtifactsDirectory,
} from "./native.mjs";
import { CLI_RELEASE_MIGRATION_TOOL } from "../cli-release/release-pin.mjs";

// The standalone migration tool is a release asset, not a bundle resource. Its
// binary arrives in the pinned LicoUp-CLI release archive beside the sidecars
// and is taken only from that staged release; it is staged outside every
// bundle so a permanent client installation never carries a migrator and the
// running client never selects one. The release target catalog picks the
// staged file up as the `migration-tool` artifact and records its digest.
// Governed publication is a separate consumer contract, not proved by this
// local stage.

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

/// Stage the on-demand migration tool outside the client bundles.
///
/// An actual invocation for a catalog-declared tool invalidates the previous output
/// before staging it. Dry runs and platforms without the capability leave
/// release-tool output untouched; neither claims to refresh it.
///
/// [cliRelease] is the record of the CLI release this run staged; the tool is
/// taken from that staged release and nowhere else.
export function buildReleaseTools(
  options,
  releaseTool,
  cliRelease,
  {
    copy = copyFileSync,
    exists = existsSync,
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
  // Product identity inputs remain the Desktop-controlled publication contract;
  // resolving them here keeps an invalid manifest or track fail-closed even
  // though the binaries themselves are produced by the CLI workspace.
  clientProductVersion();
  clientReleaseTrack(process.env);
  if (!cliRelease?.members?.includes(CLI_RELEASE_MIGRATION_TOOL)) {
    packageFailure("migration_tool_cli_release_unstaged");
  }
  const delivered = path.join(
    nativeArtifactsDirectory(options),
    `${CLI_RELEASE_MIGRATION_TOOL}${binarySuffix(options.platform)}`,
  );
  if (!exists(delivered)) packageFailure("migration_tool_artifact_missing");
  mkdir(path.dirname(staged), { recursive: true, mode: 0o755 });
  try {
    copy(delivered, staged);
  } catch (error) {
    remove(staged, { force: true });
    throw error;
  }
  return staged;
}
