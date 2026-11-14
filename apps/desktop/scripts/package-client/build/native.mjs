import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";

import { packageClientRuntime, packageFailure } from "../cli-policy.mjs";
import {
  cliReleaseRuntimeTargetIdFor,
} from "../cli-release/release-pin.mjs";
import { stageCliRelease } from "../cli-release/stage.mjs";

/**
 * Native sidecar binaries are produced by the LicoUp-CLI repository and arrive
 * in this workspace as the pinned CLI release (`tools/licoup-cli-release.json`).
 * Desktop never compiles them: packaging stages the verified release into
 * `LICO_CLI_ARTIFACTS_DIR` or the conventional
 * `build/native-artifacts/<runtime-target-id>` staging root, and every later
 * stage (Xcode bundling, resource assembly) reads that same directory.
 */
export function nativeArtifactsDirectory(
  options,
  environment = process.env,
  hostArch = process.arch,
) {
  const override = String(environment.LICO_CLI_ARTIFACTS_DIR || "").trim();
  if (override) return path.resolve(override);
  return path.join(
    packageClientRuntime.nativeArtifactsRoot,
    cliReleaseRuntimeTargetIdFor(options.platform, hostArch),
  );
}

/**
 * The sidecar program names this packaging selection requires.
 */
function requiredSidecarBins(selected) {
  return [
    ...new Set(
      selected.flatMap((item) =>
        [item.cargoBin, item.embeddedCargoBin].filter(Boolean),
      ),
    ),
  ];
}

/**
 * Stages the verified CLI release and confirms it carries every sidecar the
 * selected packaging modules require. Returns the public release record, or
 * null when this run builds no native sidecars.
 */
export function stageNativeSidecars(
  selected,
  options,
  {
    exists = existsSync,
    environment = process.env,
    stage = stageCliRelease,
  } = {},
) {
  const bins = requiredSidecarBins(selected);
  if (bins.length === 0 || options.skipNativeBuild || options.dryRun) return null;
  const directory = nativeArtifactsDirectory(options, environment);
  const release = stage({
    platform: options.platform,
    stagingDirectory: directory,
    mode: options.mode,
    environment,
  });
  const suffix = binarySuffix(options.platform);
  for (const bin of bins) {
    if (!exists(path.join(directory, `${bin}${suffix}`))) {
      packageFailure("native_sidecar_artifacts_missing");
    }
  }
  return release;
}

export function clientReleaseTrack(environment = process.env) {
  const value = String(environment.LICO_CLIENT_RELEASE_TRACK || "nightly").trim();
  if (value !== "nightly" && value !== "stable") {
    throw new Error("LICO_CLIENT_RELEASE_TRACK must be nightly or stable");
  }
  return value;
}

export function clientProductVersion() {
  const manifest = JSON.parse(readFileSync(
    path.join(packageClientRuntime.workspaceRoot, "tools", "client-version.json"),
    "utf8",
  ));
  const version = String(manifest.productVersion || "").trim();
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version)) {
    throw new Error(`Invalid productVersion in tools/client-version.json: ${version}`);
  }
  return version;
}

export function binarySuffix(platform) {
  return platform === "windows" ? ".exe" : "";
}
