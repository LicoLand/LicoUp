import { rmSync } from "node:fs";
import path from "node:path";
import process from "node:process";

import {
  packageClientRuntime,
  parsePackageClientArgs,
  publicWorkspacePath,
} from "./cli-policy.mjs";
import {
  assertPackagingConfigDigestStable,
  loadPackagingConfig,
} from "./config-codec.mjs";
import {
  publicPackagingModuleRecord,
  selectPackagingModules,
} from "./module-selection.mjs";
import { runPackageProcess } from "./process-runner.mjs";
import { buildNativeSidecars } from "./build/native.mjs";
import { buildSwiftSidecars } from "./build/swift.mjs";
import {
  assertFlutterBuildPrereqs,
  buildFlutterApp,
  generateMacosAppIcons,
  packagedBundleRoot,
} from "./build/flutter.mjs";
import {
  assemblePackageResources,
  stageRunnableClient,
} from "./resource-assembly.mjs";
import {
  assertReleaseSourceStateStable,
  captureReleaseSourceState,
  preparePortableManifest,
  updateRunnableManifest,
  writeBundleNotes,
  writeRunnableNotes,
} from "./portable-manifest.mjs";
import { writeWindowsPlatformManifest } from "./windows-manifest.mjs";
import { updateMacosAppMetadata } from "./macos/metadata.mjs";
import {
  assertMacosSigningPreflight,
  packageSigningPolicyRecord,
  signMacosBundle,
  signMacosRunnable,
} from "./macos/signing.mjs";
import { installRunnableClient } from "./macos/install.mjs";
import { cleanupFlutterBuildCache } from "./source-staging.mjs";

export function packageClient(
  argv = process.argv.slice(2),
  {
    emit = (record) => console.log(JSON.stringify(record, null, 2)),
    preflight = runBuildPreflight,
  } = {},
) {
  const options = parsePackageClientArgs(argv);
  const config = loadPackagingConfig(options.configPath, options);
  const { selected, skipped } = selectPackagingModules(config, options);
  if (options.dryRun) {
    emit(packagePlanRecord(config, selected, skipped, options));
    return null;
  }

  preflight(options);
  const capturedSource = captureReleaseSourceState(options);
  const flutterBuildAttempted = !options.skipFlutterBuild;
  try {
    buildNativeSidecars(selected, options);
    buildSwiftSidecars(selected, options);
    if (buildFlutterApp(options)) {
      rmSync(packagedBundleRoot(options), { recursive: true, force: true });
    }

    const result = assemblePackageResources(selected, skipped, options);
    result.manifestPath = preparePortableManifest(
      config,
      selected,
      skipped,
      result.bundle,
      options,
    );
    writeBundleNotes(config, selected, result.bundle, options);
    updateMacosAppMetadata(result.bundle, options);
    signMacosBundle(result.bundle, result.copiedArtifacts, options);

    const runnable = stageRunnableClient(result, options);
    runnable.manifestPath = updateRunnableManifest(
      config,
      runnable,
      options,
    );
    writeRunnableNotes(runnable, options);
    signMacosRunnable(runnable, options);
    runnable.windowsManifestPath = writeWindowsPlatformManifest(
      runnable.root,
      options,
      "runnable",
    );
    result.windowsManifestPath = writeWindowsPlatformManifest(
      result.bundle.root,
      options,
      "bundle",
    );
    const installedAppPath = installRunnableClient(runnable, options);

    assertReleaseSourceStateStable(options, capturedSource);
    if (capturedSource.digest) assertPackagingConfigDigestStable(options);

    Object.assign(result, {
      runnable,
      installedAppPath,
    });
    emit(packageSuccessRecord(result, options));
    return result;
  } finally {
    cleanupFlutterBuildCache(options, flutterBuildAttempted);
  }
}

export function runBuildPreflight(options) {
  verifyConversationParityReadiness();
  generateMacosAppIcons(options);
  assertFlutterBuildPrereqs(options);
  assertMacosSigningPreflight(options);
}

export function packagePlanRecord(config, selected, skipped, options) {
  return Object.freeze({
    ok: true,
    platform: options.platform,
    mode: options.mode,
    profile: options.profile || config.packageProfile || "licoup",
    configPath: publicWorkspacePath(options.configPath),
    packagingConfigDigest: options.packagingConfigDigest,
    signing: packageSigningPolicyRecord(options),
    enabledModules: selected.map(publicPackagingModuleRecord),
    skippedModules: skipped.map(publicPackagingModuleRecord),
  });
}

function verifyConversationParityReadiness() {
  runPackageProcess(
    process.execPath,
    [
      path.join(
        packageClientRuntime.workspaceRoot,
        "tools",
        "scripts",
        "client-agent-conversation-parity-reducer.mjs",
      ),
      "--check",
    ],
    {
      stdio: "ignore",
      failureCode: "conversation_parity_readiness_failed",
      stage: "conversation-readiness",
    },
  );
}

function packageSuccessRecord(result, options) {
  const runnable = result.runnable;
  return Object.freeze({
    ok: true,
    platform: options.platform,
    mode: options.mode,
    runnableRef: publicWorkspacePath(
      runnable.appPath || runnable.executable,
    ),
    bundleRef: publicWorkspacePath(result.bundle.root),
    executableRef: publicWorkspacePath(runnable.executable),
    manifestRef: publicWorkspacePath(result.manifestPath),
    runnableManifestRef: runnable.manifestPath
      ? publicWorkspacePath(runnable.manifestPath)
      : "",
    windowsManifestRef: result.windowsManifestPath
      ? publicWorkspacePath(result.windowsManifestPath)
      : "",
    installed: Boolean(result.installedAppPath),
    packagedArtifactRefs: result.copiedArtifacts.map((artifact) =>
      publicWorkspacePath(artifact, "<packaged-artifact>"),
    ),
    privatePathsIncluded: false,
  });
}
