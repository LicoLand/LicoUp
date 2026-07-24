import {
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import process from "node:process";

import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  clientSourceStateDigest,
  createClientSourceManifest,
  readAndVerifyClientSourceManifest,
} from "../../../../tools/scripts/lib/client-source-state-digest.mjs";
import {
  packageClientConfigPolicy,
  packageClientRuntime,
  packageClientSchemas,
  packageFailure,
  publicWorkspacePath,
  runtimeDataDescription,
  runtimeDataPolicyRecord,
} from "./cli-policy.mjs";
import {
  publicPackagingModuleRecord,
  targetSkippedModules,
} from "./module-selection.mjs";
import { packageSigningPolicyRecord } from "./macos/signing.mjs";

const clientSourceRoots = CANONICAL_CLIENT_SOURCE_ROOTS;

export function assertReleaseSourceDigestStable(before, after) {
  if (
    !packageClientConfigPolicy.sourceDigestPattern.test(String(before || "")) ||
    before !== after
  ) {
    packageFailure("release_source_changed_during_build");
  }
  return true;
}

export function diffReleaseSourceManifests(before, after, limit = 32) {
  const beforeEntries = new Map(
    (before?.entries || []).map((entry) => [entry.path, entry]),
  );
  const afterEntries = new Map(
    (after?.entries || []).map((entry) => [entry.path, entry]),
  );
  const changed = [];
  const refs = [...new Set([...beforeEntries.keys(), ...afterEntries.keys()])]
    .sort();
  for (const sourceRef of refs) {
    const left = beforeEntries.get(sourceRef);
    const right = afterEntries.get(sourceRef);
    if (
      !left ||
      !right ||
      left.digest !== right.digest ||
      left.mode !== right.mode ||
      left.size !== right.size
    ) {
      changed.push(sourceRef);
    }
  }
  return Object.freeze({
    changedSourceCount: changed.length,
    changedSourceRefs: changed.slice(0, limit),
    truncated: changed.length > limit,
  });
}

export function packageSourceStateBinding(
  options,
  {
    environment = process.env,
    sourceDigest = () =>
      clientSourceStateDigest(
        packageClientRuntime.workspaceRoot,
        clientSourceRoots,
      ),
    verifySourceManifest = (expectedDigest) =>
      readAndVerifyClientSourceManifest(
        packageClientRuntime.workspaceRoot,
        path.join(
          packageClientRuntime.workspaceRoot,
          ".lico-source-attestation",
          "client-source-manifest.json",
        ),
        expectedDigest,
        { expectedSourceRoots: clientSourceRoots },
      ),
  } = {},
) {
  const attested = String(
    environment.LICO_CLIENT_EXPECTED_SOURCE_STATE_DIGEST || "",
  ).trim();
  if (!attested) {
    return Object.freeze({
      digest: options.releaseSourceStateDigest || sourceDigest(),
      provenance: "git-worktree",
    });
  }
  if (
    options.platform !== "linux" ||
    !packageClientConfigPolicy.sourceDigestPattern.test(attested)
  ) {
    packageFailure("client_source_attestation_invalid");
  }
  const manifestBinding = verifySourceManifest(attested);
  if (
    manifestBinding?.ok !== true ||
    manifestBinding.sourceStateDigest !== attested ||
    !packageClientConfigPolicy.sourceDigestPattern.test(
      String(manifestBinding.manifestDigest || ""),
    )
  ) {
    packageFailure("client_source_manifest_authority_invalid");
  }
  if (
    options.releaseSourceStateDigest &&
    attested !== options.releaseSourceStateDigest
  ) {
    packageFailure("release_source_attestation_mismatch");
  }
  return Object.freeze({
    digest: attested,
    provenance: "vm-orchestrator-verified",
  });
}

export function captureReleaseSourceState(options) {
  if (options.mode !== "release") {
    return Object.freeze({ binding: null, digest: "", manifest: null });
  }
  const binding = packageSourceStateBinding(options);
  options.releaseSourceStateDigest = binding.digest;
  const manifest =
    binding.provenance === "git-worktree"
      ? createClientSourceManifest(
          packageClientRuntime.workspaceRoot,
          clientSourceRoots,
          binding.digest,
        )
      : null;
  return Object.freeze({ binding, digest: binding.digest, manifest });
}

export function assertReleaseSourceStateStable(options, captured) {
  if (!captured.digest) return true;
  if (captured.binding.provenance === "git-worktree") {
    const afterDigest = clientSourceStateDigest(
      packageClientRuntime.workspaceRoot,
      clientSourceRoots,
    );
    if (afterDigest !== captured.digest) {
      const afterManifest = createClientSourceManifest(
        packageClientRuntime.workspaceRoot,
        clientSourceRoots,
        afterDigest,
      );
      packageFailure(
        "release_source_changed_during_build",
        diffReleaseSourceManifests(captured.manifest, afterManifest),
      );
    }
    return assertReleaseSourceDigestStable(captured.digest, afterDigest);
  }
  if (packageSourceStateBinding(options).digest !== captured.digest) {
    packageFailure("release_source_attestation_changed_during_build");
  }
  return true;
}

export function preparePortableManifest(
  config,
  selected,
  skipped,
  bundle,
  options,
) {
  rmSync(bundle.portableDataDir, { recursive: true, force: true });
  const manifestPath = manifestPathForRoot(config, bundle.root);
  mkdirSync(path.dirname(manifestPath), { recursive: true });
  const sourceBinding = packageSourceStateBinding(options);
  const manifest = {
    schemaVersion: packageClientSchemas.bundleManifest,
    generatedAt: new Date().toISOString(),
    sourceStateDigest: sourceBinding.digest,
    sourceStateDigestProvenance: sourceBinding.provenance,
    platform: options.platform,
    mode: options.mode,
    configPath: publicWorkspacePath(options.configPath),
    packagingConfigDigest: options.packagingConfigDigest,
    bundleRoot: ".",
    flutterExecutable: relativeBundlePath(
      bundle.root,
      bundle.flutterExecutable,
    ),
    runtimeData: runtimeDataPolicyRecord(options.platform),
    signing: packageSigningPolicyRecord(options),
    featureProfile: config.featureProfile || null,
    modules: selected.map(publicPackagingModuleRecord),
    skippedModules: targetSkippedModules(skipped).map(
      publicPackagingModuleRecord,
    ),
  };
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  return manifestPath;
}

export function writeBundleNotes(config, selected, bundle, options) {
  const lines = [
    `LicoUp ${options.platform} Client Bundle`,
    "",
    "Run the Flutter desktop frontend from this bundle.",
    "The frontend resolves licoup as its LicoUp client sidecar.",
    "Run licoup for command-line operations against the same system data workspace.",
    "",
    "Enabled modules:",
    ...selected.map((item) => `- ${item.id}: ${item.label || item.id}`),
    "",
    `Packaging config: ${publicWorkspacePath(options.configPath)}`,
    `Packaging manifest: ${relativeBundlePath(bundle.root, manifestPathForRoot(config, bundle.root))}`,
    runtimeDataDescription(options.platform),
    "",
  ];
  const fileName =
    options.platform === "windows"
      ? "README-windows.txt"
      : `README-${options.platform}.txt`;
  writeFileSync(path.join(bundle.root, fileName), lines.join("\n"), "utf8");
}

export function updateRunnableManifest(config, runnable, options) {
  const manifestPath = manifestPathForRoot(config, runnable.root);
  if (!existsSync(manifestPath)) return "";
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  manifest.bundleRoot = ".";
  manifest.flutterExecutable = relativeBundlePath(
    runnable.root,
    runnable.executable,
  );
  manifest.runtimeData = runtimeDataPolicyRecord(options.platform);
  manifest.signing = packageSigningPolicyRecord(options);
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  return manifestPath;
}

export function writeRunnableNotes(runnable, options) {
  const runnableRef = relativeBundlePath(
    runnable.root,
    runnable.appPath || runnable.executable,
  );
  const executableRef = relativeBundlePath(runnable.root, runnable.executable);
  const lines = [
    `LicoUp ${options.platform} Runnable Client`,
    "",
    `Runnable client: ${runnableRef}`,
    `Executable: ${executableRef}`,
    runtimeDataDescription(options.platform),
    "",
    options.platform === "macos"
      ? `Run with: open ${JSON.stringify(runnableRef)}`
      : `Run with: ${JSON.stringify(executableRef)}`,
    "",
  ];
  writeFileSync(
    path.join(runnable.root, "RUNNABLE_CLIENT.txt"),
    lines.join("\n"),
    "utf8",
  );
}

export function manifestPathForRoot(config, root) {
  return path.join(
    root,
    config.bundle?.manifestPath ||
      packageClientRuntime.canonicalBundleManifestRef,
  );
}

export function relativeBundlePath(root, target) {
  return path.relative(root, target) || ".";
}
